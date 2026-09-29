# 13 — Concurrency & Threading

Every thread boundary in Punches, and where each one is sound. The short version: **the isolation model is invisible in the source**, the **real-time thread allocates**, and two documented safeguards do not exist in the code they describe.

---

## 1. The model in one paragraph

Punches is nominally single-threaded. There is no actor, no `Sendable` conformance anywhere in the repository, and no custom `DispatchQueue` for state — the only named queue is `audio.engine.queue` inside `AppleAudioEngine` (`AudioEngines/AppleAudioEngine.swift:10`). All application state lives in `@MainActor`-isolated classes by virtue of a build setting, and the only genuine parallelism is three: the AVAudioEngine render/tap thread, a 60 Hz `Timer` on the main run loop, and a handful of `DispatchQueue.main.async` hops.

```
  ┌───────────────────────┐
  │ AVAudioEngine RT      │  installTap callback — real-time priority
  │   writeToRingBuffer   │  2048 frames ≈ 47 Hz
  └───────────┬───────────┘
              │  NSLock (RingBuffer)
  ┌───────────▼───────────┐
  │ Main thread           │  Timer @ 60 Hz → updateSpectrum()
  │   FFT / Q3 / goniometer│  → @Published → SwiftUI render
  │   AudioManager, services, ThemeManager, all views
  └───────────────────────┘
```

That split — capture on the RT thread, analyse on main — is the correct architecture. [§4](#4-the-real-time-thread-allocates) is about the work it does before reaching the lock.

---

## 2. Isolation comes from a build setting, not the source

```objc
// Punches3.xcodeproj/project.pbxproj:585, :624
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
```

This is the load-bearing setting for the whole codebase, and it is invisible in the source files. Grepping the entire repository:

| Annotation | Occurrences |
|---|---|
| `@MainActor` on a **type** | **0** |
| `@MainActor` on a **method** | 2 |
| `nonisolated` | 0 |
| `actor` declaration | 0 |
| `@Sendable` | 0 |
| `@unchecked Sendable` | 0 |
| `MainActor.assumeIsolated` | 0 |
| `withCheckedContinuation` | 1 |
| `withCheckedThrowingContinuation` | 1 |

The two method annotations:

- `ContentView.preloadViews()` — `View/content_view.swift:110`
- `AudioManager.attachAnalyzerSafely()` — `audio_manager.swift:238`

> **Consequence for readers and for tooling.** `AudioManager`, `UnifiedAudioAnalyser`, `RingBuffer`, `PlaylistService`, `ThemeManager` and every view in the app are all main-actor-isolated, yet `class RingBuffer` (`:9`) and `class UnifiedAudioAnalyser` read as plain unannotated Swift. Nothing in the file tells you so. Jump-to-definition gives you no hint that a type is main-actor-bound, and moving code between types will produce isolation errors that have no visible cause in the diff. This is a legitimate trade-off for a SwiftUI app, but it should be documented in `CLAUDE.md`/`AGENTS.md`, which the repository does not have.

`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (`:587`, `:626`) is also on, which means a file that forgets `import Foundation` fails to compile rather than silently inheriting it — an unrelated but co-located strictness setting. See [03](03-project-structure-and-build.md#31-two-settings-worth-understanding).

---

## 3. Thread inventory

| Thread / executor | Where | What runs on it |
|---|---|---|
| **AVAudioEngine render + tap** | `UnifiedAudioAnalyser.installTapSafely` — `:335-343` | `writeToRingBuffer(_:)` — see [§4](#4-the-real-time-thread-allocates) |
| **Main run loop, 60 Hz** | `Timer.scheduledTimer` — `:286-291` | `updateSpectrum()` — all FFT, Q3, A-weighting, stereo and goniometer maths |
| **`DispatchQueue.main`** | `audio.engine.queue` — `AppleAudioEngine.swift:10` | node setup (`AppleAudioEngine.swift:154` hops back to main at `:154` to publish) |
| **`Task.detached(priority: .utility)`** | `PlaylistService.createPlaylist` — `:118-129` | `JSONEncoder().encode(playlists)` → `UserDefaults.standard.set` |
| **Cooperative thread pool** | `AudioImportService` — `:36-53` | the `NSFileCoordinator` copy, via a checked continuation |
| **Main run loop, per effect** | `AppBackground` — `ShaderEffects.swift:357`, `:386-388` | 60 fps `time` advance, **only while `useFogShader`** (`:388-391`) |
| **Main run loop, per effect** | Water / Tunnel / Smoke — `ShaderEffects.swift:77`, `:220`, `:310` | each owns a clock at its own `frameInterval` |

The three raymarch/background effects deliberately run their own clocks so they can drop to 15–30 fps and pause independently; `ShaderEffects.swift:19-22` explains it. The `guard scenePhase == .active` in every handler — `ShaderEffects.swift:79`, `:222`, `:312`, `:387` — means all four pause when the app backgrounds. That is well done.

---

## 4. The real-time thread allocates

This is the most important finding in the document.

The `installTap` callback runs on a real-time-priority thread owned by `AVAudioEngine`:

```swift
// AudioMeters/UnifiedAudioAnalyser.swift:335-343
mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hopSize), format: format) { [weak self] buffer, _ in
    #if DEBUG
    let t0 = mach_absolute_time()
    #endif
    self?.writeToRingBuffer(buffer)
    …
}
```

`writeToRingBuffer` (`:391-419`) allocates **five heap arrays per buffer**, before it ever reaches the ring buffer:

```swift
let left = Array(UnsafeBufferPointer(start: leftPtr, count: frameLength))   // :398
let right = Array(UnsafeBufferPointer(start: rightPtr, count: frameLength))  // :399
var mid   = [Float](repeating: 0, count: frameLength)                        // :401
var side  = [Float](repeating: 0, count: frameLength)                        // :402
var mono  = [Float](repeating: 0, count: frameLength)                        // :403
```

With `hopSize = 2048` at 48 kHz that is 5 × 2048 × 4 B = 40 KB of short-lived allocation **per tap, ≈47 times per second — about 1.9 MB/s of garbage created on a real-time thread.** The `vDSP` calls at `:405-412` are fine; the array construction around them is not. `malloc` on an RT thread is precisely what the section header above the file is trying to avoid:

```swift
// :8
// MARK: - Lock-Free Ring Buffer
```

> ### ⚠️ Three things are wrong at once here
>
> **1. The buffer is not lock-free.** `RingBuffer` (`:9-40`) is a `class` with `private let lock = NSLock()` (`:15`) and every access takes it. The header comment is inaccurate. The *discipline* is at least correct — `lock.lock(); defer { lock.unlock() }` at `:23-24` and `:33-34` — which is the only place in the repository where a lock is used properly.
>
> **2. The RT thread allocates ~1.9 MB/s** before reaching the lock. The fix is to preallocate five `UnsafeMutablePointer<Float>` buffers once, write the vDSP results straight into them, and have `RingBuffer` read from raw memory. `RingBuffer` is already a fixed-capacity ring (`:11-14`), so this is a mechanical change with no algorithmic risk.
>
> **3. The RT closure calls a main-actor method.** `UnifiedAudioAnalyser` is not marked `nonisolated`, so with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (§2) the type *is* main-actor-isolated, and `self?.writeToRingBuffer(buffer)` from the tap callback is an isolation violation. The project does not currently compile ([03](03-project-structure-and-build.md#5-the-target-that-does-not-compile)), so this violation has simply never been surfaced by the compiler. It will surface the moment target membership is repaired. `RingBuffer` should be a non-isolated type of pure value semantics, and the analyser's RT entry point should be `nonisolated`.

Note the `#if DEBUG` `mach_absolute_time()` at `:341` — the tap cost is measured (`tapCallbackMaxUs`, `tapOverrunCount`, surfaced in `AudioHealthHUD.swift:12-13`), which is how this class of problem is usually caught. It is measured, and the measurement exists in a HUD no user can reach.

---

## 5. The two documented safeguards that are not implemented

`UnifiedAudioAnalyser.attach` carries a detailed doc comment describing a generation-based cancellation gate:

```swift
// AudioMeters/UnifiedAudioAnalyser.swift:298-313
///   - generation: Opaque integer supplied by AudioManager. Unused here;
///                  the `isCurrent` closure is the actual cancellation gate.
///   - isCurrent:   Called just before the tap fires. Return `false` to
///                  abort — AudioManager bumps its generation counter on
///                  every new song so stale closures self-cancel.
func attach(to audioEngine: AVAudioEngine,
            generation: Int = 0,
            isCurrent: @escaping () -> Bool = { true }) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self else { return }
        guard isCurrent() else { return }          // cancelled by a newer song
        self.installTapSafely(on: audioEngine)
    }
}
```

**`AudioManager` never passes either argument.** The only call site is:

```swift
// audio_manager.swift:243
self.audioAnalyzer.attach(to: engine)
```

So `generation` is always `0` and `isCurrent` is always `{ true }`. The comment's central claim — "AudioManager bumps its generation counter on every new song so stale closures self-cancel" — describes a mechanism that does not exist. Grepping for `generation` across the repository returns only the four lines in `UnifiedAudioAnalyser` itself.

> **The race this leaves open.** `attach` waits 150 ms on the main queue before installing the tap. If the user skips a track during that window, the *old* pending closure still fires, `isCurrent()` returns `true`, and a tap is installed on an engine that now belongs to a different song. `AudioEngineService` does call `detach(from: oldEngine)` on teardown (`Services/AudioEngineService.swift:46`), which removes the tap — but a closure that has already been enqueued and is executing `installTapSafely` concurrently with that `detach` is not ordered against it. The symptom is analysis for song N+1 driven by song N's audio, or an "already has a tap" ObjC exception. Implementing the generation counter the comment already describes is a ~5-line fix.

The same "sleep and hope" pattern appears twice more: `AudioManager.attachAnalyzerSafely` (`audio_manager.swift:242`, 0.12 s) and `AudioPlaybackService.swift:98` (0.15 s). `UnifiedAudioAnalyser:308-309` explicitly notes *"Single 150 ms delay — enough for AVAudioEngine to finish its internal graph reconfiguration after play(). No nested asyncAfter."* — i.e. an earlier version stacked delays, and the fix was to stack fewer. The right answer is to observe the engine's actual state, not to guess a duration.

---

## 6. Locking

Three lock sites in the whole app.

| Location | Primitive | Guarded |
|---|---|---|
| `UnifiedAudioAnalyser.swift:15` | `NSLock` | `RingBuffer` indices + storage (`:23-24`, `:33-34`) |
| `goniometerView.swift:263` | `os_unfair_lock` | the goniometer snapshot (`:311-316`, `:325-330`) |
| `Q3SpectrumView.swift` | **none** | the Q3 band array — [06](06-visualisation.md) |

The goniometer uses a better primitive (`os_unfair_lock` is the right choice for a short, uncontended critical section) and the correct snapshot pattern: take the lock, copy into locals, release, then render outside it. `Q3SpectrumView` has no equivalent, and its renderer state is written from the same 60 Hz `updateSpectrum` path that the goniometer guards against. Because both run on the main thread and the tap thread only writes into `RingBuffer`, this is not currently a data race — it is a latent one that appears the moment anything moves the Q3 update off main. The asymmetry between the two sibling files is itself the smell: the right pattern exists 200 lines away.

`RingBuffer.write` holds its lock while looping over all `samples` (`:23-30`), so the RT thread holds the lock for the duration of a 2048-sample write. The reader holds it for the same. `os_unfair_lock` would be strictly better here, and a genuine single-producer/single-consumer ring would need no lock at all — the section header already says as much.

---

## 7. Hopping to main

Thirteen `DispatchQueue.main` hops, all of the same shape — a correct pattern used consistently:

```swift
// AudioMeters/UnifiedAudioAnalyser.swift:350
DispatchQueue.main.async { [weak self] in … }
```

with `[weak self]` at `:311`, `:350`, `:363`, `:563`, `:679`, `:733`, `AudioEngines/AppleAudioEngine.swift:154`, `Services/AudioEngineService.swift:63`, `Services/PlaylistService.swift:97`, `audio_manager.swift:141`, `View/content_view.swift:1640`, `Services/PlaylistService.swift:97`, and `[weak manager]` at `Services/AudioPlaybackService.swift:98`. No retain cycles. This part of the codebase is careful.

> ### ⚠️ One of the hops is a correctness bug
>
> `PlaylistService.reorderPlaylistSongs` (`:91-101`) mutates main-actor state **after** a hop:
>
> ```swift
> var updatedPlaylist = manager.playlists[index]
> updatedPlaylist.audioFileIDs.move(fromOffsets: source, toOffset: destination)
>
> DispatchQueue.main.async { [weak self] in
>     self.manager.playlists[index] = updatedPlaylist   // ← one runloop turn later
>     self.savePlaylists()
> }
> ```
>
> We are already on the main actor, so the `async` buys nothing and costs a full runloop turn of latency. Worse, `index` and `updatedPlaylist` are captured by value across that turn: if anything reorders, appends to, or deletes from `manager.playlists` in the interim, the write lands on the wrong element or resurrects a deleted playlist. `updatePlaylistOrder` (`:103-114`) does the same mutation **without** the hop, which is the correct version of the same code — [08](08-playlists-and-library.md) documents the resulting order-loss bug. Two adjacent functions, one right and one wrong, is a pattern worth normalising.

---

## 8. Structured concurrency: one continuation, double-resume hazard

`AudioImportService` is the only place using Swift concurrency directly (`:36-53`):

```swift
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    var coordinationError: NSError?

    fileCoordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
        do {
            try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
            continuation.resume(returning: ())
        } catch {
            continuation.resume(throwing: error)
        }
    }

    if let error = coordinationError {
        continuation.resume(throwing: error)     // ← second resume path
    }
}
```

> **⚠️ This can trap.** `CheckedContinuation` traps on double resume, and there are two unguarded `resume` paths. `NSFileCoordinator.coordinate(readingItemAt:options:error:byAccessor:)` invokes the accessor block, and the `error:` out-parameter is populated by the same call. If the coordinator both invokes the accessor *and* reports an error — which it can when a coordinated file changes mid-read — the continuation is resumed twice and the process aborts. Even without that, relying on "`coordinationError` is set only if the block did not run" is a documented-but-fragile assumption about a class that runs a coordination loop on a background thread.
>
> Additionally, `var coordinationError: NSError?` is a local captured by an escaping non-`@Sendable` closure and written through an `NSError**` bridging shim — an exclusive-access violation in waiting, and the reason the project has no `Sendable` conformance anywhere ([§2](#2-isolation-comes-from-a-build-setting-not-the-source)).
>
> The safe form is a single exit point guarded by a flag:
>
> ```swift
> let resumed = ManagedAtomicBool(false)   // or a simple actor
> func finish(_ r: Result<Void, Error>) { if !resumed.exchange(true) { continuation.resume(with: r) } }
> ```
>
> Or restructure so the accessor block never resumes and the error is read on the same side as the copy.

The rest of the import path is `async` and correctly `await`s `asset.load(.duration)` (`:56-58`) off the main actor. [09](09-file-import-and-sharing.md#3-path-a--document-picker) covers the surrounding logic.

---

## 9. `Task.detached` racing `UserDefaults`

```swift
// Services/PlaylistService.swift:118-129
let newPlaylist = Playlist(name: name)
manager.playlists.append(newPlaylist)
let playlists = manager.playlists
Task.detached(priority: .utility) { [weak self] in
    let data = try JSONEncoder().encode(playlists)
    UserDefaults.standard.set(data, forKey: self.manager.playlistsKey)
}
```

`createPlaylist` alone writes the playlist list from a detached task. `savePlaylists()` writes the **same key from the main actor** (`:100`, `:111`, `:126`, `:136`). Both encode a full snapshot of `manager.playlists` and `UserDefaults.set` is last-writer-wins. So:

1. `createPlaylist` mutates the array, snapshots it, and queues the write.
2. Any subsequent `savePlaylists()` — from a rename, a reorder, a track add, or a second `createPlaylist` — writes the newer snapshot on main.
3. If the detached task's encode is slower than step 2 (plausible: it is `.utility` priority, contending with the 60 Hz analysis timer), **the stale snapshot lands last and the user loses the newer edit.**

Nothing protects this. `Task.detached` also drops the actor context, so `self.manager.playlistsKey` is a main-actor property read off-main — an isolation violation that, again, is unobserved only because the target does not compile.

The fix is trivial: `Task.detached` buys nothing here. Encoding a small array to `Data` and writing to `UserDefaults` is microseconds of work, and `UserDefaults` is itself thread-safe. Just call `savePlaylists()` like every sibling method does.

---

## 10. The 60 Hz main-thread analysis loop

`startGraphicsTimer` (`:286-291`) runs a `Timer` at `targetFPS = 60.0` (`:224`) on the main run loop, calling `updateSpectrum()`.

Per tick, on the main thread: an 8192-point FFT, Q3 band grouping, A-weighting, stereo/mid/side correlation, peak/RMS/decay tracking, and a goniometer update — each result assigned to an `@Published` property, each of which invalidates SwiftUI views that observe it. [05](05-signal-analysis.md) covers the maths and [07](07-meters-and-hud.md) covers the observation fan-out.

The architecture is defensible — putting the FFT on main keeps every `@Published` assignment on the main actor and avoids a second synchronisation layer, and 8192-point FFT is on the order of tens of microseconds. But it does mean **DSP, decay smoothing, and SwiftUI layout all compete for the same 16.6 ms budget as the raymarch shaders**, which are also driven by main-run-loop timers. On a device that cannot hold 60 fps for rendering, the analysis timer competes with the frame budget rather than yielding to it.

The natural improvement is a dedicated `DispatchSourceTimer` on a serial queue that publishes coalesced snapshots, so the UI refreshes at display rate while the DSP runs at its own cadence. That is a substantial refactor and should not be attempted before the target compiles.

---

## 11. Summary of findings

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | **Critical** | RT tap thread allocates ~1.9 MB/s; `malloc` on a real-time thread | [§4](#4-the-real-time-thread-allocates) |
| 2 | **Critical** | `writeToRingBuffer` is called from the RT thread but the type is main-actor-isolated; violation unobserved only because the target does not compile | [§4](#4-the-real-time-thread-allocates) |
| 3 | **High** | The documented `generation` cancellation gate is never wired up; a stale 150 ms `asyncAfter` can install a tap on the wrong engine | [§5](#5-the-two-documented-safeguards-that-are-not-implemented) |
| 4 | **High** | `withCheckedThrowingContinuation` has two unguarded `resume` paths → double-resume trap | [§8](#8-structured-concurrency-one-continuation-double-resume-hazard) |
| 5 | **High** | `Task.detached` and `savePlaylists()` race on the same `UserDefaults` key → silent playlist loss | [§9](#9-taskdetached-racing-userdefaults) |
| 6 | Medium | Isolation is invisible: 0 type-level `@MainActor`, 0 `Sendable`, 0 `nonisolated` | [§2](#2-isolation-comes-from-a-build-setting-not-the-source) |
| 7 | Medium | `RingBuffer` is labelled "Lock-Free" and uses `NSLock` | [§6](#6-locking) |
| 8 | Medium | `reorderPlaylistSongs` mutates main state across an unnecessary hop, capturing `index` by value | [§7](#7-hopping-to-main) |
| 9 | Medium | Audio setup sequencing done with 120–150 ms `asyncAfter` sleeps rather than state observation | [§5](#5-the-two-documented-safeguards-that-are-not-implemented) |
| 10 | Low | `Q3SpectrumView` has no lock while its sibling `goniometerView` does — inconsistent, currently latent | [§6](#6-locking) |
| 11 | Low | Analysis shares the main run loop with shader clocks and SwiftUI layout | [§10](#10-the-60-hz-main-thread-analysis-loop) |
| 12 | Info | 13 `DispatchQueue.main` hops, all with weak captures, all consistent | [§7](#7-hopping-to-main) |

### 11.1 Fix order

Findings 1 and 2 are the same bug and must be fixed together: make `RingBuffer` a non-isolated value type over preallocated storage, and give the analyser a `nonisolated` RT entry point. Do this **first**, because repairing target membership ([03](03-project-structure-and-build.md#54-the-test-targets-are-empty-too)) will turn finding 2 into a compile error and stop the build.

Finding 3 is a five-line fix that removes a whole class of intermittent audio bugs. Finding 5 is a one-line deletion. Findings 4 and 8 are small but need care.

---

## See also

- [02 — Architecture](02-architecture.md) — which layer owns what
- [03 — Project Structure & Build](03-project-structure-and-build.md) — `SWIFT_DEFAULT_ACTOR_ISOLATION`, and why findings 1/2 have never been caught
- [04 — Audio Pipeline](04-audio-pipeline.md) — the engine graph the tap is installed on
- [05 — Signal Analysis](05-signal-analysis.md) — the work done on the 60 Hz main-thread timer
- [06 — Visualisation](06-visualisation.md) — Q3 renderer's missing synchronisation
- [07 — Meters & HUD](07-meters-and-hud.md) — `@Published` fan-out from the 60 Hz timer
- [08 — Playlists & Library](08-playlists-and-library.md) — the reorder/save races
- [09 — File Import & Sharing](09-file-import-and-sharing.md) — the continuation in the import path
- [14 — Known Issues](14-known-issues.md)
