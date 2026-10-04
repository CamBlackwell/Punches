import Foundation
import AVFoundation
import QuartzCore

class AppleAudioEngine: NSObject, AudioEngineProtocol {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var audioFile: AVAudioFile?
    private let audioQueue = DispatchQueue(label: "audio.engine.queue", qos: .userInitiated)
    private var seekOffset: TimeInterval = 0
    private var currentFramePosition: AVAudioFramePosition = 0
    private var bufferFrameCapacity: AVAudioFrameCount = 0
    private var scheduledBuffersCount: Int = 0
    private var isFileFinished = false
    private var isUserStopped = false
    private var hasWarmedUpTimePitch = false
    private let buffersAhead = 5
    private let bufferDuration: TimeInterval = 0.25
    var onPlaybackFinished: (() -> Void)?

    #if DEBUG
    private var debug_starveCount: Int = 0
    private var debug_maxScheduledAhead: Int = 0
    private var debug_avgScheduleMsEWMA: Double = 0
    private let debug_ewmaAlpha: Double = 0.2
    #endif

    var isPlaying: Bool {
        return playerNode.isPlaying
    }

    func getAudioEngine() -> AVAudioEngine? {
        return audioEngine
    }

    var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return seekOffset
        }
        let calculatedTime = seekOffset + (Double(playerTime.sampleTime) / playerTime.sampleRate)
        return min(calculatedTime, duration)
    }

    var duration: TimeInterval {
        guard let file = audioFile else { return 0 }
        // `file.length` counts frames in the *processing* format, so that is the
        // rate it has to be divided by. `fileFormat` is the on-disk stream and
        // its rate is lower whenever the decoder up-samples — HE-AAC encodes at
        // 22.05/24 kHz and decodes to 44.1/48 kHz — which would report twice the
        // real duration and desynchronise this clock from `seek`, which already
        // uses `processingFormat`.
        return Double(file.length) / file.processingFormat.sampleRate
    }

    override init() {
        super.init()
        setupAudioEngine()

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Early engine start failed: \(error)")
        }
    }

    /// Attaches the nodes and gives the player an initial format.
    ///
    /// The player is connected with `format: nil` here because no file exists
    /// yet, which leaves it on the audio session's rate. That is only a
    /// placeholder: `reconfigureGraphIfNeeded` reconnects the edge in the
    /// first file's own format before anything is scheduled, and the engine is
    /// long-lived, so the placeholder never reaches playback.
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.connect(playerNode, to: timePitch, format: nil)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start audio engine \(error)")
        }
    }

    /// Reconnects the graph in `format`, if the time-pitch unit's rate differs.
    ///
    /// ## Why both edges have to be reconnected
    ///
    /// `AVAudioPlayerNode` inserts **no** sample-rate converter, and
    /// `AVAudioUnitTimePitch` **pins its own output rate** when it is connected —
    /// it does not follow its input. The format therefore has to be established
    /// on *both* edges. Reconnecting only `playerNode → timePitch` leaves the
    /// unit rendering at whatever rate it was first connected with, which
    /// detunes a mismatched file exactly as much as not reconnecting at all:
    /// the player adopts the file's rate, the unit does not, and the audio is
    /// still pulled out at the wrong one.
    ///
    /// `timePitch.inputFormat(forBus: 0)` is the guard, because it is the
    /// junction between the two nodes and the one format that was silently
    /// wrong. Checking `playerNode` instead is what let the one-edge version
    /// look correct in testing.
    ///
    /// `mainMixerNode` still converts to whatever the hardware is doing, so a
    /// route change no longer detunes the library either — and its output
    /// format, which is what the analyser taps, stays at the hardware rate
    /// however the edges above it are connected.
    ///
    /// Reconnecting requires the engine to be stopped, so this is skipped
    /// whenever the rate and channel count already match. That is the common
    /// case and it costs nothing but the comparison. It is also free of an
    /// audible cost: `AudioPlaybackService.load` has already stopped the node
    /// before calling `load`, so the reconfig lands on a track boundary that
    /// exists rather than cutting into playback.
    private func reconfigureGraphIfNeeded(for format: AVAudioFormat) {
        // The unit, not the player — this is the format that actually stuck.
        let current = timePitch.inputFormat(forBus: 0)
        let alreadyCorrect = current.sampleRate == format.sampleRate
            && current.channelCount == format.channelCount
        guard !alreadyCorrect else { return }

        let wasRunning = audioEngine.isRunning

        // A node's connections can only be changed while the engine is stopped.
        if wasRunning {
            audioEngine.stop()
        }
        playerNode.stop()

        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(timePitch)
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()

        if wasRunning {
            do {
                try audioEngine.start()
            } catch {
                print("Failed to restart audio engine after format change: \(error)")
            }
        }

        #if DEBUG
        print("AudioEngine: graph \(current.sampleRate) Hz/\(current.channelCount) ch -> \(format.sampleRate) Hz/\(format.channelCount) ch")
        #endif
    }

    private func configureBufferCapacityIfNeeded() {
        guard let file = audioFile else { return }
        if bufferFrameCapacity == 0 {
            let sampleRate = file.processingFormat.sampleRate
            let frames = AVAudioFrameCount(sampleRate * bufferDuration)
            bufferFrameCapacity = max(frames, 1024)
        }
    }
    
    /// Runs one silent buffer through the player so the time-pitch unit has
    /// initialised before the first real buffer arrives. Once per engine.
    ///
    /// The buffer has to be in the **player's** format. Scheduling it in the
    /// mixer's format instead pins the node to the hardware rate and
    /// reintroduces the mismatch `reconfigureGraphIfNeeded` exists to prevent,
    /// so this waits until the first file has established the format.
    private func warmupTimePitchIfNeeded() {
        guard !hasWarmedUpTimePitch else { return }
        let format = playerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else { return }

        buffer.frameLength = 512
        hasWarmedUpTimePitch = true

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { }
        playerNode.play()
        playerNode.stop()
    }


    private func scheduleBuffersIfNeeded() {
        #if DEBUG
        let debugScheduleStart = CACurrentMediaTime()
        #endif

        guard let file = audioFile, !isFileFinished else { return }
        configureBufferCapacityIfNeeded()

        while scheduledBuffersCount < buffersAhead && currentFramePosition < file.length {
            let framesRemaining = file.length - currentFramePosition
            let framesToRead = min(AVAudioFrameCount(framesRemaining), bufferFrameCapacity)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: bufferFrameCapacity) else {
                return
            }

            file.framePosition = currentFramePosition

            do {
                try file.read(into: buffer, frameCount: framesToRead)
            } catch {
                print("Failed to read audio file: \(error)")
                isFileFinished = true
                return
            }

            buffer.frameLength = framesToRead
            currentFramePosition += AVAudioFramePosition(framesToRead)
            let atEnd = currentFramePosition >= file.length

            scheduledBuffersCount += 1

            #if DEBUG
            if scheduledBuffersCount > debug_maxScheduledAhead {
                debug_maxScheduledAhead = scheduledBuffersCount
            }
            #endif

            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self = self else { return }
                self.audioQueue.async {
                    if self.isUserStopped { return }
                    self.scheduledBuffersCount -= 1
                    #if DEBUG
                    // Count a starvation if we drop to zero scheduled buffers while playing, not user-stopped, and not at end
                    if self.playerNode.isPlaying && !self.isUserStopped && !atEnd && self.scheduledBuffersCount == 0 {
                        self.debug_starveCount &+= 1
                    }
                    #endif
                    if atEnd && self.scheduledBuffersCount == 0 {
                        self.isFileFinished = true
                        DispatchQueue.main.async {
                            self.onPlaybackFinished?()
                        }
                    } else {
                        self.scheduleBuffersIfNeeded()
                    }
                }
            }

            if atEnd {
                break
            }
        }

        #if DEBUG
        let elapsedMs = (CACurrentMediaTime() - debugScheduleStart) * 1000.0
        if debug_avgScheduleMsEWMA == 0 { debug_avgScheduleMsEWMA = elapsedMs }
        else { debug_avgScheduleMsEWMA = debug_ewmaAlpha * elapsedMs + (1 - debug_ewmaAlpha) * debug_avgScheduleMsEWMA }
        #endif
    }

    func load(audioFile: AudioFile) {
        audioQueue.async {
            do {
                let file = try AVAudioFile(forReading: audioFile.fileURL)
                self.audioFile = file

                // Must precede scheduling: the node plays buffers at whatever
                // format it is connected with.
                self.reconfigureGraphIfNeeded(for: file.processingFormat)
                self.warmupTimePitchIfNeeded()

                self.seekOffset = 0
                self.currentFramePosition = 0
                self.bufferFrameCapacity = 0
                self.scheduledBuffersCount = 0
                self.isFileFinished = false
                self.isUserStopped = false
            } catch {
                print("failed to load audioFile: \(error) at \(audioFile.fileURL.path())")
            }
        }
    }

    func play() {
        audioQueue.async {
            guard let file = self.audioFile else { return }

            if !self.audioEngine.isRunning {
                do {
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                } catch {
                    print("Could not start audio engine: \(error)")
                    return
                }
            }

            if !self.playerNode.isPlaying {
                self.isUserStopped = false
                if self.scheduledBuffersCount == 0 && !self.isFileFinished {
                    let sampleRate = file.processingFormat.sampleRate
                    if self.currentFramePosition == 0 {
                        self.seekOffset = 0
                    } else {
                        self.seekOffset = Double(self.currentFramePosition) / sampleRate
                    }
                    self.scheduleBuffersIfNeeded()
                }
                self.playerNode.play()
            }
        }
    }

    func pause() {
        playerNode.pause()
    }

    func stop() {
        audioQueue.async {
            self.isUserStopped = true
            self.playerNode.stop()
            self.seekOffset = 0
            self.currentFramePosition = 0
            self.bufferFrameCapacity = 0
            self.scheduledBuffersCount = 0
            self.isFileFinished = false
        }
    }

    func seek(to time: TimeInterval) {
        audioQueue.async {
            guard let file = self.audioFile else { return }

            let wasPlaying = self.playerNode.isPlaying

            self.playerNode.stop()
            self.isUserStopped = false
            self.scheduledBuffersCount = 0
            self.isFileFinished = false

            let sampleRate = file.processingFormat.sampleRate
            let clampedTime = max(0, min(time, self.duration))
            let newFramePosition = AVAudioFramePosition(clampedTime * sampleRate)

            self.currentFramePosition = max(0, min(newFramePosition, file.length))
            self.seekOffset = Double(self.currentFramePosition) / sampleRate

            self.scheduleBuffersIfNeeded()

            if wasPlaying {
                if !self.audioEngine.isRunning {
                    do {
                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                    } catch {
                        print("Could not start audio engine: \(error)")
                        return
                    }
                }
                self.playerNode.play()
            }
        }
    }

    func setVolume(_ volume: Float) {
        playerNode.volume = volume
    }

    func setTempo(_ tempo: Float) {
        audioQueue.async {
            self.timePitch.rate = tempo
        }
    }

    func setPitch(_ pitch: Float) {
        audioQueue.async {
            self.timePitch.pitch = pitch
        }
    }
    
    var debugMetrics: EngineDebugMetrics {
        #if DEBUG
        return EngineDebugMetrics(
            starveCount: debug_starveCount,
            maxScheduledAhead: debug_maxScheduledAhead,
            avgScheduleMs: debug_avgScheduleMsEWMA
        )
        #else
        return EngineDebugMetrics(starveCount: 0, maxScheduledAhead: 0, avgScheduleMs: 0)
        #endif
    }
}
