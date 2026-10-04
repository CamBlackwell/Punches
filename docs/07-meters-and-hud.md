# 07 — Meters & HUD

> The player screen's presentation layer: `VisualisationMode`, the three-way visualisation switch, the SwiftUI → Metal data hand-off, the re-render costs that come with it, and the two dead views (`SpectrumView`, `AudioHealthHUD`) that are still in the target.
> Companion: [05-signal-analysis.md](05-signal-analysis.md) (produces these values), [06-visualisation.md](06-visualisation.md) (renders them), [02-architecture.md](02-architecture.md) (the main-thread discipline behind all of it).

---

## 1. Files at a glance

| File | Lines | Live? |
|---|---|---|
| `View/audio_player_view.swift` | 327 | yes — the player screen |
| `AudioMeters/VisualisationMode.swift` | 30 | yes — the mode enum |
| `View/SpectrumView.swift` | 109 | **no — 0 call sites** |
| `AudioHealthHUD.swift` | 27 | **no — 0 call sites, `#if DEBUG`** |
| `AudioMeters/goniometerManager.swift` | 20 | **no — empty tombstone** (see [06](06-visualisation.md#5-audiometersgoniometermanagerswift--read-this-before-you-touch-the-tap)) |
| `AudioMeters/Q3SpectrumView.swift` | 570 | yes |
| `AudioMeters/goniometerView.swift` | 643 | yes |

---

## 2. `VisualisationMode`

```swift
// AudioMeters/VisualisationMode.swift:3-8
enum VisualisationMode: String, Codable, CaseIterable {
  //case both
  //case spectrumOnly
  case Goniometer
  case Artwork
  case Spectrum
}
```

| Case | Raw value | `icon` (`:10-18`) | `label` (`:21-29`) |
|---|---|---|---|
| `.Goniometer` | `"Goniometer"` | `circle` | `Goniometer` |
| `.Artwork` | `"Artwork"` | `photo` | `Art` |
| `.Spectrum` | `"Spectrum"` | `chart.bar.fill` | `Spectrum` |

The enum uses **CamelCase case names**, unlike every other enum in the project (`AppTheme`, `AppearanceMode`, `WaterQuality`, `PitchAlgorithm` all use lowerCamelCase). This is inherited from an older revision; renaming would break the persisted value.

Two cases are **commented out** (`:4-5`) along with their `icon` and `label` arms (`:12-13`, `:22-23`): `both` (a stacked spectrum + goniometer) and `spectrumOnly` (the old `SpectrumView` at full height). Both were superseded when `Q3SpectrumView` replaced `SpectrumView`. `both` is still wired up in commented form in `AudioPlayerView.visualisationView` (`View/audio_player_view.swift:49-63`).

> `Codable` conformance is declared (`:3`) but **never used** — the mode is persisted as a raw string in `UserDefaults`, not as JSON. The conformance is free but load-bearing-looking; don't let it mislead you into a JSON-migration plan.

### Persistence

| Step | Code |
|---|---|
| key | `let visualisationModeKey = "visualisationMode"` — `audio_manager.swift:31` (**not** `theme.`-prefixed, and not in the `ThemeKey` enum) |
| default | `@Published var visualisationMode: VisualisationMode = .Goniometer` — `audio_manager.swift:19` |
| load | `AudioLibraryService.loadVisualisationMode()` — `Services/AudioLibraryService.swift:129-134` |
| save | `audioManager.saveVisualisationMode()` → `libraryService.saveVisualisationMode()` — `audio_manager.swift:112-114`, `AudioLibraryService.swift:136-138` |
| load on init | `libraryService.loadVisualisationMode()` — `audio_manager.swift:86` |

`loadVisualisationMode` is a `string(forKey:)` → `VisualisationMode(rawValue:)` round-trip with a silent no-op if either side fails (`:130-133`).

> **⚠️ The UI writes but nothing re-reads on change.** The picker calls `audioManager.saveVisualisationMode()` (`View/content_view.swift:302`) so the choice survives relaunch. But `apply` is never called on a mode change — switching modes does not touch the engine, the analyser, or the ring buffers. The analyser's 60 Hz timer and the tap keep running in every mode, including `.Artwork` where nothing is displayed. See [14-known-issues.md](14-known-issues.md).

---

## 3. The mode picker

`View/content_view.swift:297-312`, inside the toolbar. It only appears when `libraryFilter == .player`, and it is mutually exclusive with the other three toolbar states (`:285-323`):

```swift
} else if libraryFilter == .player {
    ForEach(VisualisationMode.allCases, id: \.self) { mode in
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                audioManager.visualisationMode = mode
                audioManager.saveVisualisationMode()
            }
        } label: {
            Image(systemName: mode.icon)
                .foregroundStyle(audioManager.visualisationMode == mode
                                 ? theme.accentColor : theme.secondaryTextColor)
        }
    }
}
```

- `ForEach` is over `allCases`, so **the picker order follows the enum declaration order**: `Goniometer`, `Artwork`, `Spectrum` — not alphabetical, and not the `icon`-sorted order you might expect.
- Selected state is indicated **only by colour** — accent vs. secondary text. There is no checkmark, no capsule, no border.
- `icon` is used; `label` (`:21-29`) is **never used anywhere in the app**. It is dead code. Accessibility would benefit from it, but nothing currently reads it.
- `.easeInOut(duration: 0.3)` cross-fades, but every visualisation attaches `.transition(.scale.combined(with: .opacity))` — and since the switch is inside a `switch` in a `@ViewBuilder`, the transitions only animate if the switch itself is inside the `withAnimation` block, which it is not (the `withAnimation` wraps the *state mutation*, and the renderer's `transition` only participates if the enclosing view is inside a transaction — in practice this works, but it is fragile).

---

## 4. `AudioPlayerView`

`View/audio_player_view.swift:4-38`. Structure:

```
ZStack {
    Color.clear
    VStack(spacing: 8) {
        visualisationView          // flexes to fill
        Spacer()
        //tempoControl            // ← commented out, :22
        pitchControl
        timeSlider
        playbackControls
    }
    .padding()
}
```

Dependencies: `let audioFile: AudioFile`, `@ObservedObject var audioManager: AudioManager`, `@EnvironmentObject var theme: ThemeManager`. Hardcoded `.preferredColorScheme(.dark)` at `:31` — **the player screen ignores `appearanceMode` entirely**, so a light-theme user still gets a dark nav bar here.

`currentFile` (`:40-44`) is a *derived* value: it looks up `audioManager.audioFiles` by `currentlyPlayingID` and **falls back to the `audioFile` passed in**. This is how the screen follows playback when the user starts a different song from the Songs tab. `onChange(of: audioManager.currentlyPlayingID)` (`:33-37`) resets `sliderValue` to 0 when the current track changes, but only `if let newID = newID, newID != currentFile.id` — so **pausing/stopping (newID == nil) leaves the stale slider position**, and if the new ID *is* the current file the reset is skipped.

### 4.1 `visualisationView` (`:46-96`)

A `@ViewBuilder` `switch` over `audioManager.visualisationMode`:

| Case | View | Frame | Notes |
|---|---|---|---|
| `.Goniometer` | `GoniometerView(analyzer: audioManager.audioAnalyzer)` | `maxHeight: .infinity` | `:65-68` |
| `.Spectrum` | `Q3SpectrumView(analyser: audioManager.audioAnalyzer)` | `maxWidth: .infinity` | `:70-73` |
| `.Artwork` | `Image(uiImage:)` or a "No artwork" placeholder | `maxHeight: .infinity` | `:75-94` |

Note the **inconsistent argument labels between the two Metal views**: `GoniometerView(analyzer:)` takes `analyzer:` (American spelling, `goniometerView.swift:22`) while `Q3SpectrumView(analyser:)` takes `analyser:` (British, `Q3SpectrumView.swift:28`). The analyser class itself is `UnifiedAudioAnalyser` (British). This is a live inconsistency, not a typo I can safely fix — both labels are part of the public surface.

`.Artwork` (`:76-94`) reads `currentFile.artworkImageName`, then `audioManager.artworkService.loadArtworkImage(name)` (a **synchronous** disk read + UIImage decode, on the main thread, inside `body`). Fallback is a 60 pt `photo` glyph at `theme.secondaryTextColor.opacity(0.5)` over a "No artwork" label.

> **⚠️ Artwork decoding is not cached at this call site.** `loadArtworkImage` runs on every `body` evaluation, and `body` re-evaluates at up to 60 Hz whenever any observed object publishes. See `Services/ArtworkService.swift` and §6.

### 4.2 Transport controls (`:172-228`)

Two rows in a `ZStack`:

| Row | Controls |
|---|---|
| top `HStack(spacing: 40)` | `backward.fill` (`.title`, `theme.accentColor`) → 70 pt `Circle` play/pause → `forward.fill` (`.title`, `theme.accentColor`, **disabled when `audioFiles.count < 2`**) |
| bottom `HStack` | trailing repeat button: `repeat.1` when looping else `repeat`, 18 pt bold, `theme.accentColor` when looping else `theme.secondaryTextColor`, clipped to a `Circle` |

All four use `PlainButtonStyle()`, so there is **no press feedback** — the play button and skip buttons give no visual response to touch.

The play/pause button (`:182-192`) branches on identity:

```swift
if audioManager.audioFiles.isEmpty { return }
if audioManager.currentlyPlayingID == currentFile.id { audioManager.togglePlayPause() }
else { audioManager.play(audioFile: currentFile) }
```

so tapping the centre button on a *non-current* track starts that track rather than toggling.

The glyph is `isThisFilePlaying ? "pause.fill" : "play.fill"` (`:198`) where `isThisFilePlaying = audioManager.isPlaying && audioManager.currentlyPlayingID == currentFile.id` (`:98-100`) — so the icon is correct for "another track is playing", showing `play.fill` for the file you are looking at.

### 4.3 `timeSlider` (`:138-170`)

- Range `0...max(audioManager.duration, 0.01)` — the `max` avoids an illegal `0...0` range when duration is 0/NaN.
- `.disabled(audioManager.currentlyPlayingID == nil)`.
- `onEditingChanged` sets `isDragging`; on release calls `audioManager.seek(to: sliderValue)`. **Seeking only happens on release**, never during the drag.
- `onChange(of: audioManager.currentTime)` mirrors into `sliderValue` **only `if !isDragging`** (`:152-156`) — the standard guard that stops the timer fighting the user's finger.
- `.onAppear { sliderValue = audioManager.currentTime }` seeds the initial position.
- Two caption labels below, `formatTime` = `m:ss` via `String(format: "%d:%02d", …)` (`:102-106`). **The total-duration label uses `audioManager.duration`, not `currentFile`'s** — if they disagree (e.g. the file passed in differs from what's playing), the slider and its labels will be inconsistent.
- `.tint(theme.accentColor)`.

### 4.4 `pitchControl` (`:268-304`) and the dead `tempoControl`

`pitchControl` is live. Range `-2400...2400`, displayed as `audioManager.pitch / 100` semitones, endpoint labels `-2 oct` / `Normal` / `+2 oct`, with a reset button calling `setPitch(0.0)`.

`tempoControl` (`:230-266`) is **identical in structure but commented out of the view tree** at `:22`. Consequences:

- `audioManager.tempo` and `setTempo(_:)` are unreachable from the UI.
- Tempo never survives a relaunch because nothing can change it and it is not persisted — see [12-persistence-and-keys.md](12-persistence-and-keys.md).
- `resetTempoButton` (`:306-315`) is still compiled, but its only caller (`tempoControl`) is not rendered. It is dead code, not dead code the compiler can see.

> **Range bug in both:** the labels claim `0.1x … 2.0x` for tempo and `-2 oct … +2 oct` for pitch, but the actual slider ranges are `0.1...1.9` (`:248`) and `-2400...2400` (`:286`). The tempo slider's maximum label is wrong (1.9x, not 2.0x), and the tempo label row's spacing (`Spacer()` twice) is evenly split, so the centre "1.0x" label sits at 50 % of the width while the actual 1.0x value is at `(1.0-0.1)/(1.9-0.1) = 50 %` — correct by coincidence for tempo, and **correct for pitch too** since 0 is the midpoint of −2400…2400.

---

## 5. The SwiftUI → Metal hand-off

Both Metal views follow the same shape. This is the whole contract:

```
UnifiedAudioAnalyser  ──(Timer, 60 Hz, main queue)──▶  @Published arrays
                                                              │
                                    ┌─────────────────────────┘
                                    ▼
                    @ObservedObject var analyzer/analyser
                                    │
                    body re-evaluates  ──▶  UIViewRepresentable.updateUIView
                                    │                (main thread)
                                    ▼
                          renderer property copy
                                    │
                    draw(in:)  ◀── MTKView @ 60 fps  (Metal render thread)
```

### 5.1 The publish side

`UnifiedAudioAnalyser` is `class UnifiedAudioAnalyser: ObservableObject` (`UnifiedAudioAnalyser.swift:123`) — **not** `@MainActor`. Its display path is a `Timer.scheduledTimer(withTimeInterval: 1.0 / targetFPS)` (`:287-292`) that calls `updateSpectrum()`, which ends in a `DispatchQueue.main.async` (`:733-739`) that assigns:

```swift
self.leftSamples  = (self.leftSamples  + newLeft).suffix(self.maxStereoPoints)
self.rightSamples = (self.rightSamples + newRight).suffix(self.maxStereoPoints)
self.midSamples   = (self.midSamples   + newMid).suffix(self.maxStereoPoints)
self.sideSamples  = (self.sideSamples  + newSide).suffix(self.maxStereoPoints)
self.phaseCorrelation = correlation
```

- `maxStereoPoints = 400` (`:175`) — *"Increased to 400 so the Metal goniometer renderer has enough scatter density to produce a visually dense Lissajous plot at 60 fps"* (`:173-174`).
- The four sample arrays are assigned with **`.suffix(400)`**, i.e. `ArraySlice` not `Array`. Swift's `+` on two arrays is O(n) and `.suffix` is O(1) (a view), so each of the 4 assignments allocates and copies up to 400 floats — **4 allocations + up to 1600 element copies, 60×/s**, purely to build the observation payload. `midSamples` and `sideSamples` are never read by any view.
- Stereo points are downsampled to ~50 new samples per tick: `let downsample = max(1, leftSamplesData.count / 50)` over a 1024-sample ring read (`:705-719`).
- `phaseCorrelation` is the normalised dot product `dot(L,R) / sqrt(dot(L,L) · dot(R,R))` via `vDSP.dot` (`:721-731`), left at `0` if the channel counts differ or the buffer is empty.

### 5.2 The consume side

| | Goniometer | Q3 Spectrum |
|---|---|---|
| property | `@ObservedObject var analyzer` (`:22`) | `@ObservedObject var analyser` (`:28`) |
| reads | `leftSamples`, `rightSamples`, `phaseCorrelation` | `q3SpectrumBands`, `q3PeakHolds`, `q3EnhancedMode` |
| `updateUIView` | `updateSamples(left:analyzer.leftSamples, right:analyzer.rightSamples, zoom:zoomGain, sampleRate:Float(AVAudioSession.sharedInstance().sampleRate))` (`:194-199`) | `r.bands = analyser.q3SpectrumBands; r.peaks = analyser.q3PeakHolds; r.enhancedMode = analyser.q3EnhancedMode; r.inspectFraction = inspectFraction.map(Float.init)` (`:133-139`) |
| work done in `updateUIView` | **the whole IIR band split, on main** (`:280-317`) | none — 4 plain property copies |
| `Coordinator` | `final class Coordinator { let renderer = GoniometerMetalRenderer() }` (`:202-204`) | identical shape (`:141-143`) |

Both use the **identical `makeUIView` configuration** (`goniometerView.swift:175-191`, `Q3SpectrumView.swift:115-131`): 60 fps, `isPaused = false`, `enableSetNeedsDisplay = false`, `framebufferOnly = true`, `isOpaque = false`, clear colour `(0,0,0,0)`, and `guard let device = MTLCreateSystemDefaultDevice() else { return view }` — a nil GPU device yields a **silent, permanently blank** view rather than a fallback.

The Q3 path is the well-behaved one: `updateUIView` does no work, so its main-thread cost is 3 retains. The goniometer path is the problem — see below.

> **`updateUIView` is main-thread and not cheap on the goniometer path.** Each call runs 4 first-order IIR filters over ~400 samples (`:297-309`) and allocates **6 new `[Float]` arrays of 400 elements** (`:290-295`), then copies them into the renderer under a lock. Because `updateUIView` runs once per `body` evaluation, and `body` re-evaluates on *any* `@Published` change on `analyzer` — including `phaseCorrelation`, which changes every tick — the IIR pass runs at least 60×/s. Since the IIR state (`_lp300L` etc., `:274-275`) is updated here, the filter's effective cutoff is a function of the **UI refresh rate**, not the audio rate. If the UI drops frames, the filters get applied to fewer samples per second and the band split degrades. This is the most important structural issue in the presentation layer.

> **`AVAudioSession.sharedInstance().sampleRate` is read from `updateUIView`** (`goniometerView.swift:198`). That's a synchronising call into the audio session on the main thread, on every body evaluation. It is also redundant: the analyser already stores `sampleRate` (`:332`, set from the tap's format).

> `AVAudioSession.sharedInstance()` is the *new* API; the older `sharedInstance()` vs `AVAudioSession.sharedInstance()` naming aside, this is the correct modern spelling. The Q3 view needs no session access at all.

---

## 6. Re-render cost — the thing to know before you touch this

`AudioPlayerView` observes **two** objects: `audioManager` (`@ObservedObject`) and `theme` (`@EnvironmentObject`). `theme` is only read inside `pitchControl`, `timeSlider` and `playbackControls`, but `@EnvironmentObject` invalidates the **whole** view on any `ThemeManager` publish — and `ThemeManager.apply` fires ~20 `@Published` mutations in a row (see [10](10-theming-and-shaders.md#23-apply_--why-shader-params-are-conditional)). So opening Settings and picking a theme invalidates the player screen 20+ times in one runloop turn.

`GoniometerView` and `Q3SpectrumView` each add a second observation: `@ObservedObject var analyzer/analyser`. Between them, the two views re-evaluate on **~11 array/scalar `@Published` changes per 60 Hz tick** from the analyser.

The practical consequences, in order of severity:

1. **`midSamples` / `sideSamples` / `midSpectrumBands` / `sideSpectrumBands` / `midPeakHolds` / `sidePeakHolds` / `gainReduction` / `spectrumBands` / `peakHolds` are all `@Published` and all still being written every tick** — but **no live view reads any of them.** Each write is an `objectWillChange` that invalidates both meter views, for data nobody looks at. The only consumers of analyser `@Published` state anywhere in the app are `q3SpectrumBands`, `q3PeakHolds`, `q3EnhancedMode`, `leftSamples`, `rightSamples` and `phaseCorrelation`. That is **6 of the analyser's 18 `@Published` properties** (16 in a release build, since `tapCallbackMaxUs`/`tapOverrunCount` are `#if DEBUG`); the other 12 are pure re-render tax.
2. **The goniometer's IIR filtering runs on the main thread, inside `updateUIView`, at UI refresh rate** (§5.2). Moving it into the analyser (or a background queue) is the single highest-value fix in the presentation layer.
3. **`.Artwork` re-decodes a `UIImage` from disk on every body evaluation** (`audio_player_view.swift:76-77`).
4. `MTKView.isPaused = false` with `enableSetNeedsDisplay = false` (`goniometerView.swift:182-183`, `Q3SpectrumView.swift:122-123`) means **both renderers redraw at 60 fps even when the audio is stopped and all values are zero.** Nothing in either view checks `analyzer` for "is there signal" before drawing.

---

## 7. The two dead views

### 7.1 `SpectrumView` — 109 lines, 0 call sites

`View/SpectrumView.swift`. The **only** references anywhere are three commented-out lines in `View/audio_player_view.swift:51, 61`.

It is the pre-Q3 implementation and is superseded in every respect:

| | `SpectrumView` | `Q3SpectrumView` |
|---|---|---|
| renderer | SwiftUI `Canvas` (`:28-62`) | Metal |
| bands | `analyzer.spectrumBands` — 32 | `analyzer.q3SpectrumBands` — 128 |
| scale | raw `magnitude` × height (`:33`) | dBFS-normalised via `dBToY` |
| colour | MiniMeters 4-step thresholds: >0.85 red, >0.6 yellow, >0.3 green, else blue (`:42-50`) | flat cyan / A-weighted amber gradient palette |
| peak hold | `peakHolds` white bar, 2 pt tall (`:55-60`) | `q3PeakHolds` tick at 40 % band width, skipped below 0.012 |
| grid | separate `FrequencyGridOverlay` at 100 Hz / 1k / 5k / 10k (`:83-108`) | drawn in Metal at 10 log positions |
| A-weighting | none | `q3EnhancedMode` |
| inspect | none | tap/drag hairline + readout |

`FrequencyGridOverlay` (`:83-108`) is the **fifth** independent log-frequency mapping in the project (see [05](05-signal-analysis.md#9-three-incompatible-frequencyband-conventions)):

```swift
let xPercent = log10(freq / 20.0) / log10(20000.0 / 20.0)   // :90
```

Two more defects if you ever revive it:

- `for (label, freq) in freqs` with `ForEach(…, id: \.1)` — the id is the *frequency*, which is fine, but `freqs` is a `let` on the struct (`:84`) so it's reallocated per init.
- The `minimetersGradient` (`:11-20`) is **defined and never used** — the bars use the hardcoded `if/else` colours instead. Another dead declaration.
- `@State private var time` + `let timer` (`:7-8`) drives a 60 Hz `time` that **nothing reads** (`:78`).

The honest options are: delete the file, or un-comment and migrate the `FrequencyGridOverlay` into `Q3AxisLabels`. Leaving it costs nothing at runtime but invites someone to "restore" it.

### 7.2 `AudioHealthHUD` — 27 lines, 0 call sites, `#if DEBUG`

`AudioHealthHUD.swift:3-27`. Wrapped in `#if DEBUG` (`:3`) and never instantiated. It is the only intended consumer of the engine's debug telemetry.

It reads five metrics, all of which **are** live and all of which are wired up:

| Row | Source |
|---|---|
| `Engine Starves: N` | `manager.currentEngine?.debugMetrics.starveCount` — `AudioEngines/AppleAudioEngine.swift:379` |
| `Max Scheduled Ahead: N` | `debugMetrics.maxScheduledAhead` — `:379` |
| `Avg Schedule: %.2f ms` | `debugMetrics.avgScheduleMs` — `:379`, an EWMA updated at `:253-255` |
| `Tap Max: %.0f µs` | `manager.audioAnalyzer.tapCallbackMaxUs` — `UnifiedAudioAnalyser.swift:352` |
| `Tap Overruns: N` | `manager.audioAnalyzer.tapOverrunCount` — `:353` |

and the plumbing behind them is intact:

```swift
// audio_engine_protocol.swift:5-13
public struct EngineDebugMetrics {
    public let starveCount: Int
    public let maxScheduledAhead: Int
    public let avgScheduleMs: Double
}
```

`AppleAudioEngine` maintains the three counters privately (`:23-25`), bumps `debug_starveCount` in the render-path completion handler (`:233`, using `&+=` so it can't trap), tracks the high-water mark of scheduled buffers (`:217-218`), and updates the EWMA with `debug_ewmaAlpha` (`:253-255`). `debugMetrics` returns zeros when the engine isn't the Apple one (`:379`).

The analyser measures the tap callback with `mach_absolute_time` around `writeToRingBuffer` and **hops to the main queue** to publish (`:340-355`), with a `tapOverrunThresholdUs = 1000` (1 ms) budget (`:149`).

> **⚠️ The tap-metrics block has a real defect: `mach_timebase_info` is called on *every* tap callback** (`:346-347`) to convert absolute-time units to nanoseconds. That is a syscall-ish lookup in the real-time audio thread, in the one place you must not do work. Hoist it to a `static let` initialised once.
>
> Also, the two `if` statements at `:352-353` are *inside* the `DispatchQueue.main.async` closure, so a main-queue hop is enqueued **per tap buffer** (2048 frames ≈ 46 ms at 44.1 kHz) purely to maybe update two debug numbers. And `tapCallbackMaxUs` is `@Published`, so a new high-water mark re-invalidates both meter views.

Wiring the HUD back up is a 3-line change (add `AudioHealthHUD()` to the player's `ZStack`), but it needs `@ObservedObject var manager: AudioManager` to be reachable and it will re-render at 60 Hz because of §6.2.

---

## 8. Change checklist

| If you change… | Re-verify |
|---|---|
| a `VisualisationMode` case | add it to the enum *and* to `visualisationView`'s `switch` (`audio_player_view.swift:48-95`); the picker and persistence are automatic via `allCases` / `rawValue` |
| a `VisualisationMode` raw value | every existing user's `"visualisationMode"` string in `UserDefaults` |
| the observation surface of `AudioPlayerView` | the 6 live analyser properties in §6.1 (`UnifiedAudioAnalyser.swift:139-143, 159-167`) — touching any of the other 12 adds re-render cost with no benefit |
| `maxStereoPoints` (400) | goniometer scatter density *and* the per-tick allocation cost in §5.1; also the `// 150 most-recent points` comment at `goniometerView.swift:242` is already stale |
| the goniometer IIR coefficients | they are applied at UI refresh rate, not audio rate — see §5.2 before tuning `a300`/`a3k` |
| `targetFPS` | the publish rate for the *whole* analyser, including the goniometer's input |
| `preferredColorScheme(.dark)` at `audio_player_view.swift:31` | it hardcodes the player's appearance; removing it makes the player follow `theme.appearanceMode` |
| the `.Artwork` mode | `loadArtworkImage` is a synchronous disk read inside `body` |
| `phaseCorrelation` | it is a `@Published` that changes every tick and is read by the goniometer's bar *and* nothing else — moving it off `@Published` would remove one re-render trigger per tick |
