import Foundation
import AVFoundation

class SoundTouchAudioEngine: NSObject, AudioEngineProtocol {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?

    private let audioQueue = DispatchQueue(label: "audio.engine.soundtouch.queue", qos: .userInitiated)

    private var seekOffset: TimeInterval = 0
    private var currentFramePosition: AVAudioFramePosition = 0
    private var bufferFrameCapacity: AVAudioFrameCount = 0
    private var scheduledBuffersCount: Int = 0
    private var isFileFinished = false
    private var isUserStopped = false
    private let buffersAhead = 4
    private let bufferDuration: TimeInterval = 0.15

    private var soundTouch: STWrapper?
    private var channels: AVAudioChannelCount = 2
    private var sampleRate: Double = 44100

    private var _tempo: Float = 1.0
    private var _pitch: Float = 0.0

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
    }

    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("SoundTouchAudioEngine: Failed to start audio engine \(error)")
        }
    }

    private func configureForFileIfNeeded() {
        guard let file = audioFile else { return }

        let format = file.processingFormat
        sampleRate = format.sampleRate
        channels = format.channelCount

        if soundTouch == nil {
            soundTouch = STWrapper(sampleRate: sampleRate, channels: Int32(Int(channels)))
            soundTouch?.setTempo(_tempo)
            soundTouch?.setPitchSemitones(_pitch / 100.0)
        }

        if bufferFrameCapacity == 0 {
            let frames = AVAudioFrameCount(sampleRate * bufferDuration)
            bufferFrameCapacity = max(frames, 2048)  // Increased minimum
        }
    }

    private func scheduleBuffersIfNeeded() {
        guard let file = audioFile, !isFileFinished else { return }
        configureForFileIfNeeded()

        // Schedule multiple buffers at once for smoother playback
        while scheduledBuffersCount < buffersAhead && currentFramePosition < file.length {
            scheduleNextBuffer()
        }
    }

    private func scheduleNextBuffer() {
        guard let file = audioFile else { return }
        
        let framesRemaining = file.length - currentFramePosition
        guard framesRemaining > 0 else {
            isFileFinished = true
            return
        }
        
        let framesToRead = min(bufferFrameCapacity, AVAudioFrameCount(framesRemaining))

        guard let rawBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: bufferFrameCapacity
        ) else { return }

        file.framePosition = currentFramePosition

        do {
            try file.read(into: rawBuffer, frameCount: framesToRead)
        } catch {
            print("SoundTouchAudioEngine: Failed to read audio file: \(error)")
            isFileFinished = true
            return
        }

        guard let st = soundTouch else {
            rawBuffer.frameLength = framesToRead
            scheduleBuffer(
                rawBuffer,
                atEnd: currentFramePosition + AVAudioFramePosition(framesToRead) >= file.length
            )
            currentFramePosition += AVAudioFramePosition(framesToRead)
            return
        }

        let inputFrameCount = Int(rawBuffer.frameLength)
        let inputChannelCount = Int(channels)

        guard let inChannels = rawBuffer.floatChannelData else {
            currentFramePosition += AVAudioFramePosition(framesToRead)
            return
        }

        var interleavedIn = [Float](repeating: 0, count: inputFrameCount * inputChannelCount)

        for frame in 0..<inputFrameCount {
            for ch in 0..<inputChannelCount {
                interleavedIn[frame * inputChannelCount + ch] = inChannels[ch][frame]
            }
        }

        // Larger output buffer to handle tempo changes
        let outCapacitySamples = interleavedIn.count * 4  // Increased from 2
        var interleavedOut = [Float](repeating: 0, count: outCapacitySamples)

        let producedSamples: Int = interleavedIn.withUnsafeBufferPointer { inPtr in
            interleavedOut.withUnsafeMutableBufferPointer { outPtr in
                guard let inBase = inPtr.baseAddress,
                      let outBase = outPtr.baseAddress else { return 0 }

                return Int(st.processSamples(
                    inBase,
                    numSamples: UInt32(interleavedIn.count),
                    outBuffer: outBase,
                    outBufferCapacity: UInt32(outCapacitySamples)
                ))
            }
        }

        let producedFrames = producedSamples / inputChannelCount
        
        // Always advance the read position
        currentFramePosition += AVAudioFramePosition(framesToRead)
        
        // If we got output, schedule it
        if producedFrames > 0 {
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(producedFrames)
            ) else { return }

            guard let outChannels = outBuffer.floatChannelData else { return }

            for ch in 0..<inputChannelCount {
                let dst = outChannels[ch]
                for frame in 0..<producedFrames {
                    dst[frame] = interleavedOut[frame * inputChannelCount + ch]
                }
            }

            outBuffer.frameLength = AVAudioFrameCount(producedFrames)
            let atEnd = currentFramePosition >= file.length
            scheduleBuffer(outBuffer, atEnd: atEnd)
        }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, atEnd: Bool) {
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
                    // Schedule more buffers immediately
                    self.scheduleBuffersIfNeeded()
                }
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
                self.soundTouch = nil
            } catch {
                print("SoundTouchAudioEngine: failed to load audioFile: \(error) at \(audioFile.fileURL.path())")
            }
        }
    }

    func play() {
        audioQueue.async {
            guard self.audioFile != nil else { return }

            if !self.audioEngine.isRunning {
                do {
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                } catch {
                    print("SoundTouchAudioEngine: Could not start audio engine: \(error)")
                    return
                }
            }

            if !self.playerNode.isPlaying {
                self.isUserStopped = false
                if self.scheduledBuffersCount == 0 && !self.isFileFinished {
                    // Prime the buffer before starting playback
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
            self.soundTouch?.clear()
            self.soundTouch = nil
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

            self.soundTouch?.clear()
            self.soundTouch = nil
            self.configureForFileIfNeeded()

            // Prime buffers before resuming
            self.scheduleBuffersIfNeeded()

            if wasPlaying {
                if !self.audioEngine.isRunning {
                    do {
                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                    } catch {
                        print("SoundTouchAudioEngine: Could not start audio engine: \(error)")
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
            guard self._tempo != tempo else { return }
            self._tempo = tempo
            self.reprocessAudioFromCurrentPosition()
        }
    }

    func setPitch(_ pitch: Float) {
        audioQueue.async {
            guard self._pitch != pitch else { return }
            self._pitch = pitch
            self.reprocessAudioFromCurrentPosition()
        }
    }
    private func reprocessAudioFromCurrentPosition() {
        guard let file = self.audioFile else { return }
        
        let wasPlaying = self.playerNode.isPlaying
        
        let sampleRate = file.processingFormat.sampleRate
        var capturedTime: TimeInterval = self.seekOffset
        
        if let nodeTime = self.playerNode.lastRenderTime,
           let playerTime = self.playerNode.playerTime(forNodeTime: nodeTime) {
            capturedTime = self.seekOffset + (Double(playerTime.sampleTime) / playerTime.sampleRate)
        }
        
        self.playerNode.stop()
        self.scheduledBuffersCount = 0
        self.isFileFinished = false
        
        self.currentFramePosition = AVAudioFramePosition(capturedTime * sampleRate)
        self.seekOffset = capturedTime
        
        self.soundTouch?.setTempo(self._tempo)
        self.soundTouch?.setPitchSemitones(self._pitch / 100.0)
        
        self.scheduleBuffersIfNeeded()
        
        if wasPlaying {
            self.playerNode.play()
        }
    }
}
