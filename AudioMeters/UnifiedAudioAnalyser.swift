import Foundation
import AVFoundation
import Combine
import Accelerate
import AudioKit

class MixerNodeWrapper: Node {
    var avAudioNode: AVAudioNode
    var connections: [Node] = []
    
    init(_ rawNode: AVAudioNode) {
        self.avAudioNode = rawNode
    }
}

class UnifiedAudioAnalyser: ObservableObject {
    @Published var node: Node?
    @Published var spectrumBands: [Float] = Array(repeating: 0.0, count: 32)
    @Published var peakHolds: [Float] = Array(repeating: 0.0, count: 32)
    
    @Published var leftSamples: [Float] = []
    @Published var rightSamples: [Float] = []
    @Published var phaseCorrelation: Float = 0.0
    
    private let bufferSize: Int = 8192
    private let bandCount = 32
    private let maxStereoPoints = 100
    
    private var forwardDFT: vDSP.DiscreteFourierTransform<Float>?
    private var window: [Float] = []
    
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    
    private var sampleRate: Float = 44100.0
    private var smoothedBands: [Float]
    private let smoothingFactor: Float = 0.25
    private let minBinsPerBand = 3
    
    init() {
        self.realBuffer = [Float](repeating: 0, count: bufferSize)
        self.imagBuffer = [Float](repeating: 0, count: bufferSize)
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
        setupFFT()
    }
    
    private func setupFFT() {
        do {
            forwardDFT = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: bufferSize,
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
            count: bufferSize,
            isHalfWindow: false
        )
    }
    
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
            bufferSize: AVAudioFrameCount(bufferSize),
            format: format
        ) { [weak self] buffer, time in
            self?.processBuffer(buffer)
        }
    }

    
    func detach(from audioEngine: AVAudioEngine) {
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        
        DispatchQueue.main.async {
            self.spectrumBands = Array(repeating: 0.0, count: self.bandCount)
            self.peakHolds = Array(repeating: 0.0, count: self.bandCount)
            self.smoothedBands = Array(repeating: 0.0, count: self.bandCount)
            self.leftSamples = []
            self.rightSamples = []
            self.phaseCorrelation = 0.0
            self.node = nil
        }
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= bufferSize else { return }
        
        let leftPtr = channelData[0]
        let rightPtr = buffer.format.channelCount > 1 ? channelData[1] : leftPtr
        
        var monoMix = [Float](repeating: 0, count: bufferSize)
        vDSP.add(UnsafeBufferPointer(start: leftPtr, count: bufferSize),
                 UnsafeBufferPointer(start: rightPtr, count: bufferSize),
                 result: &monoMix)
        vDSP.divide(monoMix, 2.0, result: &monoMix)
        
        processSpectrum(samples: monoMix)
        processStereo(left: UnsafeBufferPointer(start: leftPtr, count: frameLength),
                      right: UnsafeBufferPointer(start: rightPtr, count: frameLength))
    }
    
    private func processSpectrum(samples: [Float]) {
        let windowedSamples = vDSP.multiply(samples, window)
        var magnitudes = [Float](repeating: 0, count: bufferSize)
        
        for i in 0..<bufferSize { imagBuffer[i] = 0 }
        
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
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(bufferSize))
            }
        }
        
        var newBands = [Float]()
        var newPeaks = [Float]()
        
        let nyquist = sampleRate / 2.0
        
        for i in 0..<bandCount {
            let fraction = Float(i) / Float(bandCount)
            let minFreq = log10(Float(20.0))
            let maxFreq = log10(Float(20000.0))
            let logFreq = minFreq + fraction * (maxFreq - minFreq)
            let targetFreq = pow(10, logFreq)
            
            let nextFraction = Float(i + 1) / Float(bandCount)
            let nextLogFreq = minFreq + nextFraction * (maxFreq - minFreq)
            let nextTargetFreq = pow(10, nextLogFreq)
            
            var startBin = Int((targetFreq / nyquist) * Float(bufferSize / 2))
            var endBin = Int((nextTargetFreq / nyquist) * Float(bufferSize / 2))
            
            let binsInRange = endBin - startBin
            if binsInRange < minBinsPerBand {
                let centerBin = (startBin + endBin) / 2
                startBin = max(0, centerBin - minBinsPerBand / 2)
                endBin = min(bufferSize / 2, startBin + minBinsPerBand)
            }
            
            let clampedStart = min(max(startBin, 0), (bufferSize / 2) - 1)
            let clampedEnd = min(max(endBin, clampedStart + 1), bufferSize / 2)
            
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
                bassBoost = 1.5
            } else if targetFreq < 500 {
                bassBoost = 1.3
            } else if targetFreq < 2000 {
                bassBoost = 1.1
            } else {
                bassBoost = 1.0 + (targetFreq / 10000.0) * 0.3
            }
            
            let weightedRMS = rms * bassBoost
            
            let db = 20 * log10(weightedRMS + 0.00001)
            let normalized = max(0, min(1, (db + 60) / 60))
            
            let smoothed = smoothedBands[i] * (1 - smoothingFactor) + normalized * smoothingFactor
            smoothedBands[i] = smoothed
            
            newBands.append(smoothed)
            let previousPeak = peakHolds.indices.contains(i) ? peakHolds[i] : 0
            newPeaks.append(max(smoothed, previousPeak - 0.01))
        }
        
        DispatchQueue.main.async {
            self.spectrumBands = newBands
            self.peakHolds = newPeaks
        }
    }
    
    private func processStereo(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let downsample = max(1, left.count / 50)
        var newLeft: [Float] = []
        var newRight: [Float] = []
        
        for i in stride(from: 0, to: left.count, by: downsample) {
            newLeft.append(left[i])
            newRight.append(right[i])
        }
        
        var correlation: Float = 0
        let dotProduct = vDSP.dot(left, right)
        let leftSumSq = vDSP.dot(left, left)
        let rightSumSq = vDSP.dot(right, right)
        let denominator = sqrt(leftSumSq * rightSumSq)
        
        if denominator > 0 {
            correlation = dotProduct / denominator
        }
        
        DispatchQueue.main.async {
            self.leftSamples = (self.leftSamples + newLeft).suffix(self.maxStereoPoints)
            self.rightSamples = (self.rightSamples + newRight).suffix(self.maxStereoPoints)
            self.phaseCorrelation = correlation
        }
    }
}
