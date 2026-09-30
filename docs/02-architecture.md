# 02 — Architecture

> Layering, dependency wiring, threading model, and the invariants you must not break.
> Read [01-getting-started-and-usage.md](01-getting-started-and-usage.md) first for what the app *is*; this doc is about *how it is put together*.

---

## 1. The one-screen mental model

Punches is a single-window SwiftUI app with **no navigation beyond one `NavigationStack`** and **no tab bar in the UIKit sense** — the three "tabs" are pages in a horizontal `TabView` swiped with a custom floating bar.

Everything else hangs off exactly two `ObservableObject` singletons injected at the root:

| Singleton | Declared | Injected | Owns |
|---|---|---|---|
| `AudioManager` | `audio_manager.swift:7` | `silly_speed.swift:8` → `:15` | library data, playback state, the engine, the analyser |
| `ThemeManager` | `View/setting_View.swift:903` | `silly_speed.swift:7` → `:14` | all 35 themes, all shader parameters |

```swift
// silly_speed.swift:6-33
struct SillySpeed: App {
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var audioManager = AudioManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environmentObject(audioManager)
                .onOpenURL { url in ... }              // punches:// deep link
                .onChange(of: scenePhase) { ... }       // pending-import drain
                .onAppear { preloadHaptics() }
        }
    }
}
```

> **Naming gotcha:** the `@main` struct is still `SillySpeed` and the entry file is still `silly_speed.swift` — leftovers from the project's former name. The product/module is `Punches3`. See [03-project-structure-and-build.md](03-project-structure-and-build.md).

---

## 2. Layer map

```
┌──────────────────────────────────────────────────────────────────────────┐
│ View/  (SwiftUI)                                                         │
│   content_view.swift · audio_player_view.swift · PlaylisList_view.swift  │
│   setting_View.swift (SettingsView) · SpectrumView.swift (DEAD)          │
│   ShaderEffects.swift (AppBackground + 4 stitchable shader wrappers)     │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ @EnvironmentObject, direct method calls
                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ audio_manager.swift — class AudioManager: NSObject, ObservableObject      │
│   @Published state (16 properties) + 30-line façade over 7 lazy services   │
└───┬───────────────────────────┬──────────────────────────┬───────────────┘
    │                           │                          │
    ▼                           ▼                          ▼
┌────────────────┐   ┌──────────────────────┐   ┌────────────────────────────┐
│ Services/*.swift│   │ audio_engine_protocol│   │ AudioMeters/               │
│ 7 classes, all │   │ protocol AudioEngine  │   │ UnifiedAudioAnalyser       │
│ hold           │   │ + EngineDebugMetrics │   │   (ObservableObject)       │
│ `unowned let  │   └──────────┬───────────┘   │ VisualisationMode          │
│  manager:`    │              │               │ goniometerManager (TOMB)    │
└────────┬───────┘              ▼               │ Q3SpectrumView   (MTKView)  │
         │              ┌────────────────┐     │ goniometerView   (MTKView)  │
         │              │AudioEngines/   │     │ Shaders.metal               │
         │              │AppleAudioEngine│     └────────────────────────────┘
         │              └────────┬───────┘
         │                       │
         │        ┌──────────────┴───────────────┐
         │        │  AVAudioEngine graph        │
         │        │  playerNode                 │
         │        │    → AVAudioUnitTimePitch   │
         │        │      → mainMixerNode ──tap──┼──► UnifiedAudioAnalyser
         │        │        → output             │
         │        └─────────────────────────────┘
         ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Data                                                                     │
│   Models.swift (AudioFile, Playlist, LibraryFilter, LibraryItem,         │
│                 ArtworkTarget)                                            │
│   <app-group container>/AudioFiles · /Artwork · /PendingImports          │
│   UserDefaults.standard (library + playlists + theme)                    │
│   UserDefaults(suiteName: "group.Cam.punches-ios") (share handoff)       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. The `AudioManager` façade and its 7 services

`AudioManager` is a **state container plus a pure delegation shell**. It holds *no* behaviour beyond `init`/`deinit`, `attachAnalyzerSafely`, and the `AVAudioPlayerDelegate` conformance. Every other method is a one-line forward.

```swift
// audio_manager.swift:39-45
lazy var engineService   = AudioEngineService(manager: self)
lazy var sessionService  = AudioSessionService(manager: self)
lazy var libraryService  = AudioLibraryService(manager: self)
lazy var playlistService = PlaylistService(manager: self)
lazy var artworkService  = ArtworkService(manager: self)
lazy var importService   = AudioImportService(manager: self)
lazy var playbackService = AudioPlaybackService(manager: self)
```

| Service | File | Responsibility |
|---|---|---|
| `AudioPlaybackService` | `Services/AudioPlaybackService.swift` | play/pause/stop/seek/skip, the 0.2 s progress timer, the 3 s "previous restarts" rule, tempo/pitch clamping, queue navigation, multi-select reorder |
| `AudioSessionService` | `Services/AudioSessionService.swift` | `AVAudioSession` category/activation, `MPRemoteCommandCenter` handlers, engine-config / interruption / route-change / lifecycle observers, `MPNowPlayingInfoCenter` |
| `AudioEngineService` | `Services/AudioEngineService.swift` | engine construction by `PitchAlgorithm`, algorithm persistence, hot-swap with playback-position restore |
| `AudioLibraryService` | `Services/AudioLibraryService.swift` | `AudioFile` load/save/delete/rename, orphan-file GC, unique filename generation, visualisation-mode persistence |
| `PlaylistService` | `Services/PlaylistService.swift` | `Playlist` load/save/CRUD, the hidden master playlist, ordering, sorted projections |
| `ArtworkService` | `Services/ArtworkService.swift` | JPEG encode/decode, artwork assignment to files and playlists, refcount-based cleanup |
| `AudioImportService` | `Services/AudioImportService.swift` | in-app document import (copy into container) and share-extension import drain (move out of `PendingImports`) |

### Pattern: `unowned let manager` service locator

Every service stores `unowned let manager: AudioManager` (e.g. `AudioPlaybackService.swift:6`) and reaches back through it for everything. `lazy var` on `AudioManager` breaks the retain cycle that would otherwise occur because the services strongly reference the manager.

**Consequence for you as a caller:** a service method frequently mutates several `@Published` properties across multiple services and expects to be on the main thread. Only two call sites bother to hop:

- `AudioManager.createPlaylist(name:)` wraps in `DispatchQueue.main.async` (`audio_manager.swift:167-169`) — **redundant**, since the call sites are on the main run loop; the working tree's `createAlbum` and `PlaylistService.createPlaylist` are synchronous
- `PlaylistService.reorderPlaylistSongs` defers its commit to `DispatchQueue.main.async` (`PlaylistService.swift:138-143`)

Everything else runs synchronously on whatever thread called in. In practice that is always the main thread because the call originates in a SwiftUI view body or button action. This is an unenforced invariant, not a guarantee.

### Pattern: lazy property creates a cycle at `init` time

`AudioManager.init` (`audio_manager.swift:73-107`) touches `libraryService`, `playlistService`, `engineService`, `sessionService` and `importService` in a fixed order. It also fires an **unstructured `Task`** partway through:

```swift
// audio_manager.swift:84-88
Task { [weak self] in
    guard let self else { return }
    await self.importService.processPendingImports()
    self.libraryService.cleanupOrphanedFiles()
}
```

That task races the rest of `init` (which goes on to set up the session and the engine). `processPendingImports` mutates `audioFiles`, `playlists`, `displayedSongs` and `playbackQueue` — and `init` sets `displayedSongs`/`playbackQueue` at `:82-83`, *after* spawning the task. Ordering is therefore unspecified on a cold launch that has pending share imports.

---

## 4. Threading model

Four distinct execution contexts carry audio data. Getting these confused is the fastest way to introduce a race or a realtime-thread stall.

| # | Context | Owner | What runs there | Protection |
|---|---|---|---|---|
| 1 | **Main actor** | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`project.pbxproj:585,624`) | all SwiftUI bodies, all `@Published` mutation, all `AudioManager` state, `UnifiedAudioAnalyser.updateSpectrum()` (driven by a main `Timer`), goniometer IIR filtering | implicit |
| 2 | **`audio.engine.queue`** | `DispatchQueue(label: "audio.engine.queue", qos: .userInitiated)` (`AudioEngines/AppleAudioEngine.swift:10`) | `load`, `play`, `stop`, `seek`, `setTempo`, `setPitch`, `scheduleBuffersIfNeeded`, and the `.dataPlayedBack` completion handlers | serial by construction |
| 3 | **Audio render thread** | `AVAudioEngine` | the `installTap` block → `UnifiedAudioAnalyser.writeToRingBuffer` | realtime — must not block, allocate unboundedly, or touch `@Published` |
| 4 | **Metal render thread** | `MTKView` delegate callback | `Q3MetalRenderer.draw(in:)`, `GoniometerMetalRenderer.draw(in:)` | `os_unfair_lock` in the goniometer; **none in Q3** |

### The 60 Hz main-thread display timer

`UnifiedAudioAnalyser` runs a `Timer` at `targetFPS = 60.0` (`UnifiedAudioAnalyser.swift:224, 286-293`) whose callback does all the FFT work and then dispatches results to main. Because the timer is scheduled on the main run loop, **the entire DSP chain runs on the main thread** and the render thread only receives finished vertex arrays. This is why a heavy `fftSize` increase is felt as UI jank rather than as audio dropout.

### Cross-thread handoff, precisely

```
render thread   main thread                      Metal render thread
─────────────   ───────────────────────────      ─────────────────────
installTap  ──► RingBuffer.write  (NSLock) ──► readLatest(fftSize)
   (L,R,mid,        │                            │
    side,mono)      ▼                            ▼
                @Published arrays          renderer snapshot
                (DispatchQueue.main.async)  (os_unfair_lock, goniometer only)
```

The goniometer is the only consumer with a lock (`AudioMeters/goniometerView.swift:249, 263, 311-316, 325-330`). `Q3MetalRenderer` writes `bands`, `peaks`, `enhancedMode`, `inspectFraction` from `updateUIView` on main and reads them in `draw(in:)` with no synchronisation (`AudioMeters/Q3SpectrumView.swift:153-156, 133-139, 234-284`). See [14-known-issues.md](14-known-issues.md#g2-unsynchronised-q3renderer-state).

---

## 5. `AudioEngineProtocol` — the swappable engine seam

```swift
// audio_engine_protocol.swift:17-35
protocol AudioEngineProtocol: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var onPlaybackFinished: (() -> Void)? { get set }

    func getAudioEngine() -> AVAudioEngine?
    func load(audioFile: AudioFile)
    func play(); func pause(); func stop()
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Float)
    func setTempo(_ tempo: Float)
    func setPitch(_ pitch: Float)
    var debugMetrics: EngineDebugMetrics { get }
}
```

`AudioEngineService.initialiseEngine()` (`Services/AudioEngineService.swift:11-21`) switches on `PitchAlgorithm` and assigns `manager.currentEngine`. There is **only one implementation**:

```swift
switch manager.selectedAlgorithm {
case .apple:      manager.currentEngine = AppleAudioEngine()
case .rubberBand: manager.currentEngine = nil   // not implemented
case .signalSmith:manager.currentEngine = nil   // not implemented
}
```

`PitchAlgorithm.isImplemented` (`pitch_algorithm.swift:8-15`) gates the UI and the restore-from-`UserDefaults` path (`AudioEngineService.swift:23-29`), so a persisted unimplemented value is silently ignored on load.

> **Gotcha:** `currentEngine` is `AudioEngineProtocol?` and is genuinely `nil` for `.rubberBand`/`.signalSmith`. Every consumer force-unwraps or `guard lets` it. If you ever expose those algorithms in the UI, playback will crash rather than degrade.

`EngineDebugMetrics` (`audio_engine_protocol.swift:5-15`) carries `starveCount`, `maxScheduledAhead`, `avgScheduleMs`, all `#if DEBUG` in `AppleAudioEngine` (`:288-298`, zeroed in Release). Consumed only by the DEBUG-only `AudioHealthHUD` (`AudioHealthHUD.swift:3-27`), which is **not referenced by any view** — see [14-known-issues.md](14-known-issues.md#d3-unused-audiohealthhud).

---

## 6. Engine swap choreography

`AudioEngineService.changeAlgorithm(to:)` (`Services/AudioEngineService.swift:35-71`) is the most delicate sequence in the app. It must not lose the user's position:

1. Snapshot `wasPlaying`, the current `AudioFile` (looked up by `currentlyPlayingID` in `audioFiles`), and `savedTime`.
2. `audioAnalyzer.detach(from: oldEngine)` — **mandatory**, because the analyser owns a tap on bus 0 of the old engine and the old engine is about to be discarded.
3. `manager.stop()`.
4. Assign the new algorithm, persist it, `initialiseEngine()`.
5. Re-`load`, re-wire `onPlaybackFinished`, re-apply `tempo` and `pitch`.
6. On main: `seek(to: savedTime)`, then `play` if it was playing.

Note `manager.duration` is *not* restored on this path, and the analyser is never re-attached to the new engine — a new tap only happens on the next `play(audioFile:)` via `attachAnalyzerSafely()` (`audio_manager.swift:261-269`).

---

## 7. Playback → analyser → visualiser chain

The complete path from a row tap to a redrawn goniometer:

```
AudioFileButton row tap                       content_view.swift:1337-1358
  └─ audioManager.play(audioFile:context:fromSongsTab:)      audio_manager.swift:242
       └─ AudioPlaybackService.play()          AudioPlaybackService.swift:12
            ├─ resolve playbackQueue from `context`         :15-19
            ├─ AVAudioSession.setCategory(.playback) + setActive(true)   :28-35
            ├─ engine.stop() / engine.load()                 :43-46
            ├─ engine.onPlaybackFinished = { skipNextSong() }  :47-49
            ├─ manager.attachAnalyzerSafely()                 :50
            │    └─ main.asyncAfter(+0.12) → analyzer.attach(to: engine)
            │         └─ main.asyncAfter(+0.15) → installTapSafely(on:)
            │              (isRunning? sampleRate>0? channelCount>0?
            │               removeTap(0) then installTap(0))
            ├─ engine.setTempo / setPitch / play              :51-54
            └─ startTimer()  (0.2 s progress + nowPlaying)    :117-138
                 │
                 ▼  audio render thread
       installTap block (bufferSize = hopSize = 2048)  UnifiedAudioAnalyser.swift:335-356
         └─ writeToRingBuffer(buffer)                             :391-419
              vDSP → mono, mid, side; 5 × RingBuffer.write (NSLock)
                 │
                 ▼  main thread, 60 Hz
       Timer → updateSpectrum()                                  :286, 423
         ├─ readLatest(8192) × 3 → processFFT(.standard/.mid/.side)  :426-433
         ├─ processQ3FFT()                                       :436, 589
         └─ updateStereoVisualization()                          :438, 702
              ↓ DispatchQueue.main.async → @Published arrays
         ┌────────────────────────────────────────┐
         │ GoniometerView  ← leftSamples,         │  goniometerView.swift:193-200
         │                    rightSamples,        │
         │                    phaseCorrelation     │
         │ Q3SpectrumView   ← q3SpectrumBands,     │  Q3SpectrumView.swift:133-139
         │                    q3PeakHolds,          │
         │                    q3EnhancedMode        │
         └────────────────────────────────────────┘
```

Three delays are stacked on the attach path (0.12 s + 0.15 s). They are not redundant: `installTap` on a stopped or unconfigured engine throws an **uncatchable ObjC exception**, so the guards in `installTapSafely` (`UnifiedAudioAnalyser.swift:319-331`) are load-bearing.

---

## 8. Invariants — do not break these

1. **Exactly one tap per `AVAudioMixerNode` bus.** `installTap` twice on bus 0 crashes uncatchably. This is why `AudioMeters/goniometerManager.swift` is a tombstone file with a 17-line warning at the top, and why `AudioEngineService.changeAlgorithm` must `detach` before replacing the engine. Never create a second component that taps the mixer.
2. **Never block or allocate in the tap callback.** It runs on the render thread. `writeToRingBuffer` is `private` for exactly this reason.
3. **`theme.*` writes fan out to `UserDefaults`.** `ThemeManager.apply(_:)` sets ~15 properties, each firing its own `didSet` → `UserDefaults.set`. Prefer mutating the specific property you need over calling `apply`.
4. **`AudioManager.fileDirectory` is a `static let`.** It is resolved once, at first access, using whatever the app-group entitlement state is at that moment. Changing entitlements requires a relaunch, not just a rebuild.
5. **`masterPlaylistID` must resolve to a `Playlist` in `playlists`.** `PlaylistService.loadOrCreateMasterPlaylist` (`PlaylistService.swift:93-115`) checks this and wipes all playlists + the key if it does not, then rebuilds. Anything that truncates `playlists` without preserving the master causes user-visible playlist loss.
6. **The main actor is the default isolation.** Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, implicitly-isolated types (`AudioManager`, `ThemeManager`, and all `View`s) are main-actor-bound. Explicit `DispatchQueue.async` in and out of services is therefore deliberate, not legacy.
7. **`playbackQueue` is context-dependent.** It is rebuilt from whichever list the user played *from* (`fromSongsTab`), and every reorder mutates it only when that flag matches. See [08-playlists-and-library.md](08-playlists-and-library.md#6-reordering).

---

## 9. Where to read next

| You want to… | Go to |
|---|---|
| Understand the DSP | [05-signal-analysis.md](05-signal-analysis.md) |
| Change buffering, seeking, or the engine graph | [04-audio-pipeline.md](04-audio-pipeline.md) |
| Change a Metal visual | [06-visualisation.md](06-visualisation.md) |
| Change a backdrop shader or theme | [10-theming-and-shaders.md](10-theming-and-shaders.md) |
| Add or rename a persisted value | [12-persistence-and-keys.md](12-persistence-and-keys.md) |
| Add a setting to the Settings screen | [11-settings-ui.md](11-settings-ui.md) |
| Build, sign, or fix the project | [03-project-structure-and-build.md](03-project-structure-and-build.md) |
| Know what is already broken | [14-known-issues.md](14-known-issues.md) |
