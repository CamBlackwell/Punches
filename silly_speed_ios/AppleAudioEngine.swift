import Foundation
import AVFoundation

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
    private let buffersAhead = 5
    private let bufferDuration: TimeInterval = 0.25

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
        return Double(file.length) / file.fileFormat.sampleRate
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
        
        
        warmupTimePitch()
    }

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

    private func configureBufferCapacityIfNeeded() {
        guard let file = audioFile else { return }
        if bufferFrameCapacity == 0 {
            let sampleRate = file.processingFormat.sampleRate
            let frames = AVAudioFrameCount(sampleRate * bufferDuration)
            bufferFrameCapacity = max(frames, 1024)
        }
    }
    
    private func warmupTimePitch() {
        guard let format = audioEngine.mainMixerNode.outputFormat(forBus: 0) as AVAudioFormat? else { return }

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { }
        playerNode.play()
        playerNode.stop()
    }


    private func scheduleBuffersIfNeeded() {
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

            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self = self else { return }
                self.audioQueue.async {
                    if self.isUserStopped { return }
                    self.scheduledBuffersCount -= 1
                    if atEnd && self.scheduledBuffersCount == 0 {
                        self.isFileFinished = true
                    } else {
                        self.scheduleBuffersIfNeeded()
                    }
                }
            }

            if atEnd {
                break
            }
        }
    }

    func load(audioFile: AudioFile) {
        audioQueue.async {
            do {
                self.audioFile = try AVAudioFile(forReading: audioFile.fileURL)
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
}
