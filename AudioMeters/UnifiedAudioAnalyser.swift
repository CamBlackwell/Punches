import Foundation
import AVFoundation
import Combine
import Accelerate
import AudioKit

// MARK: - Lock-Free Ring Buffer
class RingBuffer {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int
    private let lock = NSLock()
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: 0, count: capacity)
    }
    
    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        
        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
    }
    
    func readLatest(_ count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        var result = [Float](repeating: 0, count: count)
        var startIndex = (writeIndex - count + capacity) % capacity
        
        for i in 0..<count {
            result[i] = buffer[(startIndex + i) % capacity]
        }
        
        return result
    }
}

// MARK: - Envelope Follower for Dynamic Gain Reduction
class EnvelopeFollower {
    private var envelope: Float = 0.0
    private let attackTime: Float
    private let releaseTime: Float
    private let sampleRate: Float
    
    private var attackCoeff: Float
    private var releaseCoeff: Float
    
    init(attackMs: Float = 1.0, releaseMs: Float = 100.0, sampleRate: Float = 44100.0) {
        self.attackTime = attackMs
        self.releaseTime = releaseMs
        self.sampleRate = sampleRate
        
        // Calculate coefficients for exponential smoothing
        self.attackCoeff = exp(-1.0 / (attackMs * 0.001 * sampleRate))
        self.releaseCoeff = exp(-1.0 / (releaseMs * 0.001 * sampleRate))
    }
    
    func process(_ input: Float) -> Float {
        let rectified = abs(input)
        
        if rectified > envelope {
            // Attack: fast response to increasing levels
            envelope = attackCoeff * envelope + (1.0 - attackCoeff) * rectified
        } else {
            // Release: slow decay
            envelope = releaseCoeff * envelope + (1.0 - releaseCoeff) * rectified
        }
        
        return envelope
    }
    
    func reset() {
        envelope = 0.0
    }
}

// MARK: - Gain Computer for Dynamic Processing
struct GainComputer {
    let threshold: Float // dB
    let ratio: Float
    let knee: Float // dB
    
    init(threshold: Float = -12.0, ratio: Float = 4.0, knee: Float = 6.0) {
        self.threshold = threshold
        self.ratio = ratio
        self.knee = knee
    }
    
    func computeGainReduction(_ inputDB: Float) -> Float {
        if inputDB < (threshold - knee / 2.0) {
            // Below threshold - no reduction
            return 0.0
        } else if inputDB > (threshold + knee / 2.0) {
            // Above knee - full compression
            let excess = inputDB - threshold
            return excess * (1.0 - 1.0 / ratio)
        } else {
            // In knee - soft knee compression
            let excess = inputDB - threshold + knee / 2.0
            let scale = excess / knee
            let scaledExcess = scale * scale * knee / 2.0
            return scaledExcess * (1.0 - 1.0 / ratio)
        }
    }
}

// MARK: - Main Analyzer with Mid/Side Processing
class MixerNodeWrapper: Node {
    var avAudioNode: AVAudioNode
    var connections: [Node] = []
    
    init(_ rawNode: AVAudioNode) {
        self.avAudioNode = rawNode
    }
}

class UnifiedAudioAnalyser: ObservableObject {
    @Published var node: Node?
    
    // Standard stereo spectrum
    @Published var spectrumBands: [Float] = Array(repeating: 0.0, count: 32)
    @Published var peakHolds: [Float] = Array(repeating: 0.0, count: 32)
    
    // Mid/Side spectrum (M = L+R, S = L-R)
    @Published var midSpectrumBands: [Float] = Array(repeating: 0.0, count: 32)
    @Published var sideSpectrumBands: [Float] = Array(repeating: 0.0, count: 32)
    @Published var midPeakHolds: [Float] = Array(repeating: 0.0, count: 32)
    @Published var sidePeakHolds: [Float] = Array(repeating: 0.0, count: 32)
    
    // Gain reduction per band (for dynamic visualization)
    @Published var gainReduction: [Float] = Array(repeating: 0.0, count: 32)
    
    @Published var leftSamples: [Float] = []
    @Published var rightSamples: [Float] = []
    @Published var midSamples: [Float] = []
    @Published var sideSamples: [Float] = []
    @Published var phaseCorrelation: Float = 0.0
    
    // FFT Configuration
    private let fftSize: Int = 8192
    private let bandCount = 32
    private let maxStereoPoints = 100
    private let hopSize: Int
    private let overlapFactor: Float = 0.75
    
    // Ring buffers for lock-free audio storage
    private var audioRingBuffer: RingBuffer
    private var leftRingBuffer: RingBuffer
    private var rightRingBuffer: RingBuffer
    private var midRingBuffer: RingBuffer
    private var sideRingBuffer: RingBuffer
    
    // FFT Components
    private var forwardDFT: vDSP.DiscreteFourierTransform<Float>?
    private var window: [Float] = []
    
    // Working buffers
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    
    // Processing state
    private var sampleRate: Float = 44100.0
    
    // Three-layer smoothing
    private var smoothedBands: [Float]
    private var smoothedMidBands: [Float]
    private var smoothedSideBands: [Float]
    private let attackTime: Float = 0.0
    private let releaseTime: Float = 0.15
    
    // Dynamic gain reduction
    private var envelopeFollowers: [EnvelopeFollower]
    private var gainComputers: [GainComputer]
    private let dynamicsEnabled: Bool = true
    
    // Graphics update timer - runs at 60fps
    private var updateTimer: Timer?
    private let targetFPS: Double = 60.0
    
    init() {
        self.hopSize = Int(Float(fftSize) * (1.0 - overlapFactor))
        
        let ringBufferSize = fftSize * 4
        self.audioRingBuffer = RingBuffer(capacity: ringBufferSize)
        self.leftRingBuffer = RingBuffer(capacity: ringBufferSize)
        self.rightRingBuffer = RingBuffer(capacity: ringBufferSize)
        self.midRingBuffer = RingBuffer(capacity: ringBufferSize)
        self.sideRingBuffer = RingBuffer(capacity: ringBufferSize)
        
        self.realBuffer = [Float](repeating: 0, count: fftSize)
        self.imagBuffer = [Float](repeating: 0, count: fftSize)
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
        self.smoothedMidBands = [Float](repeating: 0, count: bandCount)
        self.smoothedSideBands = [Float](repeating: 0, count: bandCount)
        
        // Initialize envelope followers and gain computers for each band
        self.envelopeFollowers = (0..<bandCount).map { _ in
            EnvelopeFollower(attackMs: 1.0, releaseMs: 100.0, sampleRate: 44100.0)
        }
        self.gainComputers = (0..<bandCount).map { _ in
            GainComputer(threshold: -12.0, ratio: 4.0, knee: 6.0)
        }
        
        setupFFT()
        startGraphicsTimer()
    }
    
    deinit {
        updateTimer?.invalidate()
    }
    
    private func setupFFT() {
        do {
            forwardDFT = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: fftSize,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            print("Failed to setup FFT: \(error)")
        }
        
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftSize,
            isHalfWindow: false
        )
    }
    
    // MARK: - Graphics Timer (60fps)
    private func startGraphicsTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / targetFPS, repeats: true) { [weak self] _ in
            self?.updateSpectrum()
        }
    }
    
    // MARK: - Audio Attachment
    func attach(to audioEngine: AVAudioEngine) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.attachTapAfterEngineStabilizes(audioEngine)
        }
    }

    private func attachTapAfterEngineStabilizes(_ audioEngine: AVAudioEngine) {
        self.node = MixerNodeWrapper(audioEngine.mainMixerNode)
        let mixer = audioEngine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        self.sampleRate = Float(format.sampleRate)
        mixer.removeTap(onBus: 0)

        mixer.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(hopSize),
            format: format
        ) { [weak self] buffer, time in
            self?.writeToRingBuffer(buffer)
        }
    }

    func detach(from audioEngine: AVAudioEngine) {
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        updateTimer?.invalidate()
        
        DispatchQueue.main.async {
            self.spectrumBands = Array(repeating: 0.0, count: self.bandCount)
            self.peakHolds = Array(repeating: 0.0, count: self.bandCount)
            self.midSpectrumBands = Array(repeating: 0.0, count: self.bandCount)
            self.sideSpectrumBands = Array(repeating: 0.0, count: self.bandCount)
            self.midPeakHolds = Array(repeating: 0.0, count: self.bandCount)
            self.sidePeakHolds = Array(repeating: 0.0, count: self.bandCount)
            self.gainReduction = Array(repeating: 0.0, count: self.bandCount)
            self.smoothedBands = Array(repeating: 0.0, count: self.bandCount)
            self.smoothedMidBands = Array(repeating: 0.0, count: self.bandCount)
            self.smoothedSideBands = Array(repeating: 0.0, count: self.bandCount)
            self.leftSamples = []
            self.rightSamples = []
            self.midSamples = []
            self.sideSamples = []
            self.phaseCorrelation = 0.0
            self.node = nil
        }
        
        startGraphicsTimer()
    }
    
    // MARK: - Audio Thread (Write to Ring Buffer)
    private func writeToRingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        
        let leftPtr = channelData[0]
        let rightPtr = buffer.format.channelCount > 1 ? channelData[1] : leftPtr
        
        let left = Array(UnsafeBufferPointer(start: leftPtr, count: frameLength))
        let right = Array(UnsafeBufferPointer(start: rightPtr, count: frameLength))
        
        // Mid/Side encoding: M = (L+R)/2, S = (L-R)/2
        var mid = [Float](repeating: 0, count: frameLength)
        var side = [Float](repeating: 0, count: frameLength)
        var mono = [Float](repeating: 0, count: frameLength)
        
        vDSP.add(left, right, result: &mid)
        vDSP.divide(mid, 2.0, result: &mid)
        
        vDSP.subtract(right, left, result: &side)
        vDSP.divide(side, 2.0, result: &side)
        
        vDSP.add(left, right, result: &mono)
        vDSP.divide(mono, 2.0, result: &mono)
        
        // Write to ring buffers
        audioRingBuffer.write(mono)
        leftRingBuffer.write(left)
        rightRingBuffer.write(right)
        midRingBuffer.write(mid)
        sideRingBuffer.write(side)
    }
    
    // MARK: - Graphics Thread (Read from Ring Buffer at 60fps)
    private func updateSpectrum() {
        // Process standard stereo
        let monoSamples = audioRingBuffer.readLatest(fftSize)
        processFFT(samples: monoSamples, output: .standard)
        
        // Process Mid channel
        let midSamples = midRingBuffer.readLatest(fftSize)
        processFFT(samples: midSamples, output: .mid)
        
        // Process Side channel
        let sideSamples = sideRingBuffer.readLatest(fftSize)
        processFFT(samples: sideSamples, output: .side)
        
        updateStereoVisualization()
    }
    
    private enum FFTOutput {
        case standard
        case mid
        case side
    }
    
    private func processFFT(samples: [Float], output: FFTOutput) {
        let windowedSamples = vDSP.multiply(samples, window)
        var magnitudes = [Float](repeating: 0, count: fftSize)
        
        for i in 0..<fftSize { imagBuffer[i] = 0 }
        
        forwardDFT?.transform(inputReal: windowedSamples,
                             inputImaginary: imagBuffer,
                             outputReal: &realBuffer,
                             outputImaginary: &imagBuffer)
        
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize))
            }
        }
        
        var newBands = [Float]()
        var newPeaks = [Float]()
        var newGainReduction = [Float]()
        
        let nyquist = sampleRate / 2.0
        let minFreq = log10(Float(20.0))
        let maxFreq = log10(Float(20000.0))
        
        for i in 0..<bandCount {
            let fraction = Float(i) / Float(bandCount)
            let logFreq = minFreq + fraction * (maxFreq - minFreq)
            let targetFreq = pow(10, logFreq)
            
            let nextFraction = Float(i + 1) / Float(bandCount)
            let nextLogFreq = minFreq + nextFraction * (maxFreq - minFreq)
            let nextTargetFreq = pow(10, nextLogFreq)
            
            var startBin = Int((targetFreq / nyquist) * Float(fftSize / 2))
            var endBin = Int((nextTargetFreq / nyquist) * Float(fftSize / 2))
            
            let minBinsPerBand = 3
            let binsInRange = endBin - startBin
            if binsInRange < minBinsPerBand {
                let centerBin = (startBin + endBin) / 2
                startBin = max(0, centerBin - minBinsPerBand / 2)
                endBin = min(fftSize / 2, startBin + minBinsPerBand)
            }
            
            let clampedStart = min(max(startBin, 0), (fftSize / 2) - 1)
            let clampedEnd = min(max(endBin, clampedStart + 1), fftSize / 2)
            
            var sumSquared: Float = 0
            var count: Float = 0
            
            for binIndex in clampedStart..<clampedEnd {
                let mag = magnitudes[binIndex]
                sumSquared += mag * mag
                count += 1
            }
            
            let rms = count > 0 ? sqrt(sumSquared / count) : 0
            
            let bassBoost: Float
            if targetFreq < 200 {
                bassBoost = 1.8
            } else if targetFreq < 500 {
                bassBoost = 1.4
            } else if targetFreq < 2000 {
                bassBoost = 1.15
            } else {
                bassBoost = 1.0 + (targetFreq / 10000.0) * 0.4
            }
            
            let weightedRMS = rms * bassBoost
            
            // Dynamic gain reduction per band
            let envelope = envelopeFollowers[i].process(weightedRMS)
            let db = 20 * log10(envelope + 0.00001)
            let grDB = gainComputers[i].computeGainReduction(db)
            
            // Apply gain reduction
            let reducedRMS = weightedRMS * pow(10, -grDB / 20.0)
            
            let reducedDB = 20 * log10(reducedRMS + 0.00001)
            let normalized = max(0, min(1, (reducedDB + 60) / 60))
            
            // Temporal smoothing with attack/release
            let currentValue: Float
            switch output {
            case .standard: currentValue = smoothedBands[i]
            case .mid: currentValue = smoothedMidBands[i]
            case .side: currentValue = smoothedSideBands[i]
            }
            
            let smoothed: Float
            if normalized > currentValue {
                smoothed = normalized
            } else {
                let decayFactor = Float(1.0 / targetFPS) / releaseTime
                smoothed = currentValue - (currentValue - normalized) * decayFactor
            }
            
            let finalSmoothed = max(0, smoothed)
            switch output {
            case .standard: smoothedBands[i] = finalSmoothed
            case .mid: smoothedMidBands[i] = finalSmoothed
            case .side: smoothedSideBands[i] = finalSmoothed
            }
            newBands.append(finalSmoothed)
            
            // Peak hold
            let previousPeak: Float
            switch output {
            case .standard: previousPeak = peakHolds.indices.contains(i) ? peakHolds[i] : 0
            case .mid: previousPeak = midPeakHolds.indices.contains(i) ? midPeakHolds[i] : 0
            case .side: previousPeak = sidePeakHolds.indices.contains(i) ? sidePeakHolds[i] : 0
            }
            
            newPeaks.append(max(finalSmoothed, previousPeak - 0.008))
            
            // Store gain reduction
            newGainReduction.append(grDB)
        }
        
        DispatchQueue.main.async {
            switch output {
            case .standard:
                self.spectrumBands = newBands
                self.peakHolds = newPeaks
                self.gainReduction = newGainReduction
            case .mid:
                self.midSpectrumBands = newBands
                self.midPeakHolds = newPeaks
            case .side:
                self.sideSpectrumBands = newBands
                self.sidePeakHolds = newPeaks
            }
        }
    }
    
    private func updateStereoVisualization() {
        let leftSamples = leftRingBuffer.readLatest(1024)
        let rightSamples = rightRingBuffer.readLatest(1024)
        let midSamples = midRingBuffer.readLatest(1024)
        let sideSamples = sideRingBuffer.readLatest(1024)
        
        let downsample = max(1, leftSamples.count / 50)
        var newLeft: [Float] = []
        var newRight: [Float] = []
        var newMid: [Float] = []
        var newSide: [Float] = []
        
        for i in stride(from: 0, to: leftSamples.count, by: downsample) {
            newLeft.append(leftSamples[i])
            newRight.append(rightSamples[i])
            newMid.append(midSamples[i])
            newSide.append(sideSamples[i])
        }
        
        var correlation: Float = 0
        if leftSamples.count == rightSamples.count && !leftSamples.isEmpty {
            let dotProduct = vDSP.dot(leftSamples, rightSamples)
            let leftSumSq = vDSP.dot(leftSamples, leftSamples)
            let rightSumSq = vDSP.dot(rightSamples, rightSamples)
            let denominator = sqrt(leftSumSq * rightSumSq)
            
            if denominator > 0 {
                correlation = dotProduct / denominator
            }
        }
        
        DispatchQueue.main.async {
            self.leftSamples = (self.leftSamples + newLeft).suffix(self.maxStereoPoints)
            self.rightSamples = (self.rightSamples + newRight).suffix(self.maxStereoPoints)
            self.midSamples = (self.midSamples + newMid).suffix(self.maxStereoPoints)
            self.sideSamples = (self.sideSamples + newSide).suffix(self.maxStereoPoints)
            self.phaseCorrelation = correlation
        }
    }
}
