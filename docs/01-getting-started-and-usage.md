# 01 — Getting Started & Usage

What Punches is, how to build it, and how to drive the UI. Every claim here is checked against the source; where the app does not do what it appears to, that is called out.

> **The app builds.** 39 of the 41 Swift files in the repository are members of the `Punches3` target, and `xcodebuild … clean build` succeeds with zero errors on both simulator and device. The two non-members are the files in `Tests/`, which belong to the (currently empty) test bundle. Membership is automatic inside a synchronized folder; the trap is at the repository *root*, where a new file needs three manual project entries or it silently never compiles — see [03 §5](03-project-structure-and-build.md#5-target-membership-and-the-trap-in-it) and [14 A1](14-known-issues.md#a1-target-membership-silently-swallowed-files). The usage below describes the code as written; note that a missing Metal shader is a runtime blank, not a build failure, so a clean build is not evidence that every effect renders.

---

## 1. What Punches is

An offline iOS audio player built on `AVAudioEngine`, with real-time signal analysis driving two Metal visualisations, per-file pitch shifting through `AVAudioUnitTimePitch`, and a 35-theme appearance system built on four raymarched/fBM background shaders.

It is a local-files player. There is no network, no account, no sync, no streaming, and no library scanner. You import audio files and play them.

| Capability | Status |
|---|---|
| Import local audio files | works, via document picker |
| Play / pause / skip / seek | works |
| Playlists (create, rename, reorder, delete) | works, with save races ([08](08-playlists-and-library.md)) |
| 128-band Q3 spectrum | works |
| Multi-band goniometer + phase correlation | works |
| Artwork view | works |
| Per-file artwork assign / change / remove | works |
| Pitch shifting, −2 to +2 octaves | works |
| **Tempo control** | **UI is commented out** — see [§6.4](#64-tempo-is-dead) |
| **Loop** | **scope-limited, not persisted** — see [§6.5](#65-loop-is-scope-limited-and-not-persisted) |
| **Volume** | **no control at all** — see [§6.6](#66-there-is-no-volume-control) |
| **Song metadata** | **filename only** — no tags are read at all ([§6.13](#613-songs-are-read-only-to-display-their-filename)) |
| **Default song on launch** | **the oldest import, not the newest** ([§6.11](#611-the-app-opens-on-the-oldest-song-not-the-newest)) |
| **Manual song order** | **discarded by the next import/delete** ([§6.12](#612-manual-song-order-is-discarded)) |
| **Share-to-app (extension import)** | **nonfunctional** — see [09](09-file-import-and-sharing.md) |
| **Share out (system share sheet)** | works; the playlist path has a hazard ([09 §6.2](09-file-import-and-sharing.md#62-sharesheet)) |
| Unit tests | target is empty ([03 §5.4](03-project-structure-and-build.md#55-the-test-targets-are-empty-too)) |

---

## 2. Requirements

| | Required | Actual in the project | Stated in root `README.md` |
|---|---|---|---|
| iOS | 26.2 | 26.2 (`project.pbxproj:489`, `:544`) | "iOS 16 or later" — **wrong** |
| Xcode | 26.2 | 26.2 (`:321-322`, `CreatedOnToolsVersion = 26.2`) | "Xcode 15 or later" — **wrong** |
| Swift | 5.0 | `SWIFT_VERSION = 5.0` (`:588`) | not stated |
| Device | iPhone only | `TARGETED_DEVICE_FAMILY = 1` (`:589`) | not stated |
| Dependencies | — | AudioKit 5.6.6 | not stated |

> **The root `README.md:38-41` requirements are wrong by a decade.** The deployment target is iOS 26.2 and the project was created with Xcode 26.2. Anyone following the README on Xcode 15 cannot open this project at all — `objectVersion = 77` (`:6`) is not readable by Xcode 15. The requirements table should say iOS 26.2 / Xcode 26.2, and note iPhone-only.

`AudioKit` is a declared dependency but only `AudioMeters/UnifiedAudioAnalyser.swift:2` imports it; the engine is hand-rolled `AVAudioEngine` ([03 §4](03-project-structure-and-build.md#4-dependencies)).

---

## 3. Building and running

### 3.1 Running the app

Nothing to repair — the target is complete apart from `Tests/`, and the build is green.

Two things *are* worth checking before trusting what you see on screen, because neither is a compile error:

1. `ShaderLibrary.grainOverlay` does not exist in any `.metal` file ([10 §4](10-theming-and-shaders.md#4-the-four-shader-effects)).
2. `tunnelEffect` is called with 8 arguments for 9 parameters (same section).

`ShaderLibrary` resolves members dynamically from `default.metallib` at runtime, so both of these compile cleanly and fail silently — a blank tunnel, and a Grain slider wired to a function that does not exist. If the tunnel renders nothing, this is why; it is not a build problem.

### 3.2 Commands

```bash
# List available schemes — expect none on a fresh clone (no shared scheme exists)
xcodebuild -project Punches3.xcodeproj -list

# Build for device
xcodebuild -project Punches3.xcodeproj -scheme Punches3 \
  -destination 'generic/platform=iOS' build

# Build + run on a simulator
xcodebuild -project Punches3.xcodeproj -scheme Punches3 \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Unit tests — currently a no-op, the test bundle is empty
xcodebuild -project Punches3.xcodeproj -scheme Punches3 \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

> **Use `Punches3.xcodeproj`, not the workspace.** `silly_speed.code-workspace` references `../../Desktop/SillySpeed/SillySpeed.xcodeproj` — a path outside the repository that will not resolve for anyone else ([03 §7](03-project-structure-and-build.md#7-workspaces-and-schemes)). The workspace is also copied into the app bundle as a resource, which is a separate mistake.

There is **no shared scheme**; Xcode autocreates one on first open. For CI, add `Punches3.xcodeproj/xcshareddata/xcschemes/Punches3.xcscheme`.

### 3.3 Signing

`DEVELOPMENT_TEAM = U6Q4B5CXQX` is hardcoded in all three targets' Debug and Release configurations (`:562`, `:601`, `:637`, `:656`). `CODE_SIGN_STYLE = Automatic`. You will need to be on that team, or change the team ID, before a device build.

The app is signed with `Punches3.entitlements`, which is **empty**. That is fine for a simulator build and for a device build that uses no app group — but it means the share-extension import path cannot work on device, because the app-group container will be `nil` ([09 §2](09-file-import-and-sharing.md#2-sharedconstants)).

---

## 4. Navigating the app

`ContentView` (`View/content_view.swift:5`) hosts a `NavigationStack` with three pages and a custom bottom bar.

| Page | Definition | Reached by |
|---|---|---|
| Songs | `SongsListView` (`:756`), page at `:198` | bottom bar, left circle button |
| Playlists | `PlaylistsListView` (`:912`), page at `:170` | bottom bar, middle circle button |
| Player | `AudioPlayerView` (`View/audio_player_view.swift:4`), page at `:222` | tapping any song, or the mini-player pill |

### 4.1 The bottom bar

`adaptiveBottomBar` (`:357`) switches between `expandedPlayerPill` (`:395`) and `compactPlayerPill` (`:420`) based on scroll position, with three `tabCircleButton`s (`:446`) for Songs / Playlists / Player. The pill taps through to the player via `navigateToPlayer` (`:1019`).

`MiniPlayerBar` (`:1016`) is the persistent now-playing bar.

### 4.2 Visualisation mode picker

The player's toolbar has a mode picker (`:290-311`) writing `audioManager.visualisationMode` and calling `saveVisualisationMode()` (`:301`). The three live modes are `VisualisationMode.Goniometer`, `.Spectrum` and `.Artwork` (`View/audio_player_view.swift:66`, `:73`, `:80`).

The root `README.md:18` says "3 modes" and lists **Analyser**, **Goniometer**, **Art** — the first is stale; the case is `Spectrum` and it is the Q3 analyser view. A fourth case `.both` exists but is **entirely commented out** (`audio_player_view.swift:49-63`), as is a fifth `.spectrumOnly` (`:65-69`).

---

## 5. Using it

### 5.1 Importing audio

Tap **Add Songs** in the overflow menu (`View/content_view.swift:313-314`). This presents a `UIDocumentPickerViewController` configured for `.audio` with multi-select (`:1565`).

`PHPickerConfiguration.selectionLimit` is never set, so the picker offers multi-select but the import loop (`for url in urls { audioManager.importAudioFile(from: url) }`, `:1566-1568`) **imports only the first URL**. [09 §3](09-file-import-and-sharing.md#3-path-a--document-picker).

Files are copied into `AudioManager.fileDirectory` — the app-group container's `AudioFiles/` if available, else `Documents/AudioFiles/` ([12 §5](12-persistence-and-keys.md#5-on-disk-layout)). Import failures are silently discarded: `AudioImportService` publishes `importError` and `isImporting`, and **no view ever reads either** ([09 §7](09-file-import-and-sharing.md#7-what-is-not-wired)).

### 5.2 Browsing and searching

Both list pages have a custom search field (`searchBar`, `:327`) with a glass effect and a clear button (`:338-343`). Filtering is a case-insensitive contains test:

```swift
// View/content_view.swift:235-238
var filteredSongs: [AudioFile] {
    let base = …
    if searchText.isEmpty { return base }
    return base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
}
```

Playlists filter on `name` the same way (`:243-244`). Only the title/name is searched — not artist, album, or filename.

### 5.3 Song actions

Long-press any song for `AudioFileContextMenu` (`View/content_view.swift:1513-1564`):

| Action | Behaviour | Line |
|---|---|---|
| share this file | presents `UIActivityViewController` with the live container URL | `:1521-1527` |
| Set / Change Artwork | `PhotosPicker` for a new image | `:1528-1534` |
| Remove Artwork | only shown when artwork exists; destructive | `:1535-1542` |
| rename | alert, prefilled with the current title | `:1543-1547` |
| Add to Playlist | submenu of every playlist | `:1548-1555` |
| Delete | destructive; removes the file from disk | `:1556-1559` |

> **The single-song share hands out the real file on disk**, not a copy (`:1523-1526` → `audioManager.urlForSharing`). Combined with Delete two rows below it in the same menu, a share in progress can leave the receiving app with a dangling URL. The *multi-select* menu does this correctly — it copies to a temp directory first ([09 §6.2](09-file-import-and-sharing.md#62-sharesheet)). Single-song share should do the same.

### 5.4 Multi-select and batch actions

Multi-select state is `isMultiSelectMode` + `selectedFileIDs: Set<UUID>` (`:766-767`). While a selection is active, each selected row's context menu becomes `MultiSelectContextMenu` (`:1326`), which offers Share, Artwork, **Add to Playlist** (a `confirmationDialog` listing playlists, `:871-890`) and Delete.

The playlist-detail equivalent is `PlaylistMultiSelectContextMenu` (`View/PlaylisList_view.swift:283`), which adds **Remove from Playlist** alongside Delete.

All four context-menu variants are suppressed while `isReorderMode` is active (`:1298`, `View/PlaylisList_view.swift:248`).

### 5.5 Reordering

Reorder mode is toggled per list and shows an `EditButton`-style reorder UI. The `move(fromOffsets:toOffset:)` path is where [08](08-playlists-and-library.md) found two order-loss bugs; in short, drag-reordering a playlist while it is the active playback queue does not update the queue, and `reorderPlaylistSongs` writes back across an unnecessary dispatch hop ([13 §7](13-concurrency-and-threading.md#7-hopping-to-main)).

### 5.6 Playlists

Create via **Create Playlist** in the overflow menu (`:316-317`). Playlists have a name, an ordered `[UUID]` of audio files, and optional artwork. Each playlist row has swipe actions (`View/PlaylisList_view.swift:70`) and a context menu (`:247`).

There is a hidden master playlist (`__MASTER_SONGS__`) that backs the Songs page order, and **deleting it wipes every user playlist** ([08 §3](08-playlists-and-library.md#3-the-master-playlist--the-most-important-thing-in-this-document)). It is not shown in the Playlists list, so this failure is not reachable from the UI as shipped — but the guard in `deletePlaylist` tests `sortedPlaylists` rather than asserting the master exists, so it is one refactor away.

### 5.7 The player

`AudioPlayerView` layout, top to bottom (`View/audio_player_view.swift:17-26`):

1. `visualisationView` — the current mode, full height
2. *(tempo control — commented out, line 22)*
3. `pitchControl` — slider, `−2400…2400` cents, with a reset button
4. `timeSlider` — scrubber with elapsed / duration read-outs
5. `playbackControls` — previous / play-pause / next, plus the loop toggle

`currentFile` (`:40-44`) resolves to `audioFiles.first(where: { $0.id == audioManager.currentlyPlayingID }) ?? audioFile` — so the player page follows the *actual* playing track, falling back to the row you tapped.

The whole player forces `.preferredColorScheme(.dark)` (`:31`) regardless of the theme setting.

---

## 6. Things that do not work

### 6.1 There is no Settings for audio

Settings (`View/setting_View.swift:1158`) is a **theme and background-effect editor only**. No volume, no pitch, no tempo, no loop, no output route, no session config, no import options, no diagnostics, no reset-to-defaults ([11 §2](11-settings-ui.md#2-screen-structure)). All audio controls are inline in the player.

It is also reachable only from the **Songs** tab's overflow menu — not from Playlists, not from the player, and not while a multi-selection is active ([11 §1](11-settings-ui.md#1-how-you-get-there)).

### 6.2 The tunnel effect does not compile

`ShaderLibrary.grainOverlay` is called at `View/ShaderEffects.swift:209-214` and defined nowhere. The Grain slider in Settings is fully wired to `theme.tunnelGrainStrength` and drives a function that does not exist. Until the shader is written or the call removed, the tunnel cannot build ([10 §4](10-theming-and-shaders.md#4-the-four-shader-effects)).

### 6.3 Water, tunnel and smoke are mutually exclusive by construction

`AppBackground` draws `backgroundColor`, then water, then tunnel, then smoke, then fog. The middle three are **full replacement backdrops**, not blend layers, so enabling two shows only the later one. Settings presents four independent toggles with no warning ([11 §7](11-settings-ui.md#7-settings-that-do-not-exist)).

### 6.4 Tempo is dead

`tempoControl` is fully implemented — `View/audio_player_view.swift:230-266`, a `0.1...1.9` slider wired to `audioManager.setTempo`, with a reset button at `:306-315`. **The call site is commented out at line 22** (`//tempoControl`). Un-commenting one line restores the UI; `AudioManager.setTempo` and the engine plumbing are all still there.

> While restoring it, note the end labels are wrong: the range is `0.1...1.9` (`:248`) but the right-hand label reads `2.0x` (`:260`).

Tempo is also not persisted ([12](12-persistence-and-keys.md)), so it resets to 1.0 on every launch regardless.

### 6.5 Loop is scope-limited and not persisted

`playbackControls` has a working loop toggle — `audioManager.isLooping.toggle()` at `View/audio_player_view.swift:217`, with the icon switching between `repeat` and `repeat.1` at `:219`. `isLooping` is a plain `@Published var isLooping: Bool = false` (`audio_manager.swift:18`) and is **not persisted** ([12](12-persistence-and-keys.md)), so it resets to `false` on every launch.

It *is* read, but only in one place: `AudioPlaybackService.swift:190`, where it makes the queue wrap to the beginning **when the last song ends**. So the control is narrower than its icon suggests:

- It works on natural end-of-queue.
- It does **not** make `skipNextSong` wrap — the button still disables at the end.
- The icon at `repeat.1` is a single-item repeat, which is not what the flag does at all.

[04 §7](04-audio-pipeline.md#7-queue-skip-and-loop) covers the completion path that honours it, and [14 · D1](14-known-issues.md#d1-loop-is-honoured-only-at-the-end-of-the-queue) carries the investigation.

### 6.6 There is no volume control

`@State private var volume: Float = 1.0` is declared at `View/audio_player_view.swift:8` and **never read or written**. No `MPVolumeView`, no `AVAudioSession.outputVolume` binding, no slider. The user has hardware volume only.

### 6.7 Import errors are invisible

`AudioManager` publishes `isImporting: Bool` and `importError: String?` (`audio_manager.swift:22-23`), and `AudioImportService` writes both — distinct messages for permission, missing file, unknown type, and a Cocoa-domain catch-all (`Services/AudioImportService.swift:95-104`). **No view reads either property.** A file that fails to import simply does not appear, with no message; the only trace is a `print` on the Console (`:89`) ([09 §7](09-file-import-and-sharing.md#7-what-is-not-wired)).

The two writes are not treated consistently: the error-path `importError` / `isImporting = false` assignments are wrapped in `await MainActor.run` (`:91`), but the **success-path** `isImporting = false` at `:87` sits directly inside the `Task` with no hop. Wiring a view to `isImporting` will therefore give you an off-main publish on every successful import.

### 6.8 Multi-file import silently takes one file

The document picker allows selecting many files; the loop only imports the first ([09 §3](09-file-import-and-sharing.md#3-path-a--document-picker)).

### 6.9 The share extension cannot work

No share-extension target exists, `Punches3.entitlements` is empty, and `punches://openAndPlay` is not registered in `Punches3-Info.plist`. The complete, correct `AudioShare/` sources are in the repository and wired to nothing ([09](09-file-import-and-sharing.md), [03 §6](03-project-structure-and-build.md#6-infoplist-and-entitlements)).

### 6.10 Orphan cleanup can delete untracked files

`AudioLibraryService.cleanupOrphanedFiles()` deletes anything in `fileDirectory` that is not in the persisted `audioFiles` array, with one hardcoded exemption for the literal name `"Artwork"`. A file present on disk but absent from `UserDefaults` — after a failed save, a partial migration, or a restore from backup — is deleted on next launch ([08](08-playlists-and-library.md), [12](12-persistence-and-keys.md)).

Worse, `fileDirectory` is not one directory. With the app group available it is `<app group>/AudioFiles`; **without it — the committed state — it is the Documents root** (`audio_manager.swift:48-54`). So today this function scans and deletes the user's entire Documents directory, not an app-owned subfolder. Log the resolved path once at launch before trusting it ([14 · C2](14-known-issues.md#c2-cleanuporphanedfiles-deletes-untracked-files)).

A separate function, `processPendingImports`, removes `<app group>/PendingImports/` whole after an extension share (`AudioImportService.swift:171`) — including files that failed earlier in the same batch ([14 · B7](14-known-issues.md#b7-processpendingimports-deletes-the-whole-directory)).

### 6.11 The app opens on the oldest song, not the newest

`selectedAudioFile` is `@State` and is `nil` on a fresh launch, so the player page falls back to `audioManager.audioFiles.first` (`View/content_view.swift:224`) — the **first song ever imported**, because `loadAudioFiles` appends in directory order and nothing ever sorts `audioFiles`. The same fallback exists on the Player tab button (`:487-488`). Meanwhile the Songs list renders `displayedSongs`, which *is* correctly sorted newest-first by `sortedAudioFiles`.

So the list shows newest-first and the player opens on the oldest. `audioFiles` is also what `saveAudioFiles` persists, so the append order survives relaunch. See [14 · C13](14-known-issues.md#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list).

### 6.12 Manual song order is discarded

Four different orderings of the same data exist, and only one is the user's ([08 §3.3](08-playlists-and-library.md#33-four-orderings-of-the-same-data)):

- `audioFiles` — the raw directory listing, **never sorted**; this is what the player reads for its default song.
- `sortedAudioFiles` — sorts by `dateAdded`, discarding manual order even when it reads it from the master playlist.
- `displayedSongs` — the manual order, as a snapshot.
- `playbackQueue` — copied from whichever of the above produced the play action.

An import, delete, or rename rebuilds `displayedSongs` from `dateAdded`, so a hand-sorted list reverts to newest-first. The manual order written into a playlist by `reorderSongs` is persisted and then re-sorted the moment it is read back ([14 · C14](14-known-issues.md#c14-manual-sort-order-is-silently-discarded)). The fix requires an answer to one question — manual order or date order? — which is why [14](14-known-issues.md) flags it rather than simply patching the sort.

### 6.13 Songs are read only to display their filename

Nothing in the app parses a tag. A repository-wide search for `AVMetadataItem`, `commonMetadata`, `artist`, `album`, `genre` returns **zero hits in any `.swift` file**, and the only `AVAsset` usage in the whole project is a single `.duration` read during import (`Services/AudioImportService.swift:55-57`) ([08 §2.1](08-playlists-and-library.md#21-audiofile)):

- **Title** = the filename, set at import. Notably the two `AudioFile` initialisers disagree about it — one strips the extension (`Models.swift:21`), the decoding one keeps `fileName` whole (`:30`), so the same file can display two different titles depending on the code path ([14 · C8](14-known-issues.md#c8-the-two-audiofiletitle-fallbacks-disagree)).
- **Artist / album / genre / track / year** — no field on the model at all, so there is nothing to display and no view that omits it.
- **Embedded artwork** — never extracted; the artwork you see was set by hand.

Because the model has no fields for metadata, this is not a view-layer omission you could patch in a screen. See [14 · D14](14-known-issues.md#d14-no-metadata-is-read-anywhere-the-title-is-the-filename).

### 6.14 A phone call leaves the player stuck "playing"

On interruption the observer does set `isPlaying = false` and stop the timer and pause the engine (`Services/AudioSessionService.swift:101-105`) — so the *app's* flag is right. What it never does is re-publish `MPNowPlayingInfoCenter`, so `MPNowPlayingInfoPropertyPlaybackRate` keeps its last value of `1.0` and Control Center and the lock screen go on showing the track as playing. `currentlyPlayingID` also survives, so the mini player keeps a track with a frozen progress bar.

The dead end is that a phone call delivers `.ended` **without** `.shouldResume` — the normal outcome — and that branch (`:107-119`) is gated entirely on the option, so it does nothing at all. The timer stays stopped. Returning to the foreground does not repair it either: the `willEnterForeground` handler re-activates the session but never restarts the engine or the timer. `startTimer` is only reachable from `load`, `togglePlayPause`, and `skipNextSong` — all of them user actions — so the player stays frozen until you tap something.

`stop()` has the same gap — it never clears `nowPlayingInfo` either, so the identical symptom appears whenever the queue ends ([14 · E14](14-known-issues.md#e14-an-interruption-leaves-state-that-reads-as-still-playing)).

### 6.15 The next button can skip two songs at once

Auto-advance is wired **twice**, with no coordination:

1. `engine.onPlaybackFinished` fires `skipNextSong()` from the last buffer's completion callback (`AudioPlaybackService.swift:47-49` → `AppleAudioEngine.swift:152-156`).
2. The 0.2 s timer checks `currentTime >= duration` and calls `skipNextSong()` (`AudioPlaybackService.swift:134-136`).

Neither records that an advance is already in progress, and `skipNextSong` is not re-entrant. The completion handler checks its stop guard on `audioQueue` and then hops to the main queue **without re-checking**, so a callback that was already past the guard when you pressed Next calls `skipNextSong()` *after* the replacement track has started — skipping it. The timer is also a `Timer.scheduledTimer` in the default run-loop mode, so it does not fire while you are scrolling and is throttled in the background, which is why auto-next is unreliable in exactly the situations people notice it ([14 · E15](14-known-issues.md#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song)).

Related, and independent: the lock-screen and headphone buttons are registered inside a `do` block whose first two statements throw — if either fails, no remote command target is ever added and those buttons are permanently inert. The `play` command also *toggles* rather than playing, so it can pause when you meant to resume ([14 · E16](14-known-issues.md#e16-remote-commands-are-registered-inside-the-session-setup-do-block)).

---

## 7. Feature tour: the goniometer

The goniometer is the most substantial visualisation, and the root `README.md:24-33` describes it accurately.

The analyser's mono tap output is split into three bands with **first-order** IIR filters — bass (0–300 Hz, orange), mids (300 Hz–3 kHz, cyan), highs (3–20 kHz, violet) — and each is rendered as its own Lissajous cloud in a Lissajous-style M/S scatter plot ([06](06-visualisation.md)).

> **The root `README.md:25` is slightly wrong** when it says "IIR low-pass filters" as though they form a crossover. Each band is an independent single-pole low-pass, so the three bands overlap heavily and none of the stated 300 Hz / 3 kHz boundaries is a true −3 dB crossover. A 2nd- or 4th-order topology would fix it; see [06](06-visualisation.md#4-goniometerview--multi-band-lissajous).

Below the plot sits a phase-correlation bar reading −1 (out of phase) to +1 (in phase) (`AudioMeters/goniometerView.swift:81-88`), driven by `UnifiedAudioAnalyser.phaseCorrelation` (`:143`, computed at `:738`). Zoom steps ×1 / ×2 / ×4 / ×8 scale the signal via `zoomSteps` (`goniometerView.swift:25`) and are applied with `−`/`+` buttons.

All cross-thread handoff in this view is guarded with `os_unfair_lock` (`goniometerView.swift:263`, `:311-316`, `:325-330`) and is the correct snapshot pattern — take the lock, copy out, release, render. The root `README.md:47` generalises this to "all cross-thread sample handoff"; that is **not** true — `Q3SpectrumView` has no lock at all, and `RingBuffer` uses `NSLock` ([13 §6](13-concurrency-and-threading.md#6-locking)).

---

## 8. Feature tour: the Q3 spectrum

128 log-spaced bands from 20 Hz to 20 kHz, drawn with Metal (`Q3SpectrumView` → `Q3MetalRenderer` → `Shaders.metal`). Tap and drag anywhere to inspect the amplitude and approximate frequency at that point, via a `Q3InspectOverlay` ([06](06-visualisation.md)).

There is an A-weighted / flat toggle in the top-right of the view (`:60-85`) that switches the applied weighting curve.

The renderer keeps a peak-hold envelope per band with a release-time decay computed from the 60 Hz tick (`:666`), plus an "enhanced" mode.

---

## 9. Where to go next

| If you want to… | Read |
|---|---|
| Understand the layers | [02](02-architecture.md) |
| Fix the build | [03 §5](03-project-structure-and-build.md#5-target-membership-and-the-trap-in-it), [14](14-known-issues.md) |
| Understand the audio graph | [04](04-audio-pipeline.md) |
| Understand the DSP | [05](05-signal-analysis.md) |
| Understand the Metal renderers | [06](06-visualisation.md) |
| Understand the `@Published` fan-out | [07](07-meters-and-hud.md) |
| Understand the data model | [08](08-playlists-and-library.md) |
| Make sharing work | [09](09-file-import-and-sharing.md) |
| Change the theme or the shaders | [10](10-theming-and-shaders.md), [11](11-settings-ui.md) |
| Add a persisted setting | [12](12-persistence-and-keys.md) |
| Fix a threading bug | [13](13-concurrency-and-threading.md) |
| Prioritise the work | [14](14-known-issues.md) |
