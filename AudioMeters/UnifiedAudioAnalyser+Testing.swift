import Accelerate
import Foundation

// MARK: - Test Support
// This extension exposes internal entry points for unit testing.
// None of these methods should be called from production code paths.
extension UnifiedAudioAnalyser {

  /// Runs the Q3 FFT pipeline synchronously on the provided mono samples and
  /// returns the raw normalised band values without temporal smoothing or peak hold.
  ///
  /// This exists solely to allow `Q3AnalyserTests` to drive the signal processing
  /// logic directly without requiring a live `AVAudioEngine` or audio session.
  ///
  /// - Parameters:
  ///   - samples: Mono PCM samples. Must be exactly `fftSize` (8192) elements.
  ///   - sampleRate: The sample rate to use for bin-to-frequency mapping.
  ///   - applyAWeighting: Whether to apply A-weighting before normalising.
  /// - Returns: Array of `q3BandCount` (128) values in [0, 1].
  internal func q3BandsForTesting(
    samples: [Float],
    sampleRate: Float = 44100,
    applyAWeighting: Bool = false
  ) -> [Float] {
    precondition(samples.count == fftSize, "samples must have exactly fftSize elements")

    var localReal = [Float](repeating: 0, count: fftSize)
    var localImag = [Float](repeating: 0, count: fftSize)

    let windowed = vDSP.multiply(samples, window)
    for i in 0..<fftSize { localImag[i] = 0 }

    forwardDFT?.transform(
      inputReal: windowed,
      inputImaginary: localImag,
      outputReal: &localReal,
      outputImaginary: &localImag)

    let halfSize = fftSize / 2
    var magnitudes = [Float](repeating: 0, count: halfSize)
    localReal.withUnsafeMutableBufferPointer { realPtr in
      localImag.withUnsafeMutableBufferPointer { imagPtr in
        var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
      }
    }

    let fftScale: Float = 1.0 / Float(halfSize)
    vDSP.multiply(fftScale, magnitudes, result: &magnitudes)

    let nyquist = sampleRate / 2.0
    let minFreqLog = log10(Float(20))
    let maxFreqLog = log10(Float(20_000))
    var bands = [Float](repeating: 0, count: q3BandCount)

    for i in 0..<q3BandCount {
      let loFraction = Float(i) / Float(q3BandCount)
      let hiFraction = Float(i + 1) / Float(q3BandCount)
      let loFreq = pow(10.0, minFreqLog + loFraction * (maxFreqLog - minFreqLog))
      let hiFreq = pow(10.0, minFreqLog + hiFraction * (maxFreqLog - minFreqLog))
      let centerFreq = sqrt(loFreq * hiFreq)

      let startBin = max(0, Int((loFreq / nyquist) * Float(halfSize)))
      let endBin = min(halfSize, max(startBin + 1, Int((hiFreq / nyquist) * Float(halfSize))))

      var peakMag: Float = 0
      for bin in startBin..<endBin {
        if magnitudes[bin] > peakMag { peakMag = magnitudes[bin] }
      }

      let rawDB = 20.0 * log10(max(peakMag, 1e-9))
      let displayDB = applyAWeighting ? rawDB + aWeighting(frequency: centerFreq) : rawDB
      bands[i] = max(0.0, min(1.0, (displayDB + 90.0) / 90.0))
    }

    return bands
  }

  /// Returns the A-weighting correction in dB for a given frequency.
  /// Exposed internally so tests can verify the IEC 61672 reference point (0 dB at 1 kHz).
  internal func aWeightingForTesting(frequency: Float) -> Float {
    aWeighting(frequency: frequency)
  }

  /// Generates a mono sine wave at the given frequency and amplitude.
  /// Used by tests as a deterministic audio stimulus.
  internal static func sineWave(
    frequency: Float,
    amplitude: Float = 1.0,
    sampleRate: Float = 44100,
    count: Int = 8192
  ) -> [Float] {
    (0..<count).map { n in
      amplitude * sin(2.0 * .pi * frequency * Float(n) / sampleRate)
    }
  }

  /// Generates a multitone signal — the sum of several sine waves at the given
  /// frequencies, each normalised so the combined peak amplitude stays ≤ 1.0.
  internal static func multitoneSigal(
    frequencies: [Float],
    sampleRate: Float = 44100,
    count: Int = 8192
  ) -> [Float] {
    let amplitude = 1.0 / Float(frequencies.count)
    var signal = [Float](repeating: 0, count: count)
    for freq in frequencies {
      let tone = sineWave(frequency: freq, amplitude: amplitude, sampleRate: sampleRate, count: count)
      vDSP.add(signal, tone, result: &signal)
    }
    return signal
  }
}
