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

    /// Whether `timePitch → mainMixerNode` has been connected yet.
    ///
    /// That edge is deferred out of `setupAudioEngine()` — see there for why. It
    /// needs its own flag because `reconfigureGraphIfNeeded` decides whether to
    /// run on `alreadyCorrect`, which can be `true` on a brand-new engine: the
    /// placeholder `playerNode → timePitch` connection adopts the audio session's
    /// rate, so any file already at that rate skips the reconfigure entirely and
    /// the graph would be left with no path to the speakers. Silence, for every
    /// 48 kHz file, with nothing logged.
    private var isOutputConnected = false
    private let buffersAhead = 5
    private let bufferDuration: TimeInterval = 0.25
    /// Fired on the main queue once the final scheduled buffer has been played.
///
/// Deliberately *not* cleared by `stop()` or `load()`, even though that reads
/// like it should be. `AudioPlaybackService` reassigns this from the main
/// thread immediately after calling `load()`, while the engine's own `stop()`
/// and `load()` bodies are still sitting unstarted on `audioQueue` — so clearing
/// it there races the reassignment and can wipe the closure the *new* track
/// needs, silently disabling auto-advance for that track. Staleness is handled
/// by `playbackGeneration` instead, which is checked on `audioQueue` where it
/// cannot race.
var onPlaybackFinished: (() -> Void)?

    /// Identifies the current scheduling run.
    ///
    /// `AVAudioPlayerNode` keeps invoking completion handlers for buffers that
    /// were *flushed* rather than played, and both `stop()` and `seek()` flush
    /// up to `buffersAhead` of them. Those late callbacks used to land on
    /// `audioQueue` behind the work that had just replaced them, decrement the
    /// new run's `scheduledBuffersCount`, and — because the flushed run's last
    /// buffer had `atEnd == true` — set `isFileFinished` on a track that had
    /// barely started and fire `onPlaybackFinished`. That is the "the next
    /// button skips two songs" and "seeking near the end skips the track"
    /// behaviour, and no amount of clearing `onPlaybackFinished` prevents it,
    /// because the damage is to the scheduling counter rather than the
    /// callback.
    ///
    /// Every buffer captures the generation it was scheduled under and discards
    /// itself if the engine has moved on. All three mutators of scheduling
    /// state bump it — `load`, `stop` and `seek`.
    private var playbackRun = PlaybackRun()

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
    }

    /// Attaches the nodes and gives the player an initial format.
    ///
    /// The player is connected with `format: nil` here because no file exists
    /// yet, which leaves it on the audio session's rate. That is only a
    /// placeholder: `reconfigureGraphIfNeeded` reconnects the edge in the
    /// first file's own format before anything is scheduled, and the engine is
    /// long-lived, so the placeholder never reaches playback.
    ///
    /// ## The output edge is connected later, not here
    ///
    /// Reading `audioEngine.mainMixerNode` initialises the IO unit, and when the
    /// audio hardware does not answer, AudioToolbox reports it through
    /// `_ReportRPCTimeout` → `abort()` from *inside* the accessor. There is no
    /// error to catch and no way to decline: merely naming the mixer was enough
    /// to kill the process during `AudioManager.init`, before any playback code
    /// ran and before anything could be shown or logged.
    ///
    /// So the graph is built up to the time-pitch unit here and the connection to
    /// the mixer is made by `reconfigureGraphIfNeeded` on the first file that
    /// needs it. Nothing is lost by the delay — the mixer was only ever going to
    /// be used once there was audio to route through it, and an app that is
    /// launched and never played now touches no audio hardware at all.
    ///
    /// `prepare()` is deferred for the same reason and is genuinely redundant
    /// rather than merely premature: preparing a graph whose chain ends at
    /// `timePitch` raises an `NSException` from `AVAudioEngineGraph::Initialize`
    /// — an Objective-C exception, so again nothing to catch. Both
    /// `reconfigureGraphIfNeeded` and `play()` prepare after the graph reaches
    /// the mixer, and `start()` prepares implicitly, so the eager call bought
    /// nothing.
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.connect(playerNode, to: timePitch, format: nil)
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

        // `!isOutputConnected` overrides `alreadyCorrect`: the graph can already
        // be the right shape *and* still have nothing connected to the speakers.
        guard !alreadyCorrect || !isOutputConnected else { return }

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
        isOutputConnected = true
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

        // The token of the run in progress, read not advanced. This only ever
        // runs on `audioQueue`, so it cannot change underneath the loop — and
        // advancing it here would invalidate the buffers the previous pass
        // scheduled, since this function recurses as buffers drain.
        let generation = playbackRun.current

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
                    // Drop the callback if the run it belonged to has been
                    // replaced. This is the whole point of the generation, and
                    // it is checked here — on the same serial queue as `load`,
                    // `stop` and `seek` — so it cannot itself race.
                    guard self.playbackRun.isCurrent(generation) else { return }
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
            // Invalidate the previous run's outstanding callbacks *before*
            // anything else. The counters they would decrement are reset below.
            // Explicit `_ =`: the returned token is deliberately *not* used here.
            // Capturing it is the one thing this must not do — see
            // `scheduleBuffersIfNeeded`, where reading it bumps it, and where
            // the read is on the hot path.
            _ = self.playbackRun.begin()
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
        // Serialised with every sibling. Calling `playerNode.pause()` directly
        // ran it on whichever thread the notification arrived on, racing the
        // scheduling work already queued on `audioQueue`.
        audioQueue.async {
            self.playerNode.pause()
        }
    }

    func stop() {
        audioQueue.async {
            _ = self.playbackRun.begin()
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
            // `playerNode.stop()` below flushes every pending buffer and the
            // system still calls their handlers, so this must invalidate them
            // before the counters are reset — otherwise a seek near the end of a
            // track fires the end-of-track completion on the rescheduled run.
            _ = self.playbackRun.begin()
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
