# 05 — Signal Analysis

> The full DSP chain: tap → ring buffers → FFT → bands → published arrays. Two different spectrum paths exist with different scalings; knowing which is which is the single most useful thing in this file.
> Companion: [04-audio-pipeline.md](04-audio-pipeline.md) (where the samples come from), [06-visualisation.md](06-visualisation.md) (where they go).

---

## 1. Configuration constants

All in `AudioMeters/UnifiedAudioAnalyser.swift`.

| Constant | Value | Line | Meaning |
|---|---|---|---|
| `fftSize` | `8192` | `:171` | both FFT paths |
| `bandCount` | `32` | `:172` | standard/mid/side path only |
| `q3BandCount` | `128` | `:155` | Q3 path only |
| `overlapFactor` | `0.75` | `:177` | Hann-windowed FFT overlap |
| `hopSize` | `Int(8192 * 0.25)` = **2048** | `:229` | also the tap `bufferSize` |
| `maxStereoPoints` | `400` | `:175` | goniometer scatter cap |
| `targetFPS` | `60.0` | `:224` | main-thread timer rate |
| `attackTime` | `0.0` s | `:209` | standard path smoothing |
| `releaseTime` | `0.15` s | `:210` | standard path smoothing |
| `q3ReleaseTime` | `0.30` s | `:214` | Q3 path smoothing |
| `dynamicsEnabled` | `true` | `:219` | standard path gain reduction (declared, never read) |
| `tapOverrunThresholdUs` | `1000.0` | `:149` | DEBUG overrun trip point |
| FFT window | `.hanningDenormalized` | `:276-281` | non-periodic Hann, `isHalfWindow: false` |

### Derived numbers worth knowing

- **Bin width** = `sampleRate / fftSize` ≈ **5.383 Hz** at 44.1 kHz.
- **Frequency resolution** is ~5.4 Hz, but the 20 Hz–20 kHz range only has ~3720 usable positive bins, so 128 log-spaced bands map to **~29 bins per band** on average — comfortably above the 1-bin minimum. The minimum-band guard (`minBinsPerBand = 3`, `:486-492`) only exists for the 32-band path.
- **Band 127 is above Nyquist** for 44.1 kHz. `processQ3FFT` clamps `endBin` to `halfSize` (`:644`), so the top band is always silent. This is why the test helper uses `min(127, ...)`.
- **75 % overlap** means the tap delivers a buffer every 2048 frames ≈ 46.4 ms at 44.1 kHz, but the display timer reads every 16.7 ms. The timer therefore re-analyses the same tail several times between taps; peak-hold and the 300 ms release are what keep that from looking steppy.

---

## 2. `RingBuffer` — the audio↔display boundary

`UnifiedAudioAnalyser.swift:10-45`.

```swift
class RingBuffer {
  private var buffer: [Float]
  private var writeIndex = 0
  private let capacity: Int
  private let lock = NSLock()          // ← NOT lock-free
}
```

| Member | Behaviour |
|---|---|
| `write(_ samples: [Float])` | element-by-element, `writeIndex = (writeIndex + 1) % capacity`, under `NSLock` |
| `readLatest(_ count: Int) -> [Float]` | reads backwards from `writeIndex`; `startIndex = (writeIndex - count + capacity) % capacity` |

Five instances are created, each `fftSize * 4 = 32768` floats (`:231-235`):

| Buffer | Contents | Consumer |
|---|---|---|
| `audioRingBuffer` | `(L + R) / 2` | standard 32-band spectrum |
| `midRingBuffer` | `(L + R) / 2` | mid spectrum (identical content to above) |
| `sideRingBuffer` | `(R − L) / 2` | side spectrum |
| `leftRingBuffer` | `L` | Q3 FFT, goniometer |
| `rightRingBuffer` | `R` | Q3 FFT, goniometer, correlation |

> **Gotcha — the `// MARK: - Lock-Free Ring Buffer` comment at `:8` is wrong.** The implementation uses `NSLock`. The `os_unfair_lock` mentioned in the top-level `README.md:47` refers to the *goniometer view's* cross-thread handoff, not this. Don't trust either label.

> **Gotcha — `readLatest` never signals underrun.** If fewer than `count` samples have been written since the ring was last read, it returns zeros (or stale data) without indicating which. On the first frames after attaching a tap, the spectrum will show noise from the `Array(repeating: 0, ...)` initialiser mixed with garbage-free zeros — it converges within one FFT window.

### Write path — `writeToRingBuffer(_:)` (`:391-419`)

Runs on the **audio render thread**:

```swift
let leftPtr  = channelData[0]
let rightPtr = buffer.format.channelCount > 1 ? channelData[1] : leftPtr   // mono → duplicate L

let left  = Array(UnsafeBufferPointer(start: leftPtr,  count: frameLength))
let right = Array(UnsafeBufferPointer(start: rightPtr, count: frameLength))

vDSP.add(left, right, result: &mid);  vDSP.divide(mid,  2.0, result: &mid)
vDSP.subtract(right, left, result: &side); vDSP.divide(side, 2.0, result: &side)
vDSP.add(left, right, result: &mono); vDSP.divide(mono, 2.0, result: &mono)
```

- **Mono files are duplicated to stereo** (`:396`) so downstream code never has to branch. The goniometer for a mono file therefore shows a perfect vertical line, which is the correct Lissajous for identical channels.
- Four heap allocations per tap (2048 floats × 4). At ~21.5 taps/second that is ~86 allocations/second on the render thread. It works, but it is the single most allocation-heavy thing on the realtime path. A preallocated scratch buffer would be the natural optimisation.
- The `(L+R)/2` and `(R−L)/2` coefficients are the **standard mid/side definition without the √2 normalisation**. This is intentional — it means side is exactly 6 dB below mid for a hard-panned mono source, which is the convention mixing engineers expect from a goniometer.

---

## 3. Tap installation — the crash guards

```swift
// :306-316
func attach(to audioEngine: AVAudioEngine,
            generation: Int = 0,
            isCurrent: @escaping () -> Bool = { true }) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self else { return }
        guard isCurrent() else { return }     // cancelled by a newer song
        self.installTapSafely(on: audioEngine)
    }
}
```

`installTapSafely` (`:319-357`) has four sequential guards, each preventing a different uncatchable ObjC exception:

| Guard | Line | Prevents |
|---|---|---|
| `audioEngine.isRunning` | `:321` | `installTap` on a stopped engine |
| `format.sampleRate > 0` | `:327` | tapping an unconfigured mixer (sample rate 0) |
| `format.channelCount > 0` | `:327` | same, for channel count |
| `mixer.removeTap(onBus: 0)` before installing | `:330` | a second tap on bus 0 |

> **`generation` is a dead parameter.** It is documented at `:301-303` as "unused here; the `isCurrent` closure is the actual cancellation gate", and `AudioManager.attachAnalyzerSafely()` (`audio_manager.swift:238-245`) calls `attach(to:)` with both defaults. Nothing bumps a generation counter.

`isCurrent` is the correct cancellation primitive: it lets a stale deferred attach from song A abort when song B has already been requested. Nothing currently passes a non-trivial closure, so it always returns `true` — which means **rapid track-skipping can leave a tap installed on a discarded engine's mixer** (harmless, since that engine is released, but it means `detach` is only called from `AudioEngineService.changeAlgorithm`).

The DEBUG timing wrapper (`:340-355`) measures `writeToRingBuffer` with `mach_absolute_time` and reports `tapCallbackMaxUs` / `tapOverrunCount` to the main queue. Overruns are counted above 1000 µs.

---

## 4. The two spectrum paths

`updateSpectrum()` (`:423-439`) runs four FFTs per 60 Hz tick, on the **main thread**:

```swift
processFFT(samples: audioRingBuffer.readLatest(fftSize), output: .standard)
processFFT(samples: midRingBuffer.readLatest(fftSize),   output: .mid)
processFFT(samples: sideRingBuffer.readLatest(fftSize),  output: .side)
processQ3FFT()
updateStereoVisualization()
```

| | **Standard path** (`processFFT`, `:445-577`) | **Q3 path** (`processQ3FFT`, `:589-684`) |
|---|---|---|
| Bands | 32 | 128 |
| Input | mono / mid / side ring buffer | `(L + R) / 2` recomputed from left+right |
| Per-band statistic | **RMS** over the bin range | **peak magnitude** in the bin range |
| Band edges | `minFreq`→`maxFreq` at `i/32` and `(i+1)/32` | `i/128` and `(i+1)/128` |
| Band width floor | `minBinsPerBand = 3` (`:486-492`) | none — `max(startBin+1, …)` (`:644`) |
| Frequency weighting | **bass boost**, piecewise (`:508-517`) | none unless `q3EnhancedMode` |
| Dynamics | `EnvelopeFollower` + `GainComputer` (4:1, −12 dB, 6 dB knee) | none |
| dB reference | `20·log10(envelope + 1e-5)`, then reduced dB | `20·log10(max(peakMag, 1e-9))` |
| Normalisation | `(reducedDB + 60) / 60` → `[0,1]` (`:527`) | `(displayDB + 90) / 90` → `[0,1]` (`:662`) |
| Smoothing | attack 0, release 150 ms (`:209-210`) | instant attack, release 300 ms (`:214`) |
| Peak-hold decay | `prevPeak - 0.008` per frame ≈ 6.7 s (`:559`) | `prevPeak - 0.004` per frame ≈ 4 s (`:676`) |
| Displayed by | nothing live (see below) | `Q3SpectrumView` |

> **The standard 32-band path has no live consumer.** Its outputs `spectrumBands`, `midSpectrumBands`, `sideSpectrumBands`, `peakHolds` and `gainReduction` are read only by `View/SpectrumView.swift:32`, which is itself unreachable (its only two call sites are commented out at `View/audio_player_view.swift:51, 61`). So **three of the four FFTs executed at 60 Hz are computing arrays nobody draws.** The obvious optimisation is to gate `processFFT(.standard/.mid/.side)` behind a flag, which would cut main-thread DSP work by roughly 75 %. See [14-known-issues.md](14-known-issues.md#g4-three-ffts-per-frame-with-no-consumer).

### The standard path's bass boost (`:508-517`)

| `targetFreq` | Multiplier |
|---|---|
| `< 200` Hz | `1.8` |
| `< 500` Hz | `1.4` |
| `< 2000` Hz | `1.15` |
| `≥ 2000` Hz | `1.0 + (targetFreq / 10000) * 0.4` → 1.08 at 2 kHz, 1.4 at 10 kHz |

### The standard path's gain computer

`GainComputer.computeGainReduction(_:)` (`:97-109`) is a textbook soft-knee compressor curve, applied **per band**:

```
input < threshold − knee/2   → 0 dB
input > threshold + knee/2   → excess · (1 − 1/ratio)
otherwise (in knee)          → scale²·(knee/2) · (1 − 1/ratio),  scale = (input − threshold + knee/2)/knee
```

Defaults `threshold = -12.0`, `ratio = 4.0`, `knee = 6.0` (`:91`). The result is subtracted in the linear domain (`:525`, `× 10^(−gr/20)`), so it is genuine gain reduction, not a display curve.

`EnvelopeFollower` (`:49-82`) is a one-pole attack/release follower with coefficient `exp(−1 / (t_ms · 0.001 · fs))`, `attackMs = 1.0`, `releaseMs = 100.0`, hard-coded to 44 100 Hz at construction (`:248-250`) **even if the actual session runs at 48 kHz**. The time constants are therefore ~9 % short on a 48 kHz device.

---

## 5. `processQ3FFT` in detail (`:589-684`)

```
mono   = (leftData + rightData) / 2                     vDSP
window = vDSP.multiply(mono, window)                    Hann
fft    = forwardDFT.transform(window, zeros → q3Real/q3Imag)
mags   = vDSP_zvabs(q3Real, q3Imag)                     first fftSize/2 bins
mags  *= 1 / (fftSize/2)                                fftScale, :624
```

`fftScale = 1.0 / Float(halfSize)` (`:624`) normalises so a full-scale sine's peak bin lands near 1.0, i.e. ~0 dBFS.

Per band (`:634-677`):

```
loFreq = 10^(minFreqLog + (i/128)   · (maxFreqLog − minFreqLog))
hiFreq = 10^(minFreqLog + ((i+1)/128)· (maxFreqLog − minFreqLog))
centerFreq = sqrt(loFreq · hiFreq)                              ← geometric centre
startBin = max(0, Int((loFreq/nyquist) · halfSize))
endBin   = min(halfSize, max(startBin+1, Int((hiFreq/nyquist) · halfSize)))

peakMag  = max(magnitudes[startBin ..< endBin])                 ← peak, not RMS
dBFS     = 20 · log10(max(peakMag, 1e-9))
displayDB = q3EnhancedMode ? dBFS + aWeighting(centerFreq) : dBFS
normalised = clamp((displayDB + 90) / 90, 0, 1)
```

Peak rather than RMS is a deliberate choice, documented at `:645-647`: it preserves transients and narrow-band content instead of averaging them away.

Smoothing (`:664-671`) is instant attack with a linear decay:

```swift
let decayFactor = Float(1.0 / targetFPS) / q3ReleaseTime      // ≈ 0.0556
let smoothed = normalised >= current
    ? normalised
    : max(0.0, current - (current - normalised) * decayFactor)
```

Results are published on main (`:679-683`). The tap→publish latency is therefore at most one 16.7 ms timer tick.

---

## 6. A-weighting

```swift
// :690-698
internal func aWeighting(frequency: Float) -> Float {
    let f2 = frequency * frequency
    let numerator = (12_194.0 * 12_194.0) * (f2 * f2)
    let d1 = f2 + 20.6 * 20.6
    let d2 = sqrt(f2 + 107.7 * 107.7) * sqrt(f2 + 737.9 * 737.9)
    let d3 = f2 + 12_194.0 * 12_194.0
    let ra = numerator / (d1 * d2 * d3)
    return 20.0 * log10(max(ra, 1e-9)) + 2.00
}
```

The standard IEC 61672 / IEC 1672 curve. The `+ 2.00` dB offset normalises the curve to **0 dB at 1 kHz**, which is what `testAWeightingIsZeroAtOneKHz` asserts (`Tests/Q3analysertests.swift:134-138`).

Toggled by `q3EnhancedMode` (`:167`), bound to the `A-WT` / `FLAT` button in `Q3SpectrumView` (`AudioMeters/Q3SpectrumView.swift:62-83`) and persisted nowhere — it resets every launch.

---

## 7. Stereo visualisation (`:702-740`)

```swift
let leftSamplesData  = leftRingBuffer.readLatest(1024)     // NOT fftSize
let rightSamplesData = rightRingBuffer.readLatest(1024)
let midSamplesData   = midRingBuffer.readLatest(1024)
let sideSamplesData  = sideRingBuffer.readLatest(1024)

let downsample = max(1, leftSamplesData.count / 50)         // 1024/50 = 20
// → ~51 new points per tick
```

On main, the four arrays are appended and truncated:

```swift
self.leftSamples = (self.leftSamples + newLeft).suffix(maxStereoPoints)   // 400
```

So the goniometer always renders the **most recent ~400 points**, which at 51 points/tick and 60 ticks/s is a ~130 ms rolling window. This is what produces the trail/density rather than a single instantaneous dot.

### Phase correlation (`:721-731`)

```
correlation = vDSP.dot(L, R) / sqrt( vDSP.dot(L,L) · vDSP.dot(R,R) )
```

Guarded by a length-equality check and `denominator > 0` (`:722, 728`). Range is −1 … +1; negative values mean the channels will partially cancel when summed to mono. Displayed by the bar under the goniometer (`AudioMeters/goniometerView.swift:81-123`, mapping `(x + 1) / 2` onto a red→orange→yellow→green gradient).

> **Gotcha:** the correlation is computed from the raw 1024-sample read, but the goniometer itself is fed the 400-point suffix that includes *older* samples appended earlier. So the correlation describes a different (shorter, newer) window than the plot. Also, the value is only written when `leftSamplesData.count == rightSamplesData.count`, which holds for stereo and for the mono-duplication path, but the fallback is `0` (silence-looking) rather than `+1` (mono).

---

## 8. Detach and reset (`:359-387`)

`detach(from:)`:
1. `mainMixerNode.removeTap(onBus: 0)`
2. `updateTimer?.invalidate()`
3. On main: zero **every** published array, all smoothing arrays, all ring-buffer-derived sample arrays, `phaseCorrelation`, and `node`
4. `startGraphicsTimer()` — **restarts the 60 Hz timer immediately**

> **Gotcha:** step 4 means the 60 Hz timer is restarted but no tap is installed, so the analyser keeps doing four FFTs per frame on zeros for the whole time between `detach` and the next `attach`. During `AudioEngineService.changeAlgorithm` that window is short, but if you ever `detach` without re-attaching, this is a permanent 100 % main-thread DSP cost. The `guard audioEngine.isRunning` in `installTapSafely` means the tap is frequently *not* installed on the first attempt, which makes this window routine rather than exceptional.

---

## 9. Three incompatible frequency↔band conventions

This is the highest-value thing to know in this file. The project contains three separate implementations of "which frequency is band *i*", and they do not agree.

| # | Location | Formula | Band 0 | Band 127 | Correct for |
|---|---|---|---|---|---|
| **1** | `UnifiedAudioAnalyser.swift:636-640` and `+Testing.swift:57-61` | `lo = 10^(minLog + (i/128)·range)`, `hi` at `(i+1)/128` | [20, 21.1) Hz | [20 000, 21 000) Hz | **FFT bin aggregation** — needs edges to slice bins |
| **2** | `Tests/FrequencyAllignmenttest.swift:16-20` `FrequencyMapper.bandIndexToFrequency` | `index / (totalBands - 1)` | 20 Hz exactly | 20 000 Hz exactly | **Display** — needs centres that span the axis |
| **3** | `Tests/Q3analysertests.swift:25-32` `expectedBand(for:)` | `Int(fraction · 128)` where `fraction = (log10 f − log10 20)/(log10 20000 − log10 20)` | 20 Hz | 20 000 Hz | **Test expectations only** |

Differences and their consequences:

- **Convention 1 is half a band offset from 2 and 3.** Its bands are *edges*; convention 2's are *centres*. For 128 bands over 3 decades, half a band is 1.5 % of the log range ≈ a 4.5 % frequency error at 1 kHz.
- **Convention 1's top band is above Nyquist** (21 kHz > 22.05 kHz is under, but its bin range is clamped, so it is always silent at any rate). `Q3MetalRenderer` independently maps its axis to 20 Hz–20 kHz (`AudioMeters/Q3SpectrumView.swift:302-304`), so the rightmost visible band is effectively dead.
- **`FrequencyMapper` is documented as the "central source of truth"** and is instructed to be used "in BOTH UnifiedAudioAnalyser and Q3MetalRenderer" (`Tests/FrequencyAllignmenttest.swift:6-7`). **Neither of those files imports or uses it.** There is no `Q3MetalRenderer` reference in the project at all. It is aspirational documentation in a file that is itself not a test.
- **`Q3MetalRenderer` has its own fourth copy** of the log mapping, in `freqToX` / `bandToX` (`AudioMeters/Q3SpectrumView.swift:290-304`).

**Recommendation:** adopt `FrequencyMapper` as the single source, move it out of `Tests/` into the app target, and make `processQ3FFT` slice bins from `bandFrequencyRange(index:totalBands:)` (`FrequencyAllignmenttest.swift:37-51`) rather than recomputing log edges inline. That single change removes three of the four implementations and fixes the half-band offset.

---

## 10. Published output surface

Everything a view can read, and where it goes.

| Property | Type / count | Written at | Read by |
|---|---|---|---|
| `spectrumBands`, `peakHolds`, `gainReduction` | `[Float]` × 32 | `:563-576` | `View/SpectrumView.swift:32` **(dead)** |
| `midSpectrumBands`, `midPeakHolds` | `[Float]` × 32 | `:569-570` | nothing |
| `sideSpectrumBands`, `sidePeakHolds` | `[Float]` × 32 | `:572-573` | nothing |
| `q3SpectrumBands` | `[Float]` × 128 | `:679-683` | `Q3SpectrumView` (`Q3SpectrumView.swift:134`) |
| `q3PeakHolds` | `[Float]` × 128 | `:679-683` | `Q3SpectrumView` (`:135`) |
| `q3EnhancedMode` | `Bool` | UI toggle | `Q3SpectrumView` (`:136`), read by `processQ3FFT` (`:657`) |
| `leftSamples`, `rightSamples` | `[Float]` ≤ 400 | `:733-737` | `GoniometerView` (`goniometerView.swift:194-195`) |
| `midSamples`, `sideSamples` | `[Float]` ≤ 400 | `:733-737` | **nothing** — the goniometer re-derives its own bands in Swift |
| `phaseCorrelation` | `Float` | `:738` | `GoniometerView` (`goniometerView.swift:198`) |
| `node` | `Node?` (`MixerNodeWrapper`) | `:333`, cleared `:383` | nothing — AudioKit's `Node` subclass is a vestige |
| `tapCallbackMaxUs`, `tapOverrunCount` | `Double`, `Int` | `:350-354` (DEBUG) | `AudioHealthHUD` (**not mounted**) |

> **Gotcha — the AudioKit dependency is vestigial.** `import AudioKit` at `:2` exists only for `Node` (a protocol `MixerNodeWrapper` conforms to at `:114-121`) and `@Published var node: Node?` (`:124`), which nothing reads. The actual DSP is 100 % `Accelerate`/`vDSP`. If the AudioKit SPM dependency is removed, the analyser needs exactly one type deleted. See [14-known-issues.md](14-known-issues.md#g5-audiokit-dependency-is-vestigial).

---

## 11. Test-support surface

`AudioMeters/UnifiedAudioAnalyser+Testing.swift` (113 lines) exposes `internal` hooks so the DSP can be tested without a live `AVAudioEngine`:

| Symbol | Signature | Purpose |
|---|---|---|
| `q3BandsForTesting` | `(samples: [Float], sampleRate: Float = 44100, applyAWeighting: Bool = false) -> [Float]` | synchronous reimplementation of the Q3 path **without** smoothing or peak-hold. `precondition(samples.count == fftSize)` (`:25`) |
| `aWeightingForTesting` | `(frequency: Float) -> Float` | thin wrapper over `aWeighting(frequency:)` |
| `sineWave` | `static (frequency: Float, amplitude: Float = 1.0, sampleRate: Float = 44100, count: Int = 8192) -> [Float]` | deterministic stimulus |
| `multitoneSigal` | `static (frequencies: [Float], …) -> [Float]` | sum of sines, each at `1.0 / count` so the peak stays ≤ 1.0. **Note the typo: `Sigal`, not `Signal`** |

> This file **ships in the app target** — it is not `#if DEBUG`-gated. That is deliberate (the test file's doc comment says "The main app must include `UnifiedAudioAnalyser+Testing.swift`") but it does mean `internal` test hooks are present in release builds. Wrapping it in `#if DEBUG` would break the test target unless that target also defines `DEBUG`, which it does by default.

The full behavioural contract these hooks encode — 19 tests with exact numeric expectations — is documented in [13-concurrency-and-threading.md](13-concurrency-and-threading.md).
