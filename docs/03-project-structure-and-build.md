# 03 — Project Structure & Build

How the Punches repository is laid out, how the Xcode project is configured, and — importantly — **which of those files the build actually compiles.**

> **Read this before trusting any other document.** The `Punches3` target now compiles **31 of the 33 Swift files in the repository** and builds clean. The mechanism that gets them there is not the one Apple's documentation describes, and the Sources phase is not the membership list — see [§5](#5-target-membership-and-the-trap-in-it) before concluding anything about whether a given file is compiled. Treat the rest of this suite as a description of the codebase, and re-verify build claims against `Punches3.SwiftFileList`.

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

The root-level group (`project.pbxproj:213-239`) holds real `PBXFileReference` + `PBXBuildFile` entries — that is how root-level files join the target, and it means a new file added there needs three manual edits (§5.4). Every directory is a `PBXFileSystemSynchronizedRootGroup` (`:135-185`), and in this project each one's `membershipExceptions` acts as an *inclusion* allowlist rather than Apple's documented exclusion list (§5.2).

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

## 5. Target membership, and the trap in it

This is the single most important fact in this document, and it explains several oddities elsewhere in the suite.

### 5.1 What the Sources phase contains

`project.pbxproj:396-409` — the `Punches3` target's `PBXSourcesBuildPhase` lists **nine** files explicitly:

```
silly_speed.swift          Models.swift             SharedConstants.swift
audio_engine_protocol.swift  audio_manager.swift   pitch_algorithm.swift
AudioHealthHUD.swift       DiagnosticsService.swift DiagnosticsView.swift
```

**This list is not the whole story, and reading it as though it were is what caused most of the confusion in earlier revisions of this document.** The target also draws in every file belonging to a `PBXFileSystemSynchronizedRootGroup` (§5.2), and that is 24 more Swift files.

### 5.2 `membershipExceptions` is an INCLUSION list here — not an exclusion list

Xcode 16+ uses `PBXFileSystemSynchronizedRootGroup` so a folder's files can join a target without per-file `PBXBuildFile` entries. Apple's documented semantics for `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions` is that it lists files **excluded** from the named target.

**In this project it behaves as the opposite: an inclusion allowlist.** A file in a synchronized folder reaches the compiler *if and only if* it is listed in that folder's `membershipExceptions`. Verified empirically — `View/Album_view.swift` sat on disk, unlisted, and was silently not compiled; adding one line to the `View` list made it compile with zero code changes.

| Group | Exception set | Line | Listed (⇒ compiled) |
|---|---|---|---|
| `AudioEngines` | `CB7BBD6D…` | `:58-64` | `AppleAudioEngine.swift` |
| `AudioMeters` | `CB7BBD70…` | `:81-93` | all **7** (6 Swift + `Shaders.metal`) |
| `AudioShare` | `CB7BBD71…` | `:94-102` | `ShareViewController.swift`, `MainInterface.storyboard` ×2 |
| `Services` | `CB7BBD72…` | `:103-115` | all **7** |
| `View` | `CB7BBD73…` | `:116-133` | **12** — 7 Swift + `BlueNoise64.png` + 4 `.metal` |
| `Tests` (for `Punches3`) | `CB7BBD6E…` | `:65-72` | both test files |
| `Tests` (for `Punches3Tests`) | `CB7BBD6F…` | `:73-80` | both test files |

> ⚠️ **Do not "fix" this by deleting the exception sets.** The remedy that looks correct under Apple's documented semantics — remove the `PBXFileSystemSynchronizedBuildFileExceptionSet` objects and add the groups to `fileSystemSynchronizedGroups` so the lists become pure exclusions — would very plausibly remove all 24 files listed above from the target. Earlier revisions of this document recommended exactly that; it is wrong for this tree. See §8.1.

Note also that `Punches3`'s `fileSystemSynchronizedGroups` (`:270-272`) lists **only** `Tests`, yet the other five groups demonstrably contribute files. Under this project's semantics the exception sets' `target` field — not the target's group list — is what binds a group to a target. Do not use `fileSystemSynchronizedGroups` as a membership oracle here.

### 5.3 The result

**33** Swift files in the repository; **31 reach the compiler**, plus 5 `.metal` files and one generated file, for 32 lines in `Punches3.SwiftFileList`:

| Location | Swift in repo | Compiled |
|---|---|---|
| repository root | 9 | **9** (explicit `PBXBuildFile` + the `View`-style allowlists don't apply) |
| `View/` | 7 | **7** |
| `Services/` | 7 | **7** |
| `AudioMeters/` | 6 | **6** |
| `AudioEngines/` | 1 | **1** |
| `AudioShare/` | 1 | **1** |
| `Tests/` | 2 | **0** |

The only files in the repository that do not compile are the two in `Tests/` (§5.4). `Punches3.build/Debug-iphoneos/…/Punches3.SwiftFileList` is the ground truth; the Sources phase is not.

### 5.4 Root-level files get no automatic membership

No synchronized group covers the repository root — the main group (`CB7BBCB32F764F220051E29E`) is a plain `PBXGroup` with explicit children. So **a new `.swift` file dropped at the repo root does not join the target at all**, no matter what the folder exception sets say. It needs the three manual edits the existing root files have: a `PBXFileReference`, a `PBXBuildFile` with `in Sources`, and an entry in the main group's `children`.

`DiagnosticsService.swift` and `DiagnosticsView.swift` were both missed this way. Because the files were absent from the target, `DiagnosticsView.swift`'s duplicate `private struct ShareSheet` — which collides with the canonical `ShareSheet` in `View/content_view.swift` and is a genuine error once the file *is* a member — never surfaced in a target build. Xcode's editor still reported it, because live-issue checking uses the project navigator's file set rather than the target's.

### 5.5 The test targets are empty too

`Punches3Tests`' Sources phase (`:412-418`) has `files = ()`. Both test files are in `Tests/`, which is the one synchronized group listed in the target's `fileSystemSynchronizedGroups` — and under this project's semantics a `membershipExceptions` entry is an *inclusion*, so `Punches3Tests` has no way to pick them up. `Q3analysertests.swift` never runs.

`Punches3UITests` (`:419-425`) is the same, and there is no XCUITest file in the repository at all.

`Tests/FrequencyAllignmenttest.swift` is in any case not a test — it is a `print`-based utility with a `main`-style entry, per [05](05-signal-analysis.md).

> **A new file is not automatically a new compile error; it is a new file that is never checked.** This has already happened twice: `View/Album_view.swift` (692 lines, commit `775bea1`, which touched no project file at all) and the two root-level diagnostics files. Verify membership with `Punches3.SwiftFileList` after adding a file, not with the Sources phase.

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

```
$ xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'generic/platform=iOS' clean build
** BUILD SUCCEEDED **
```

Until `View/Album_view.swift` was added to the `View` membership allowlist, this instead reported two `cannot find '<Type>' in scope` errors against `View/content_view.swift` — and only two, because `Album_view.swift` itself was never compiled. A small error count was the symptom, not reassurance.

These are the commands that matter:

| Task | Command |
|---|---|
| Build (device) | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'generic/platform=iOS' build` |
| Build (simulator) | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'platform=iOS Simulator,name=iPhone 17' build` |
| Unit tests | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 -destination 'platform=iOS Simulator,name=iPhone 17' test` |
| Clean | `xcodebuild -project Punches3.xcodeproj -scheme Punches3 clean` |
| List schemes | `xcodebuild -project Punches3.xcodeproj -list` |

The device build **succeeds from clean with zero errors**. The test targets are still empty, so `test` builds an empty bundle and reports nothing ([§5.5](#55-the-test-targets-are-empty-too)).

### 8.1 Adding a file to the target

**To add a file inside a synchronized folder** (`View/`, `Services/`, `AudioMeters/`, `AudioEngines/`, `AudioShare/`): add its name to that folder's `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions`. That is the entire change — no `PBXFileReference`, no `PBXBuildFile`, no Sources-phase entry. This is how `View/Album_view.swift` was added, and it compiled with zero code changes.

**To add a file at the repository root**, where no synchronized group applies ([§5.4](#54-root-level-files-get-no-automatic-membership)), three manual edits are required: a `PBXFileReference`, a `PBXBuildFile` marked `in Sources`, and an entry in the main group's `children`.

> 🚫 **Do not delete the `PBXFileSystemSynchronizedBuildFileExceptionSet` objects, and do not "convert" `membershipExceptions` into Apple's documented exclusion lists by adding these groups to `fileSystemSynchronizedGroups`.** Earlier revisions of this document prescribed precisely that, on the assumption that the lists were exclusion sets. They are not, in this tree ([§5.2](#52-membershipexceptions-is-an-inclusion-list-here--not-an-exclusion-list)). Following that advice would remove the 24 files that currently compile, and is the single easiest way to break this build from a green state.

If this project is ever migrated to Apple's documented exclusion semantics, it has to be a single verified change — build afterwards and confirm `Punches3.SwiftFileList` still contains all 31 project files — never incrementally.

---

## 9. Things a reader should not assume

1. **That the Sources phase lists everything that compiles.** It lists 9 of 31; the other 22 arrive via synchronized groups. [§5](#5-target-membership-and-the-trap-in-it)
2. **That a file on disk is in the target.** It is not, unless it is listed in a synchronized folder's `membershipExceptions` or carries a root-level `PBXBuildFile`. This has silently swallowed two whole features already. [§5.4](#54-root-level-files-get-no-automatic-membership)
3. **That the tests run.** Both test bundles are empty. [§5.5](#55-the-test-targets-are-empty-too)
4. **That the share extension exists.** The files are right; the target is absent. [§6](#6-infoplist-and-entitlements)
5. **That the app group works.** The target is signed with an empty entitlements file. [§6](#6-infoplist-and-entitlements)
6. **That AudioKit is central.** One file uses it; the engine is hand-rolled `AVAudioEngine`. [§4](#4-dependencies)
7. **That the app is universal.** `TARGETED_DEVICE_FAMILY = 1` while the test targets say `1,2`. [§3](#3-build-settings-app-target)
8. **That Debug and Release differ.** The two configurations are byte-identical in every setting listed in [§3](#3-build-settings-app-target).
9. **That a green build means the app runs.** `ShaderLibrary` resolves members dynamically from `default.metallib` at runtime, so a missing shader is a blank effect and a mis-called one is a silent no-op — never a compile error. [10](10-theming-and-shaders.md#4-the-four-shader-effects).

---

## See also

- [01 — Getting Started & Usage](01-getting-started-and-usage.md)
- [02 — Architecture](02-architecture.md)
- [05 — Signal Analysis](05-signal-analysis.md) — for the `Tests/` files
- [09 — File Import & Sharing](09-file-import-and-sharing.md) — entitlements, URL scheme, extension plist
- [10 — Theming & Shaders](10-theming-and-shaders.md) — the `.metal` files in the target, and why a missing shader is a runtime blank rather than a compile error
- [13 — Concurrency & Threading](13-concurrency-and-threading.md) — what `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` implies
- [14 — Known Issues](14-known-issues.md)
