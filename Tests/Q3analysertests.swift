import Accelerate
@testable import silly_speed_ios
import XCTest

// MARK: - Q3AnalyserTests

/// Unit tests for the Q3 spectrum analyser path in `UnifiedAudioAnalyser`.
///
/// Add this file to the `silly_speed_iosTests` target ONLY — not the main app target.
/// The main app must include `UnifiedAudioAnalyser+Testing.swift`.
final class Q3AnalyserTests: XCTestCase {

  private var analyser: UnifiedAudioAnalyser!

  private let sampleRate: Float = 44100
  private let fftSize: Int = 8192

  override func setUp() {
    super.setUp()
    analyser = UnifiedAudioAnalyser()
  }

  override func tearDown() {
    analyser = nil
    super.tearDown()
  }

  // MARK: - Helpers

  private func peakBandIndex(_ bands: [Float]) -> Int {
    bands.indices.max(by: { bands[$0] < bands[$1] }) ?? 0
  }

  private func expectedBand(for frequency: Float) -> Int {
    let minLog = log10(Float(20))
    let maxLog = log10(Float(20_000))
    let fraction = (log10(frequency) - minLog) / (maxLog - minLog)
    return min(127, Int(fraction * 128))
  }

  // MARK: - 1. Silence produces near-zero bands

  func testSilenceProducesNearZeroBands() {
    let silence = [Float](repeating: 0.0, count: fftSize)
    let bands = analyser.q3BandsForTesting(samples: silence)

    XCTAssertEqual(bands.count, 128)
    for (index, value) in bands.enumerated() {
      XCTAssertLessThan(value, 0.05,
        "Band \(index) should be near zero for silence (got \(value))")
    }
  }

  // MARK: - 2. Full-scale sine approaches 0 dBFS

  func testFullScaleSineApproachesZeroDBFS() {
    let tone = UnifiedAudioAnalyser.sineWave(
      frequency: 1000, amplitude: 1.0, sampleRate: sampleRate, count: fftSize)
    let bands = analyser.q3BandsForTesting(samples: tone)
    let peak = bands.max() ?? 0

    XCTAssertGreaterThan(peak, 0.80,
      "Full-scale 1 kHz tone should produce a normalised peak > 0.80 (got \(peak))")
  }

  // MARK: - 3. Single tone frequency accuracy

  func testSingleToneFrequencyAccuracy() {
    let testFrequencies: [Float] = [50, 100, 200, 500, 1000, 2000, 5000, 10000]

    for freq in testFrequencies {
      let tone = UnifiedAudioAnalyser.sineWave(
        frequency: freq, sampleRate: sampleRate, count: fftSize)
      let bands = analyser.q3BandsForTesting(samples: tone)
      let detected = peakBandIndex(bands)
      let expected = expectedBand(for: freq)

      XCTAssertEqual(detected, expected, accuracy: 1,
        "Tone at \(freq) Hz: peak should be at band ~\(expected), got \(detected)")
    }
  }

  // MARK: - 4. Multitone — all tones resolved simultaneously

  func testMultitoneAllTonesResolved() {
    let testFrequencies: [Float] = [100, 1000, 10000]
    let signal = UnifiedAudioAnalyser.multitoneSigal(
      frequencies: testFrequencies, sampleRate: sampleRate, count: fftSize)
    let bands = analyser.q3BandsForTesting(samples: signal)

    for freq in testFrequencies {
      let expected = expectedBand(for: freq)
      let windowLo = max(0, expected - 3)
      let windowHi = min(127, expected + 3)
      let localPeak = bands[windowLo...windowHi].max() ?? 0

      XCTAssertGreaterThan(localPeak, 0.40,
        "Tone at \(freq) Hz not resolved. Expected local peak > 0.40 near band \(expected), got \(localPeak)")
    }
  }

  // MARK: - 5. All bands always in [0, 1]

  func testBandValuesAlwaysNormalised() {
    let stimuli: [[Float]] = [
      [Float](repeating: 0, count: fftSize),
      UnifiedAudioAnalyser.sineWave(frequency: 1000, amplitude: 1.0, sampleRate: sampleRate, count: fftSize),
      UnifiedAudioAnalyser.sineWave(frequency: 20, amplitude: 1.0, sampleRate: sampleRate, count: fftSize),
      UnifiedAudioAnalyser.sineWave(frequency: 18000, amplitude: 1.0, sampleRate: sampleRate, count: fftSize),
      (0..<fftSize).map { _ in Float.random(in: -1...1) },
    ]

    for (stimulusIndex, stimulus) in stimuli.enumerated() {
      let bands = analyser.q3BandsForTesting(samples: stimulus)
      for (bandIndex, value) in bands.enumerated() {
        XCTAssertGreaterThanOrEqual(value, 0.0,
          "Stimulus \(stimulusIndex), band \(bandIndex): value below 0 (\(value))")
        XCTAssertLessThanOrEqual(value, 1.0,
          "Stimulus \(stimulusIndex), band \(bandIndex): value exceeds 1 (\(value))")
      }
    }
  }

  // MARK: - 6. Band count is 128

  func testBandCountIs128() {
    let tone = UnifiedAudioAnalyser.sineWave(frequency: 1000, sampleRate: sampleRate, count: fftSize)
    let bands = analyser.q3BandsForTesting(samples: tone)
    XCTAssertEqual(bands.count, 128)
  }

  // MARK: - 7. A-weighting reference point (IEC 61672: 0 dB at 1 kHz)

  func testAWeightingIsZeroAtOneKHz() {
    let correction = analyser.aWeightingForTesting(frequency: 1000)
    XCTAssertEqual(Double(correction), 0.0, accuracy: 0.5,
      "A-weighting at 1 kHz should be ~0 dB per IEC 61672 (got \(correction) dB)")
  }

  func testAWeightingAttenuatesLowFrequencies() {
    let correction = analyser.aWeightingForTesting(frequency: 100)
    XCTAssertLessThan(Double(correction), -15.0,
      "A-weighting at 100 Hz should be strongly negative (got \(correction) dB)")
  }

  func testAWeightingBoostsMidHighFrequencies() {
    let at1k = analyser.aWeightingForTesting(frequency: 1000)
    let at3k = analyser.aWeightingForTesting(frequency: 3150)
    XCTAssertGreaterThan(Double(at3k), Double(at1k),
      "A-weighting at 3.15 kHz should be higher than at 1 kHz (\(at3k) vs \(at1k))")
  }

  func testAWeightingAttenuatesVeryHighFrequencies() {
    let at1k = analyser.aWeightingForTesting(frequency: 1000)
    let at18k = analyser.aWeightingForTesting(frequency: 18000)
    XCTAssertLessThan(Double(at18k), Double(at1k),
      "A-weighting at 18 kHz should be lower than at 1 kHz (\(at18k) vs \(at1k))")
  }

  // MARK: - 8. A-weighting shifts spectrum correctly

  func testAWeightingShiftsSpectrum() {
    let lowTone = UnifiedAudioAnalyser.sineWave(
      frequency: 100, sampleRate: sampleRate, count: fftSize)
    let midTone = UnifiedAudioAnalyser.sineWave(
      frequency: 1000, sampleRate: sampleRate, count: fftSize)

    let lowFlat = analyser.q3BandsForTesting(samples: lowTone, applyAWeighting: false)
    let lowWeighted = analyser.q3BandsForTesting(samples: lowTone, applyAWeighting: true)
    let midFlat = analyser.q3BandsForTesting(samples: midTone, applyAWeighting: false)
    let midWeighted = analyser.q3BandsForTesting(samples: midTone, applyAWeighting: true)

    XCTAssertLessThan(Double(lowWeighted.max() ?? 0), Double(lowFlat.max() ?? 0),
      "100 Hz tone should be attenuated by A-weighting")
    XCTAssertEqual(
      Double(midWeighted.max() ?? 0), Double(midFlat.max() ?? 0), accuracy: 0.04,
      "1 kHz tone level should be nearly unchanged by A-weighting")
  }

  // MARK: - 9. Ring buffer round-trip

  func testRingBufferRetainsLatestSamples() {
    let bufferSize = 64
    let ringBuffer = RingBuffer(capacity: bufferSize)
    let written = (0..<bufferSize).map { Float($0) }
    ringBuffer.write(written)
    let read = ringBuffer.readLatest(bufferSize)

    XCTAssertEqual(read.count, bufferSize)
    for i in 0..<bufferSize {
      XCTAssertEqual(read[i], written[i], accuracy: 1e-6,
        "Ring buffer mismatch at index \(i)")
    }
  }

  func testRingBufferHandlesOverflow() {
    let capacity = 32
    let ringBuffer = RingBuffer(capacity: capacity)
    let allSamples = (0..<capacity * 2).map { Float($0) }
    ringBuffer.write(allSamples)
    let latest = ringBuffer.readLatest(capacity)

    XCTAssertEqual(latest.count, capacity)
    for i in 0..<capacity {
      XCTAssertEqual(latest[i], Float(capacity + i), accuracy: 1e-6,
        "After overflow, ring buffer should return the most recent samples")
    }
  }

  // MARK: - 10. FrequencyMapper round-trip

  func testFrequencyMapperRoundTrip() {
    let testFrequencies: [Float] = [20, 100, 440, 1000, 5000, 10000, 20000]
    let width: Float = 1000

    for freq in testFrequencies {
      let x = FrequencyMapper.frequencyToX(freq, width: width)
      let recovered = FrequencyMapper.xToFrequency(x, width: width)
      let error = abs(freq - recovered) / freq
      XCTAssertLessThan(Double(error), 0.001,
        "FrequencyMapper round-trip error at \(freq) Hz: \(error * 100)%")
    }
  }

  func testFrequencyMapperBandCoverageIsComplete() {
    for i in 0..<128 {
      let freq = FrequencyMapper.bandIndexToFrequency(index: i, totalBands: 128)
      XCTAssertGreaterThanOrEqual(Double(freq), 20.0, "Band \(i): \(freq) Hz below 20 Hz")
      XCTAssertLessThanOrEqual(Double(freq), 20_000.0, "Band \(i): \(freq) Hz above 20 kHz")
    }
  }

  // MARK: - 11. White noise produces roughly uniform spectrum

  func testWhiteNoiseProducesRoughlyUniformSpectrum() {
    var accumulated = [Float](repeating: 0, count: 128)
    for _ in 0..<8 {
      let noise = (0..<fftSize).map { _ in Float.random(in: -1...1) }
      let bands = analyser.q3BandsForTesting(samples: noise)
      vDSP.add(accumulated, bands, result: &accumulated)
    }
    let averaged = vDSP.divide(accumulated, 8)
    let interior = Array(averaged[1..<127])
    let maxVal = interior.max() ?? 0
    let minVal = interior.filter { $0 > 0.01 }.min() ?? 0

    if minVal > 0 {
      let ratio = maxVal / minVal
      XCTAssertLessThan(Double(ratio), 5.0,
        "White noise spectrum is too uneven (max/min = \(ratio)). Check log-spacing.")
    }
  }

  // MARK: - 12. Tone is louder than silence

  func testToneExceedsSilence() {
    let silence = [Float](repeating: 0.0, count: fftSize)
    let tone = UnifiedAudioAnalyser.sineWave(
      frequency: 1000, amplitude: 0.5, sampleRate: sampleRate, count: fftSize)

    let silencePeak = analyser.q3BandsForTesting(samples: silence).max() ?? 0
    let tonePeak = analyser.q3BandsForTesting(samples: tone).max() ?? 0

    XCTAssertGreaterThan(tonePeak, silencePeak,
      "A 1 kHz tone should produce a higher peak than silence")
  }

  // MARK: - 13. Amplitude linearity (+6 dB per doubling)

  func testAmplitudeDoublingRaisesLevel() {
    let tone1 = UnifiedAudioAnalyser.sineWave(
      frequency: 1000, amplitude: 0.25, sampleRate: sampleRate, count: fftSize)
    let tone2 = UnifiedAudioAnalyser.sineWave(
      frequency: 1000, amplitude: 0.50, sampleRate: sampleRate, count: fftSize)

    let peak1 = analyser.q3BandsForTesting(samples: tone1).max() ?? 0
    let peak2 = analyser.q3BandsForTesting(samples: tone2).max() ?? 0
    let deltaNormalised = peak2 - peak1
    let expectedDelta: Float = 6.0 / 90.0  // ~0.067

    XCTAssertEqual(Double(deltaNormalised), Double(expectedDelta), accuracy: 0.03,
      "Doubling amplitude should raise level by ~6 dB " +
      "(expected Δ≈\(String(format: "%.3f", expectedDelta)), got \(String(format: "%.3f", deltaNormalised)))")
  }

  // MARK: - 14. Hann window suppresses spectral leakage

  func testHannWindowSuppressesLeakage() {
    // 997 Hz deliberately does not align with an FFT bin boundary.
    let offBinTone = UnifiedAudioAnalyser.sineWave(
      frequency: 997, sampleRate: sampleRate, count: fftSize)
    let bands = analyser.q3BandsForTesting(samples: offBinTone)
    let detected = peakBandIndex(bands)
    let expected = expectedBand(for: 997)

    XCTAssertEqual(detected, expected, accuracy: 1,
      "Off-bin 997 Hz tone: peak at band \(detected), expected ~\(expected). " +
      "Check Hann window is applied before FFT.")
  }
}
