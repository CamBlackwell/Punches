# 03 — Project Structure & Build

How the Punches repository is laid out, how the Xcode project is configured, and — importantly — **which of those files the build actually compiles.**

> **Read this before trusting any other document.** As committed, the `Punches3` target compiles **7 of 30 Swift files**. Every symbol defined outside those 7 is missing at compile time, so the target does not build. See [§5](#5-the-target-that-does-not-compile). Treat the rest of this suite as a description of the *intended* codebase.

---

## 1. Repository layout

```
Punches/
├── .gitignore                         ← only `*.xcuserstate`; see §7
├── README.md
├── silly_speed.code-workspace        ← see §7, references a path outside the repo
│
├── Assets.xcassets/
│   ├── AccentColor.colorset/
│   └── AppIcon.appiconset/           ← only heartberry.jpg, one size
│
├── ── root-level, on the target's Sources phase ────────────
│   ├── silly_speed.swift             ← @main, app root, URL handling
│   ├── audio_manager.swift           ← AudioManager, the @MainActor god object
│   ├── audio_engine_protocol.swift   ← AudioEngineType protocol
│   ├── pitch_algorithm.swift         ← PitchAlgorithm
│   ├── Models.swift                  ← AudioFile, Playlist, LibraryFilter, …
│   ├── SharedConstants.swift         ← app group + pending-import key
│   ├── AudioHealthHUD.swift          ← debug HUD (unused)
│   ├── Punches3.entitlements         ← EMPTY
│   ├── Punches3-Info.plist           ← background audio only
│   └── silly_speed_ios.entitlements  ← app group declared, referenced by nothing
│
├── ── synchronized folders, all files EXCLUDED from the target ──
│   ├── AudioEngines/AppleAudioEngine.swift
│   ├── AudioMeters/                  (7 files: analyser, Q3, goniometer, Metal)
│   ├── Services/                     (7 files: library, playlist, import, artwork, …)
│   ├── View/                         (11 files: UI + 4 stitchable .metal)
│   ├── AudioShare/                   (share extension: controller, plist, entitlements)
│   └── Tests/                        (2 files)
│
└── Punches3.xcodeproj/
    ├── project.pbxproj
    └── project.xcworkspace/
        ├── contents.xcworkspacedata
        └── xcshareddata/swiftpm/Package.resolved
```

Only the root-level group (`project.pbxproj:213-237`) holds real `PBXFileReference` + `PBXBuildFile` entries. Every directory is a `PBXFileSystemSynchronizedRootGroup` (`:135-185`) and every one of them carries an exception set that excludes its contents (§5).

---

## 2. Targets

Three targets, all created with Xcode 26.2 (`project.pbxproj:323-335`).

| Target | UUID | Type | Product | Notes |
|---|---|---|---|---|
| `Punches3` | `CB7BBCBB…` | application | `Punches3.app` | the app; **7 sources** |
| `Punches3Tests` | `CB7BBCCC…` | unit-test bundle | `Punches3Tests.xctest` | **empty Sources phase**; no tests run |
| `Punches3UITests` | `CB7BBCD2…` | UI-test bundle | `Punches3UITests.xctest` | **empty Sources phase**; no UI test files exist |

`project.pbxproj:250-313` defines all three. `packageReferences` (`:346-349`) declares **AudioKit** and **AudioKitUI**; only AudioKit is attached to a target (`:267-269`).

There is **no share-extension target**, despite `AudioShare/` containing a complete, correct extension plist (§6).

> **`Punches3UITests` exists with nothing in it.** No file anywhere in the repo is an XCUITest. It builds an empty bundle every `⌘U`.

---

## 3. Build settings (app target)

From `project.pbxproj:554-631` (Debug and Release are identical — no conditional blocks at all).

| Setting | Value | Line |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `Cam.Punches3` | `:577`, `:616` |
| `PRODUCT_NAME` | `$(TARGET_NAME)` | `:578`, `:617` |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.0` / `1` | `:561`, `:576` |
| `IPHONEOS_DEPLOYMENT_TARGET` | `26.2` (inherited from project `:489`, `:544`) | — |
| `SWIFT_VERSION` | `5.0` | `:588`, `:627` |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` | `:585`, `:624` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | `:584`, `:623` |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | `YES` | `:587`, `:626` |
| `TARGETED_DEVICE_FAMILY` | `1` — iPhone only | `:589`, `:628` |
| `INFOPLIST_FILE` | `Punches3-Info.plist` | `:565`, `:604` |
| `GENERATE_INFOPLIST_FILE` | `YES` | `:564`, `:603` |
| `CODE_SIGN_ENTITLEMENTS` | `Punches3.entitlements` | `:559`, `:598` |
| `CODE_SIGN_STYLE` / `DEVELOPMENT_TEAM` | `Automatic` / `U6Q4B5CXQX` | `:560-562` |
| `SUPPORTED_PLATFORMS` | `iphoneos iphonesimulator` | `:580`, `:619` |
| `SUPPORTS_MACCATALYST` | `NO` | `:581`, `:620` |
| `ENABLE_PREVIEWS` | `YES` | `:563`, `:602` |
| `INFOPLIST_KEY_LSApplicationCategoryType` | `public.app-category.music` | `:566` |
| `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` | "To add photos to songs, playlists and albums" | `:567` |
| `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` | `YES` | `:568` |
| `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents` | `YES` | `:569` |
| `INFOPLIST_KEY_UILaunchScreen_Generation` | `YES` | `:570` |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations` | all four | `:571` |

The test targets set `TARGETED_DEVICE_FAMILY = "1,2"` (`:649`) — iPhone **and iPad** — while the app itself is iPhone-only.

### 3.1 Two settings worth understanding

**`GENERATE_INFOPLIST_FILE = YES` together with `INFOPLIST_FILE`.** This is legal and common, but the precedence matters: keys present in `Punches3-Info.plist` win, and the `INFOPLIST_KEY_*` settings above only fill in keys the file does *not* define. `Punches3-Info.plist` defines only `UIBackgroundModes` (see [09](09-file-import-and-sharing.md#2-sharedconstants)), so scene manifest, launch screen, orientations and the photo-library usage string all come from the generated side. Adding a key to the plist silently overrides the `INFOPLIST_KEY_` setting, not the other way round.

**`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with `SWIFT_VERSION = 5.0`.** The language mode is Swift 5, but the *default actor* for unannotated declarations is `MainActor`. This is why so much of the codebase is already implicitly `@MainActor` and why the `nonisolated` / `Task.detached` annotations in [13](13-concurrency-and-threading.md) are load-bearing. It also means the 5-language-mode compiler still enforces strict concurrency in the places that matter — see the `ContentView` `CountdownView` error in [13](13-concurrency-and-threading.md).

---

## 4. Dependencies

### Swift Package Manager

`Package.resolved` (version 3, three pins):

| Package | Version | Revision | Used? |
|---|---|---|---|
| `audiokit` | 5.6.6 | `8d18b718a52d826b9c46b65e08295450e297591d` | **yes** — one file |
| `audiokitui` | 0.3.7 | `1a61e8a96c7ee24c3e5abe06dc3334a31fd7571d` | **no** — no target depends on it |
| `controls` | 1.1.4 | `4dd10370125af7f1e26d7a71b2c5929bb3c95087` | **no** — not even declared in the project |

- `packageReferences` declares AudioKit and AudioKitUI only (`project.pbxproj:346-349`).
- `Controls` is a **stale pin** — it is a transitive dependency of AudioKitUI and remains in `Package.resolved` from a previous state, but nothing in `project.pbxproj` references it. Harmless, but it is dead state.

> **AudioKit has exactly one consumer in the whole repository:** `AudioMeters/UnifiedAudioAnalyser.swift:2` (`import AudioKit`). Everything else — `audio_manager.swift`, `Services/AudioEngineService.swift`, `AudioEngines/AppleAudioEngine.swift` — uses raw `AVAudioEngine` / `AVAudioPlayerNode` / `AVAudioUnit`. AudioKit is a heavy dependency (it brings `audiokitui` and `controls` in behind it) for one file, and that file is excluded from the target. See [14-known-issues.md](14-known-issues.md).

Linking is via the target's Frameworks phase (`:187-195`) — AudioKit and nothing else. No other third-party code, no CocoaPods, no Carthage, no `Package.swift` of its own.

---

## 5. The target that does not compile

This is the single most important fact in this document, and it explains several oddities elsewhere in the suite.

### 5.1 What the Sources phase actually contains

`project.pbxproj:388-402` — the `Punches3` target's `PBXSourcesBuildPhase` has **seven** entries:

```
silly_speed.swift          Models.swift             SharedConstants.swift
audio_engine_protocol.swift  audio_manager.swift   pitch_algorithm.swift
AudioHealthHUD.swift
```

That is the entire list.

### 5.2 Why the folder files are not added

Xcode 16+ uses `PBXFileSystemSynchronizedRootGroup` so that a folder's files join a target automatically. Membership is controlled by `PBXFileSystemSynchronizedBuildFileExceptionSet` objects, whose `membershipExceptions` list is the set of files **excluded** from the named target.

Every synchronized root group in this project has an exception set pointing at `Punches3`, and every entry in those lists is the whole folder's contents:

| Group | Exception set | Line | Excluded files |
|---|---|---|---|
| `AudioEngines` | `CB7BBD6D…` | `:58-64` | `AppleAudioEngine.swift` |
| `Tests` (for `Punches3`) | `CB7BBD6E…` | `:65-72` | `FrequencyAllignmenttest.swift`, `Q3analysertests.swift` |
| `Tests` (for `Punches3Tests`) | `CB7BBD6F…` | `:73-80` | **the same two test files** |
| `AudioMeters` | `CB7BBD70…` | `:81-93` | all **7** |
| `AudioShare` | `CB7BBD71…` | `:94-102` | `ShareViewController.swift`, `MainInterface.storyboard` ×2 |
| `Services` | `CB7BBD72…` | `:103-115` | all **7** |
| `View` | `CB7BBD73…` | `:116-132` | all **11**, including `BlueNoise64.png` and all four `.metal` files |

Confirming the exclusion from the other side, `Punches3`'s `fileSystemSynchronizedGroups` (`:263-265`) lists **only** `Tests` — the one group whose files are all excluded anyway:

```objc
fileSystemSynchronizedGroups = (
    CB7BBD4D2F7650E30051E29E /* Tests */,
);
```

`AudioMeters`, `Services`, `View`, `AudioEngines` and `AudioShare` are synchronized root groups referenced by the main group but **not attached to the target at all**. A synchronized group that is not in a target's `fileSystemSynchronizedGroups` contributes nothing, whatever its exception set says.

### 5.3 The result

30 Swift files in the repository; **7 reach the compiler.** The 23 that do not, by folder:

- `AudioMeters/` — 6 Swift (`UnifiedAudioAnalyser`, `Q3SpectrumView`, `goniometerView`, `goniometerManager`, `VisualisationMode`, `UnifiedAudioAnalyser+Testing`) plus `Shaders.metal`
- `Services/` — all 7 (`AudioEngineService`, `AudioImportService`, `AudioLibraryService`, `AudioPlaybackService`, `AudioSessionService`, `PlaylistService`, `ArtworkService`)
- `View/` — 6 Swift (`content_view`, `audio_player_view`, `PlaylisList_view`, `setting_View`, `ShaderEffects`, `SpectrumView`) plus 4 `.metal` (`ColormapWarp`, `Fog`, `TunnelShader`, `Water`)
- `AudioEngines/AppleAudioEngine.swift`
- `AudioShare/ShareViewController.swift`
- `Tests/` — both files (`Q3analysertests`, `FrequencyAllignmenttest`)

That is 23 Swift files and 5 `.metal` files, none of which are compiled. The 7 that do compile are the 7 at the repository root.

Since `silly_speed.swift` instantiates `ContentView`, `AudioManager` and `ThemeManager`, and `audio_manager.swift` instantiates `AudioLibraryService`, `PlaylistService`, `ArtworkService`, `AudioImportService` and every `AudioEngineService`, the seven files that *do* compile reference dozens of undeclared types. The build fails immediately with `cannot find '<Type>' in scope`.

There is no build script, no generated source, and no `#if canImport` guard that could supply any of it.

> **The intent was almost certainly the inverse:** the exception sets were meant to *add* files to targets, or they were scaffolded by a tool that recorded "not yet a member" for every file. Either way the committed state does not build. Do not treat any "it works on my machine" claim about this repo as evidence about the committed tree.

### 5.4 The test targets are empty too

`Punches3Tests`' Sources phase (`:403-409`) has `files = ()`. And the `Tests` exception set for that target (`:73-80`) excludes *both* test files from it. So even if the app compiled, `Punches3Tests` would build an empty bundle and `Q3analysertests.swift` would never run.

`Punches3UITests` (`:410-416`) is the same, and there is no XCUITest file in the repository at all.

`Tests/FrequencyAllignmenttest.swift` is in any case not a test — it is a `print`-based utility with a `main`-style entry, per [05](05-signal-analysis.md).

---

## 6. Info.plist and entitlements

| File | Wired to target? | Contents |
|---|---|---|
| `Punches3-Info.plist` | yes (`:565`, `:604`) | `UIBackgroundModes: [audio]` only |
| `Punches3.entitlements` | **yes** (`:559`, `:598`) | **empty** — no `com.apple.security.application-groups` |
| `silly_speed_ios.entitlements` | **no** | declares the app group, referenced by nothing |
| `AudioShare/AudioShare.entitlements` | **no** | declares the app group, referenced by nothing |
| `AudioShare/Info.plist` | **no** | a complete, correct share-extension plist |

`AudioShare/Info.plist` is a real extension manifest and would work as-is: `NSExtensionPointIdentifier = com.apple.share-services`, `NSExtensionMainStoryboard = MainInterface`, and an activation rule of `NSExtensionActivationSupportsFileURLs: true` with `NSExtensionActivationSupportsAudioWithMaxCount: 10` / `…SupportsFileWithMaxCount: 10`.

The app is wired to the *wrong* entitlements file. `Punches3.entitlements` is empty, so even if the target compiled, `SharedConstants`' app-group container and the whole import/share path would fail at runtime with a nil container. Full analysis in [09](09-file-import-and-sharing.md).

---

## 7. Workspaces and schemes

- `silly_speed.code-workspace` contains a **path outside the repository**:

  ```json
  { "folders": [ { "path": "." },
                 { "path": "../../Desktop/SillySpeed/SillySpeed.xcodeproj" } ] }
  ```

  The second entry resolves to a sibling project that is not in version control. Opening the workspace on any other machine gives Xcode a broken reference, and it is the *project*, not the workspace, that the scheme list is built from — so use `Punches3.xcodeproj` directly.

- **No shared scheme exists.** `Punches3.xcodeproj/xcshareddata/xcschemes/` does not exist; the only scheme data is `xcuserdata/virginia.xcuserdatad/xcschemes/xcschememanagement.plist`. On a fresh clone Xcode will autocreate a scheme on first open, but `xcodebuild -scheme Punches3` fails until it has. For CI, add a shared scheme to `xcshareddata/xcschemes/`.

- **`silly_speed.code-workspace` is copied into the app bundle.** It is a `PBXBuildFile` in the app's Resources phase (`:16`, `:367`). A workspace file shipped inside `Punches3.app` is dead weight and mildly confusing; it should not be a resource.

- Tracked per-user state is committed: `xcuserdata/virginia.xcuserdatad/` (`IDEFindNavigatorScopes.plist`, `UserInterfaceState.xcuserstate`, `xcbkptlist`, `xcschememanagement.plist`). `.gitignore` contains exactly one line — `*.xcuserstate` — so the other three are tracked even though the pattern was clearly meant to cover the directory. `git rm --cached` them and ignore `xcuserdata/`.

---

## 8. Building and verifying

Given [§5](#5-the-target-that-does-not-compile), the current state of the tree is:

```
$ xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'generic/platform=iOS' build
error: cannot find 'ContentView' in scope
error: cannot find 'ThemeManager' in scope
error: cannot find 'AudioLibraryService' in scope
… (dozens more)
```

Once membership is repaired, these are the commands that matter:

| Task | Command |
|---|---|
| Build (device) | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'generic/platform=iOS' build` |
| Build (simulator) | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'platform=iOS Simulator,name=iPhone 17' build` |
| Unit tests | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'platform=iOS Simulator,name=iPhone 17' test` |
| Clean | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 clean` |
| List schemes | `xcodebuild -project Punches3.xcodeproj -list` |

### 8.1 Repairing target membership

The minimal fix is to add the four excluded folders to `Punches3`'s `fileSystemSynchronizedGroups` and empty the corresponding `membershipExceptions` lists — i.e. delete the exception sets for `AudioEngines`, `AudioMeters`, `Services` and `View` and add those groups to the target. Concretely, `Punches3` should end up with:

```objc
fileSystemSynchronizedGroups = (
    CB7BBD34… /* AudioEngines */,
    CB7BBD3C… /* AudioMeters */,
    CB7BBD4A… /* Services */,
    CB7BBD53… /* View */,
);
```

and the `Tests` group should be left out of `Punches3` entirely (tests do not belong in the app target) while its exceptions for `Punches3Tests` are **cleared**, not replaced, so `Q3analysertests.swift` is a member of the test bundle.

Two follow-on failures should be expected and are *not* membership problems:

- `ShaderLibrary.grainOverlay` is undefined, and `tunnelEffect` is called with 8 arguments for 7 parameters — [10](10-theming-and-shaders.md#4-the-four-shader-effects).
- `View/BlueNoise64.png` is excluded by the same `View` exception set that excludes the source files; it needs its own exception removed, or better, it needs to move into `Assets.xcassets/`.

---

## 9. Things a reader should not assume

1. **That the code compiles.** It does not, as committed. [§5](#5-the-target-that-does-not-compile).
2. **That the tests run.** Both test bundles are empty. [§5.4](#54-the-test-targets-are-empty-too)
3. **That the share extension exists.** The files are right; the target is absent. [§6](#6-infoplist-and-entitlements)
4. **That the app group works.** The target is signed with an empty entitlements file. [§6](#6-infoplist-and-entitlements)
5. **That AudioKit is central.** One file uses it; the engine is hand-rolled `AVAudioEngine`. [§4](#4-dependencies)
6. **That the app is universal.** `TARGETED_DEVICE_FAMILY = 1` while the test targets say `1,2`. [§3](#3-build-settings-app-target)
7. **That Debug and Release differ.** The two configurations are byte-identical in every setting listed in [§3](#3-build-settings-app-target).

---

## See also

- [01 — Getting Started & Usage](01-getting-started-and-usage.md)
- [02 — Architecture](02-architecture.md)
- [05 — Signal Analysis](05-signal-analysis.md) — for the `Tests/` files
- [09 — File Import & Sharing](09-file-import-and-sharing.md) — entitlements, URL scheme, extension plist
- [10 — Theming & Shaders](10-theming-and-shaders.md) — the `.metal` files excluded from the target
- [13 — Concurrency & Threading](13-concurrency-and-threading.md) — what `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` implies
- [14 — Known Issues](14-known-issues.md)
