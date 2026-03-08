import Accelerate
import AudioKit
import AVFoundation
import Combine
import Foundation

// MARK: - Lock-Free Ring Buffer

class RingBuffer {
  private var buffer: [Float]
  private var writeIndex: Int = 0
  private var readIndex: Int = 0
  private let capacity: Int
  private let lock = NSLock()

  init(capacity: Int) {
    self.capacity = capacity
    buffer = Array(repeating: 0, count: capacity)
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
    let startIndex = (writeIndex - count + capacity) % capacity

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

    attackCoeff = exp(-1.0 / (attackMs * 0.001 * sampleRate))
    releaseCoeff = exp(-1.0 / (releaseMs * 0.001 * sampleRate))
  }

  func process(_ input: Float) -> Float {
    let rectified = abs(input)

    if rectified > envelope {
      envelope = attackCoeff * envelope + (1.0 - attackCoeff) * rectified
    } else {
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
  let threshold: Float  // dB
  let ratio: Float
  let knee: Float  // dB

  init(threshold: Float = -12.0, ratio: Float = 4.0, knee: Float = 6.0) {
    self.threshold = threshold
    self.ratio = ratio
    self.knee = knee
  }

  func computeGainReduction(_ inputDB: Float) -> Float {
    if inputDB < (threshold - knee / 2.0) {
      return 0.0
    } else if inputDB > (threshold + knee / 2.0) {
      let excess = inputDB - threshold
      return excess * (1.0 - 1.0 / ratio)
    } else {
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
    avAudioNode = rawNode
  }
}

class UnifiedAudioAnalyser: ObservableObject {
  @Published var node: Node?

  // Standard stereo spectrum
  @Published var spectrumBands: [Float] = Array(repeating: 0.0, count: 32)
  @Published var peakHolds: [Float] = Array(repeating: 0.0, count: 32)

  // Mid/Side spectrum
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

  // MARK: Q3 Spectrum — accurate dBFS display path

  /// Number of log-spaced frequency bands used by the Q3 spectrum view.
  let q3BandCount = 128

  /// Per-band magnitude in normalised [0, 1] (0 = −90 dBFS, 1 = 0 dBFS).
  /// No compression or frequency weighting applied unless `q3EnhancedMode` is true.
  @Published var q3SpectrumBands: [Float] = Array(repeating: 0.0, count: 128)

  /// Per-band peak hold values in the same normalised scale as `q3SpectrumBands`.
  @Published var q3PeakHolds: [Float] = Array(repeating: 0.0, count: 128)

  /// When true the Q3 path applies an approximate A-weighting curve before
  /// normalising, matching the perceptual loudness weighting used by many
  /// professional analysers (amber colour mode in the view).
  @Published var q3EnhancedMode: Bool = false

  // MARK: FFT Configuration

  internal let fftSize: Int = 8192
  private let bandCount = 32
  private let maxStereoPoints = 100
  private let hopSize: Int
  private let overlapFactor: Float = 0.75

  // MARK: Ring buffers

  private var audioRingBuffer: RingBuffer
  private var leftRingBuffer: RingBuffer
  private var rightRingBuffer: RingBuffer
  private var midRingBuffer: RingBuffer
  private var sideRingBuffer: RingBuffer

  // MARK: FFT components

  internal var forwardDFT: vDSP.DiscreteFourierTransform<Float>?
  internal var window: [Float] = []

  // Shared working buffers (standard path)
  private var realBuffer: [Float]
  private var imagBuffer: [Float]

  // Working buffers for the Q3 path — separate to avoid clobbering the
  // standard path during concurrent timer callbacks.
  private var q3RealBuffer: [Float]
  private var q3ImagBuffer: [Float]

  // MARK: Processing state

  private var sampleRate: Float = 44100.0

  // Standard-path smoothing
  private var smoothedBands: [Float]
  private var smoothedMidBands: [Float]
  private var smoothedSideBands: [Float]
  private let attackTime: Float = 0.0
  private let releaseTime: Float = 0.15

  // Q3-path smoothing (no compression applied; 300 ms release for readability)
  private var q3SmoothedBands: [Float]
  private let q3ReleaseTime: Float = 0.30

  // Dynamic gain reduction (standard path only)
  private var envelopeFollowers: [EnvelopeFollower]
  private var gainComputers: [GainComputer]
  private let dynamicsEnabled: Bool = true

  // MARK: Display timer

  private var updateTimer: Timer?
  private let targetFPS: Double = 60.0

  // MARK: init

  init() {
    hopSize = Int(Float(fftSize) * (1.0 - overlapFactor))

    let ringBufferSize = fftSize * 4
    audioRingBuffer = RingBuffer(capacity: ringBufferSize)
    leftRingBuffer = RingBuffer(capacity: ringBufferSize)
    rightRingBuffer = RingBuffer(capacity: ringBufferSize)
    midRingBuffer = RingBuffer(capacity: ringBufferSize)
    sideRingBuffer = RingBuffer(capacity: ringBufferSize)

    realBuffer = [Float](repeating: 0, count: fftSize)
    imagBuffer = [Float](repeating: 0, count: fftSize)
    q3RealBuffer = [Float](repeating: 0, count: fftSize)
    q3ImagBuffer = [Float](repeating: 0, count: fftSize)

    smoothedBands = [Float](repeating: 0, count: 32)
    smoothedMidBands = [Float](repeating: 0, count: 32)
    smoothedSideBands = [Float](repeating: 0, count: 32)
    q3SmoothedBands = [Float](repeating: 0, count: 128)

    envelopeFollowers = (0..<32).map { _ in
      EnvelopeFollower(attackMs: 1.0, releaseMs: 100.0, sampleRate: 44100.0)
    }
    gainComputers = (0..<32).map { _ in
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

  // MARK: Display timer (60 fps)

  private func startGraphicsTimer() {
    updateTimer = Timer.scheduledTimer(
      withTimeInterval: 1.0 / targetFPS,
      repeats: true
    ) { [weak self] _ in
      self?.updateSpectrum()
    }
  }

  // MARK: Audio attachment

  func attach(to audioEngine: AVAudioEngine) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      self.attachTapAfterEngineStabilizes(audioEngine)
    }
  }

  private func attachTapAfterEngineStabilizes(_ audioEngine: AVAudioEngine) {
    node = MixerNodeWrapper(audioEngine.mainMixerNode)
    let mixer = audioEngine.mainMixerNode
    let format = mixer.outputFormat(forBus: 0)
    sampleRate = Float(format.sampleRate)
    mixer.removeTap(onBus: 0)

    mixer.installTap(
      onBus: 0,
      bufferSize: AVAudioFrameCount(hopSize),
      format: format
    ) { [weak self] buffer, _ in
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
      // Reset Q3 path
      self.q3SpectrumBands = Array(repeating: 0.0, count: self.q3BandCount)
      self.q3PeakHolds = Array(repeating: 0.0, count: self.q3BandCount)
      self.q3SmoothedBands = Array(repeating: 0.0, count: self.q3BandCount)
      self.leftSamples = []
      self.rightSamples = []
      self.midSamples = []
      self.sideSamples = []
      self.phaseCorrelation = 0.0
      self.node = nil
    }

    startGraphicsTimer()
  }

  // MARK: Audio thread — write to ring buffers

  private func writeToRingBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let frameLength = Int(buffer.frameLength)

    let leftPtr = channelData[0]
    let rightPtr = buffer.format.channelCount > 1 ? channelData[1] : leftPtr

    let left = Array(UnsafeBufferPointer(start: leftPtr, count: frameLength))
    let right = Array(UnsafeBufferPointer(start: rightPtr, count: frameLength))

    var mid = [Float](repeating: 0, count: frameLength)
    var side = [Float](repeating: 0, count: frameLength)
    var mono = [Float](repeating: 0, count: frameLength)

    vDSP.add(left, right, result: &mid)
    vDSP.divide(mid, 2.0, result: &mid)

    vDSP.subtract(right, left, result: &side)
    vDSP.divide(side, 2.0, result: &side)

    vDSP.add(left, right, result: &mono)
    vDSP.divide(mono, 2.0, result: &mono)

    audioRingBuffer.write(mono)
    leftRingBuffer.write(left)
    rightRingBuffer.write(right)
    midRingBuffer.write(mid)
    sideRingBuffer.write(side)
  }

  // MARK: Display thread — read and process at 60 fps

  private func updateSpectrum() {
    // Standard 32-band paths (with compression and weighting — used by
    // the existing spectrum / goniometer views)
    let monoSamples = audioRingBuffer.readLatest(fftSize)
    processFFT(samples: monoSamples, output: .standard)

    let midSamplesData = midRingBuffer.readLatest(fftSize)
    processFFT(samples: midSamplesData, output: .mid)

    let sideSamplesData = sideRingBuffer.readLatest(fftSize)
    processFFT(samples: sideSamplesData, output: .side)

    // Q3 accurate path — separate, unmodified dBFS
    processQ3FFT()

    updateStereoVisualization()
  }

  private enum FFTOutput {
    case standard, mid, side
  }

  private func processFFT(samples: [Float], output: FFTOutput) {
    let windowedSamples = vDSP.multiply(samples, window)
    var magnitudes = [Float](repeating: 0, count: fftSize)

    for i in 0..<fftSize { imagBuffer[i] = 0 }

    forwardDFT?.transform(
      inputReal: windowedSamples,
      inputImaginary: imagBuffer,
      outputReal: &realBuffer,
      outputImaginary: &imagBuffer)

    realBuffer.withUnsafeMutableBufferPointer { realPtr in
      imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
        var splitComplex = DSPSplitComplex(
          realp: realPtr.baseAddress!,
          imagp: imagPtr.baseAddress!)
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

      let envelope = envelopeFollowers[i].process(weightedRMS)
      let db = 20 * log10(envelope + 0.00001)
      let grDB = gainComputers[i].computeGainReduction(db)

      let reducedRMS = weightedRMS * pow(10, -grDB / 20.0)
      let reducedDB = 20 * log10(reducedRMS + 0.00001)
      let normalized = max(0, min(1, (reducedDB + 60) / 60))

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

      let previousPeak: Float
      switch output {
      case .standard: previousPeak = peakHolds.indices.contains(i) ? peakHolds[i] : 0
      case .mid: previousPeak = midPeakHolds.indices.contains(i) ? midPeakHolds[i] : 0
      case .side: previousPeak = sidePeakHolds.indices.contains(i) ? sidePeakHolds[i] : 0
      }

      newPeaks.append(max(finalSmoothed, previousPeak - 0.008))
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

  // MARK: Q3 accurate FFT path

  /// Processes a 128-band magnitude spectrum from the stereo (L+R) signal.
  ///
  /// Key differences from the standard path:
  /// - No per-band compression or gain reduction
  /// - No bass-boost weighting (flat unless `q3EnhancedMode` is true)
  /// - Peak-magnitude per band rather than RMS, giving a truer spectral picture
  /// - Full dBFS range: −90 to 0 dBFS mapped to [0, 1]
  /// - 300 ms release time (more legible than 150 ms for mixing reference use)
  private func processQ3FFT() {
    // Average L+R to mono for stereo-combined display
    let leftData = leftRingBuffer.readLatest(fftSize)
    let rightData = rightRingBuffer.readLatest(fftSize)

    var mono = [Float](repeating: 0, count: fftSize)
    vDSP.add(leftData, rightData, result: &mono)
    vDSP.divide(mono, 2.0, result: &mono)

    // Apply Hann window
    let windowed = vDSP.multiply(mono, window)

    // Zero imaginary input
    for i in 0..<fftSize { q3ImagBuffer[i] = 0 }

    // Forward FFT
    forwardDFT?.transform(
      inputReal: windowed,
      inputImaginary: q3ImagBuffer,
      outputReal: &q3RealBuffer,
      outputImaginary: &q3ImagBuffer)

    // Compute linear magnitudes for positive-frequency bins
    let halfSize = fftSize / 2
    var magnitudes = [Float](repeating: 0, count: halfSize)
    q3RealBuffer.withUnsafeMutableBufferPointer { realPtr in
      q3ImagBuffer.withUnsafeMutableBufferPointer { imagPtr in
        var split = DSPSplitComplex(
          realp: realPtr.baseAddress!,
          imagp: imagPtr.baseAddress!)
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
      }
    }

    // Normalise magnitudes relative to full-scale FFT amplitude
    let fftScale: Float = 1.0 / Float(halfSize)
    vDSP.multiply(fftScale, magnitudes, result: &magnitudes)

    let nyquist = sampleRate / 2.0
    let minFreqLog = log10(Float(20))
    let maxFreqLog = log10(Float(20_000))

    var newBands = [Float](repeating: 0, count: q3BandCount)
    var newPeaks = [Float](repeating: 0, count: q3BandCount)

    for i in 0..<q3BandCount {
      // Log-spaced band edges
      let loFraction = Float(i) / Float(q3BandCount)
      let hiFraction = Float(i + 1) / Float(q3BandCount)
      let loFreq = pow(10.0, minFreqLog + loFraction * (maxFreqLog - minFreqLog))
      let hiFreq = pow(10.0, minFreqLog + hiFraction * (maxFreqLog - minFreqLog))
      let centerFreq = sqrt(loFreq * hiFreq)

      // Map frequency range to FFT bin range
      let startBin = max(0, Int((loFreq / nyquist) * Float(halfSize)))
      let endBin = min(halfSize, max(startBin + 1, Int((hiFreq / nyquist) * Float(halfSize))))

      // Peak magnitude in this band — max is more representative than RMS for
      // spectrum display because it preserves transient and narrow-band content.
      var peakMag: Float = 0
      for bin in startBin..<endBin {
        if magnitudes[bin] > peakMag { peakMag = magnitudes[bin] }
      }

      // Convert to dBFS
      let dBFS = 20.0 * log10(max(peakMag, 1e-9))

      // Optional A-weighting correction
      let displayDB: Float = q3EnhancedMode
        ? dBFS + aWeighting(frequency: centerFreq)
        : dBFS

      // Normalise to [0, 1]: −90 dBFS → 0.0,  0 dBFS → 1.0
      let normalised = max(0.0, min(1.0, (displayDB + 90.0) / 90.0))

      // Temporal smoothing: instant attack, 300 ms release
      let current = q3SmoothedBands[i]
      let decayFactor = Float(1.0 / targetFPS) / q3ReleaseTime
      let smoothed = normalised >= current
        ? normalised
        : max(0.0, current - (current - normalised) * decayFactor)

      q3SmoothedBands[i] = smoothed
      newBands[i] = smoothed

      // Peak hold: slow decay (~0.004 per frame ≈ 4 s for full scale at 60 fps)
      let prevPeak = q3PeakHolds.indices.contains(i) ? q3PeakHolds[i] : 0.0
      newPeaks[i] = max(smoothed, prevPeak - 0.004)
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.q3SpectrumBands = newBands
      self.q3PeakHolds = newPeaks
    }
  }

  /// Returns an approximate A-weighting correction in dB for the given frequency.
  ///
  /// Implements the standard IEC 61672 A-weighting formula. The +2.0 dB offset
  /// normalises the curve to 0 dB at 1 kHz.
  internal func aWeighting(frequency: Float) -> Float {
    let f2 = frequency * frequency
    let numerator = (12_194.0 * 12_194.0) * (f2 * f2)
    let d1 = f2 + 20.6 * 20.6
    let d2 = sqrt(f2 + 107.7 * 107.7) * sqrt(f2 + 737.9 * 737.9)
    let d3 = f2 + 12_194.0 * 12_194.0
    let ra = numerator / (d1 * d2 * d3)
    return 20.0 * log10(max(ra, 1e-9)) + 2.00
  }

  // MARK: Stereo visualization update

  private func updateStereoVisualization() {
    let leftSamplesData = leftRingBuffer.readLatest(1024)
    let rightSamplesData = rightRingBuffer.readLatest(1024)
    let midSamplesData = midRingBuffer.readLatest(1024)
    let sideSamplesData = sideRingBuffer.readLatest(1024)

    let downsample = max(1, leftSamplesData.count / 50)
    var newLeft: [Float] = []
    var newRight: [Float] = []
    var newMid: [Float] = []
    var newSide: [Float] = []

    for i in stride(from: 0, to: leftSamplesData.count, by: downsample) {
      newLeft.append(leftSamplesData[i])
      newRight.append(rightSamplesData[i])
      newMid.append(midSamplesData[i])
      newSide.append(sideSamplesData[i])
    }

    var correlation: Float = 0
    if leftSamplesData.count == rightSamplesData.count && !leftSamplesData.isEmpty {
      let dotProduct = vDSP.dot(leftSamplesData, rightSamplesData)
      let leftSumSq = vDSP.dot(leftSamplesData, leftSamplesData)
      let rightSumSq = vDSP.dot(rightSamplesData, rightSamplesData)
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
