# 14 — Known Issues & Risks

A severity-ranked register of every defect, dead path, and documentation error found in the Punches codebase. Each entry states the evidence, the impact, and the fix.

**This is the document to read first after [03](03-project-structure-and-build.md).** The project does not build as committed, and several of the highest-severity findings below have never been surfaced by the compiler because of that.

> **About the Exploration notes.** Entries carry an **Exploration notes** block recording the hypotheses that have already been ruled out, the instrumentation that would confirm or refute the rest, and any trap for the next person to look. This exists so that a hypothesis is not re-investigated from scratch, and so that a *failed* approach is as visible as a successful one. If you test one of these, update the block — including when the test shows the entry is **wrong**. One entry has already been corrected that way: [D1](#d1-loop-is-honoured-only-at-the-end-of-the-queue) previously claimed a variable had no readers anywhere, which was false. All Critical and High entries carry the block; the Medium and Low set does not yet, and should be filled in as each is picked up.

---

## Severity scale

| Level | Meaning |
|---|---|
| **Critical** | The app does not build, will crash, or loses user data. Must be fixed before anything else. |
| **High** | A shipped feature is broken, or a code path can corrupt state / produce garbage audio. |
| **Medium** | Works, but incorrect, misleading, or fragile. Will produce a bug report. |
| **Low** | Cosmetic, inconsistent, or a maintenance hazard. No user-visible failure. |

## Counts

| Severity | Count |
|---|---|
| Critical | 13 |
| High | 32 |
| Medium | 28 |
| Low | 18 |
| **Total** | **91** |

The table counts entries, not distinct defects: [A3](#a3-app-group-entitlement-is-empty) and [B1](#b1-app-group-entitlement-is-empty) are the same root cause documented from the build side and the import side, and several entries share a single fix.

## Reported symptoms

User-reported symptoms and the entries that explain them. A single report can have more than one cause, and two reports can share one.

| Symptom (as reported) | Entries | Note |
|---|---|---|
| *"A call stops the music but it is still registered as playing."* | [E14](#e14-an-interruption-leaves-state-that-reads-as-still-playing) · [E16](#e16-remote-commands-are-registered-inside-the-session-setup-do-block) | E14 is the direct cause — the published now-playing rate is never rewritten, and the timer is not restarted because a call ends without `.shouldResume`. E16 is a separate aggravator: when it fires, the lock-screen controls are inert too, so the user has no remote way to recover. |
| *"There is no file permanence; files disappear after closing the app."* | [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) · [C2](#c2-cleanuporphanedfiles-deletes-untracked-files) · [B7](#b7-processpendingimports-deletes-the-whole-directory) | C12 is the complete chain and the one to fix first: the index goes empty, then cleanup deletes the files. |
| *"Auto next song needs some work."* | [E15](#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song) · [D1](#d1-loop-is-honoured-only-at-the-end-of-the-queue) · [C4](#c4-reordering-does-not-update-playbackqueue) | E15 is the duplication and the stale-callback race. D1 is why the loop toggle appears not to work. |
| *"Songs should default to the top of the list, not the bottom."* | [C13](#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list) · [C14](#c14-manual-sort-order-is-silently-discarded) | The sort is correct. C13 is the unsorted `audioFiles.first` fallback used for the default selection; C14 is manual order being discarded on recompute. |
| *"There is no effective metadata integration."* | [D14](#d14-no-metadata-is-read-anywhere-the-title-is-the-filename) · [C8](#c8-the-two-audiofiletitle-fallbacks-disagree) | D14 is the whole gap: the model has no fields for artist/album/genre and nothing reads tags. C8 is why even the filename-derived title is inconsistent — the two `AudioFile` initialisers disagree about stripping the extension. |
| *"Songs sometimes don't skip when out of the app."* | [E16](#e16-remote-commands-are-registered-inside-the-session-setup-do-block) · [E15](#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song) | E16 is the "sometimes": if `setActive` throws at launch, no remote handler is ever registered. E15's background timer throttling is the other half. |

---

## A — Build & Project Structure

### A1 The target compiles 7 of 30 Swift files

**Critical.**

`Punches3`'s Sources phase contains exactly seven entries (`Punches3.xcodeproj/project.pbxproj:392-399`): `silly_speed.swift`, `audio_manager.swift`, `audio_engine_protocol.swift`, `pitch_algorithm.swift`, `Models.swift`, `SharedConstants.swift`, `AudioHealthHUD.swift`.

Every other file is excluded. Each synchronized root group carries a `PBXFileSystemSynchronizedBuildFileExceptionSet` whose `membershipExceptions` lists the whole folder — `AudioMeters` all 7 (`:81-93`), `Services` all 7 (`:103-115`), `View` all 11 (`:116-132`), `AudioEngines` (`:58-64`), `AudioShare` (`:94-102`) — and those five groups are **not in the target's `fileSystemSynchronizedGroups` at all** (`:263-265` lists only `Tests`, whose own exceptions exclude both test files).

`silly_speed.swift` instantiates `ContentView`, `AudioManager` and `ThemeManager`; `audio_manager.swift` instantiates seven services. The build fails immediately with `cannot find '<Type>' in scope`, dozens of times.

**Now 31 Swift files, and it is getting worse with each feature.** `View/Album_view.swift` was added for the album feature and is not in the target either, so it is invisible to any build — including the developer's, unless they add it in Xcode. **A new file is not automatically a new compile error; it is a new file that is never checked.** Fix [A1](#a1-the-target-compiles-7-of-30-swift-files) before adding further files, or every subsequent feature is being written blind.

**Fix:** add the four folders to `Punches3`'s `fileSystemSynchronizedGroups` and delete the four exception sets. See [03 §8.1](03-project-structure-and-build.md#81-repairing-target-membership). Expect [G1](#g1-missing-grainoverlay-shader-and-bluenoise64-asset) and [E2](#e2-rt-closure-calls-a-main-actor-method) to surface immediately afterwards — they are latent *because* of this bug.

**Exploration notes.**
- **Ruled out:** "the files are excluded by a build setting." They are excluded structurally. The four synchronized root groups are not in `fileSystemSynchronizedGroups` at all, and a `membershipExceptions` set on a group that is not attached to a target has no effect. No build setting controls this.
- **Ruled out:** "a source-generation phase adds them." There is no script or generated-source phase in the target.
- **To confirm:** the Sources phase (`project.pbxproj:388-402`) is the ground truth. Alternatively, build and read the `CompileSwift` lines in the log — they list exactly the files that reached the compiler.
- **Expect this to raise the error count.** Repairing membership surfaces [A4](#a4-grainoverlay-is-undefined-and-tunneleffect-is-mis-called) and [F2](#f2-the-tunnel-effect-does-not-compile) as hard compile errors, and [E2](#e2-rt-closure-calls-a-main-actor-method) as an actor-isolation error. A build with *more* errors afterwards is progress, not regression.

### A2 Both test targets are empty

**Critical.**

`Punches3Tests`' Sources phase is `files = ()` (`:403-409`), and the `Tests` exception set for that target excludes both test files (`:73-80`). `Punches3UITests` is the same (`:410-416`) and no XCUITest file exists. `⌘U` and `xcodebuild test` build empty bundles.

**Fix:** clear the `Punches3Tests` exception set so `Q3analysertests.swift` becomes a member. Delete the `Punches3UITests` target or add tests to it.

**Exploration notes.**
- **Ruled out:** "the test files are somewhere the target does not point." They are in `Tests/`, present on disk, excluded by the `Tests` membership exception set, and the Sources phase has `files = ()`.
- **Ruled out:** "Xcode finds them by convention." Synchronized groups still require explicit target membership; there is no discovery.
- **To confirm:** an empty test bundle reports **zero tests**, which reads as "the suite passed." Do not treat a green run as evidence the tests ran. `Q3analysertests.swift` is the one with real numeric expectations and the one worth restoring first.
- **Note:** [FrequencyAllignmenttest.swift](14-known-issues.md) is not a test — see [D7](#d7-frequencyallignmenttestswift-is-not-a-test). Restoring it as a target member adds a file that only prints.

### A3 App group entitlement is empty

**Critical.**

*(also [B1](#b1-app-group-entitlement-is-empty))* — `Punches3.entitlements` is an empty `<dict/>`, wired via `CODE_SIGN_ENTITLEMENTS` (`:559`, `:598`). The working versions exist in two files nothing references: `AudioShare/AudioShare.entitlements` and `silly_speed_ios.entitlements`, both declaring `group.Cam.punches-ios`. Without the entitlement, `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` and `fileDirectory` silently falls back to `Documents`.

**Fix:** copy the `com.apple.security.application-groups` array into `Punches3.entitlements`.

**Exploration notes.**
- **Ruled out:** "the entitlement is declared somewhere else." `CODE_SIGN_ENTITLEMENTS` points at `Punches3.entitlements`, which is an empty `<dict/>`. Two complete, correct entitlement files exist in the tree and nothing references them.
- **Ruled out:** "`containerURL(forSecurityApplicationGroupIdentifier:)` works without the entitlement." It returns `nil`. This is the reason the failure is *silent*: `fileDirectory` falls back to `Documents` and import appears to work, so the broken cross-process path is invisible until the extension is involved.
- **To confirm:** the app already prints the container URL at launch (`audio_manager.swift:104-106`). Compare its output with the group identifier declared in the two unreferenced entitlement files — a `nil` there is the confirmation.
- **Ordering:** this is a prerequisite for [B1](14-known-issues.md#b1-app-group-entitlement-is-empty), [B2](#b2-no-share-extension-target-exists) and the whole of section B. Fix it before testing any of them, or you will be debugging a path that cannot possibly succeed.

### A4 `grainOverlay` is undefined and `tunnelEffect` is mis-called

**Critical.**

See [G1](#g1-missing-grainoverlay-shader-and-bluenoise64-asset). Blocking the build independently of A1.

**Exploration notes.**
- **Ruled out:** "`grainOverlay` is defined in a `.metal` file that is not in the target." It is not defined anywhere — zero matches across every `.metal` file in the repository, not merely unlinked ones.
- **Ruled out:** "AudioKit provides the function." `ShaderLibrary` resolves to the app's own stitchable namespace, and the AudioKit dependency is vestigial (see [G5](#g5-audiokit-dependency-is-vestigial)).
- **Ruled out:** "the call site is dead code so it never compiles." It is on the live tunnel path, which is reachable from Settings.
- **To confirm:** this is a compiler error, not a runtime blank, so it needs no runtime instrumentation — build and read the diagnostic. Fix order matters: **remove the call to unblock the build, then add the shader separately.** Adding a Metal function is a bigger change than deleting a call, and mixing them makes the build unbisectable.
- **The second half is a runtime nil, not a compile error.** `Image("BlueNoise64")` compiles and silently returns nothing. See [G1](#g1-missing-grainoverlay-shader-and-bluenoise64-asset).

### A5 The RT thread allocates on a real-time queue

**Critical.**

See [E1](#e1-rt-thread-allocates-19-mbs). Blocking once the build is repaired.

**Exploration notes.**
- **Ruled out:** "the buffers are small enough not to matter." Two are `hopSize` frames and three are fixed small, but the cost is per *tap callback*, not per file.
- **Ruled out:** "the allocator makes it safe." It is safe in the correctness sense — that is not what the RT-thread rule is about. The rule is that any heap operation can block, and blocking the render thread is an audible glitch.
- **To confirm:** you do not need a profiler to size this. Taps per second = `sampleRate / hopSize`; bytes per tap = frames × 4 × array count. Both are known constants. Confirm with one Instruments *Allocations* run scoped to the audio thread if you want the number to be authoritative.
- **Note:** fixing this is mechanical — reuse preallocated storage via the existing ring buffer instead of constructing arrays — but see [E2](#e2-rt-closure-calls-a-main-actor-method), which fails to compile once membership is repaired and is best fixed in the same pass.

### A6 `processPendingImports` deletes files it did not import

**High.**

Duplicate of [B7](#b7-processpendingimports-deletes-the-whole-directory) — same function, same line (`AudioImportService.swift:171`), recorded under the build section as well as the import section because it was found independently from each side. Fix it once and close both.

The two entries do not diverge: the target is `<app group>/PendingImports/`, removed whole, and the path is currently unreachable until [A3](#a3-app-group-entitlement-is-empty) is fixed. See B7's notes for the ordering and the leak between `:168` and `:171`.

**Exploration notes.**
- **Ruled out:** "A6 and B7 are two different deletions." They are one line of code, `AudioImportService.swift:171`, seen from the build side and the import side. Do not spend time establishing whether one of them is stale — close them together.
- **Ruled out:** "it walks the directory and removes matching entries." It does not inspect names at all; `removeItem(at: pendingDirectory)` takes the directory itself.
- **To confirm:** verify once under [A3](#a3-app-group-entitlement-is-empty)'s fixed state, then mark both entries from the same result. Until A3 is fixed the early return at `:112` means any test proves nothing — a clean run is not evidence that B7 is safe.

### A7 No shared scheme; the workspace points outside the repository

**Medium.**

`silly_speed.code-workspace` lists `../../Desktop/SillySpeed/SillySpeed.xcodeproj` — a path outside version control. There is no `xcshareddata/xcschemes/`; only `xcuserdata/virginia.xcuserdatad/xcschemes/xcschememanagement.plist`. `xcodebuild -scheme Punches3` fails on a fresh clone until Xcode autocreates a scheme.

**Fix:** commit a shared scheme; delete or fix the workspace.

### A8 Workspace file is copied into the app bundle

**Low.**

`silly_speed.code-workspace` is a `PBXBuildFile` in the app's Resources phase (`:16`, `:367`). A workspace file has no business in `Punches3.app`. Remove it.

### A9 `.gitignore` does not cover `xcuserdata/`

**Low.**

`.gitignore` is one line: `*.xcuserstate`. `IDEFindNavigatorScopes.plist`, `UserInterfaceState.xcuserstate`, `xcbkptlist` and `xcschememanagement.plist` are all tracked under `Punches3.xcodeproj/xcuserdata/virginia.xcuserdatad/`. Add `xcuserdata/`, `git rm --cached` the tracked files.

### A10 Debug and Release configurations are identical

**Low.**

`project.pbxproj:554-591` and `:593-631` differ only in the surrounding comment. Both are `-Onone` at target level (the project-level Release sets `SWIFT_COMPILATION_MODE = wholemodule`, `:551`). No `SWIFT_OPTIMIZATION_LEVEL` override in the app's Release. Worth confirming this is intended.

### A11 `DEVELOPMENT_TEAM` is hardcoded in all six configurations

**Low.**

`U6Q4B5CXQX` at `:562`, `:601`, `:637`, `:656` and the project-level configs. Anyone else must edit the project file to build for device. Consider `DEVELOPMENT_TEAM = ""` with local `xcconfig`.

### A12 `TARGETED_DEVICE_FAMILY` disagrees between app and tests

**Low.**

App: `1` (iPhone only, `:589`, `:628`). Tests: `"1,2"` (`:649`). Either the app should be universal or the test targets are wrong.

### A13 `controls` is a stale package pin

**Low.**

`Package.resolved` pins `controls` 1.1.4 but `packageReferences` declares only AudioKit and AudioKitUI (`:346-349`). Harmless leftover.

---

## B — Import & Sharing

### B1 App group entitlement is empty

**Critical.**

`Punches3.entitlements` is empty but is the file actually signed ([A3](#a3-app-group-entitlement-is-empty)). This is the root cause of every other item in this section: with no app-group container, the whole `PendingImports` handoff is inert even if an extension target existed.

**Exploration notes.**
- Same root cause as [A3](#a3-app-group-entitlement-is-empty) — the empty `Punches3.entitlements`. This entry exists because the *consequence* is different: A3 is the build-side statement, this is the import-side one. Do not fix twice.
- **Ruled out:** "the extension writes to its own container and the app reads a different one." They would both resolve to the same group *if* the entitlement existed; without it both silently fall back, which is what makes this hard to see.
- **To confirm:** the same container-URL log as A3, from both the app and the extension. Two different answers confirm the split.
- **Blocked by:** [B2](#b2-no-share-extension-target-exists). There is no extension binary to test against, so the app-group path cannot be exercised end to end until a target exists.

### B2 No share-extension target exists

**High.**

Only `Punches3`, `Punches3Tests` and `Punches3UITests` are defined (`:250-313`). `AudioShare/ShareViewController.swift`, `AudioShare/Info.plist` and `AudioShare/AudioShare.entitlements` are complete and correct, and referenced by nothing. `ShareViewController` is additionally in the `Punches3` exclusion list (`:99`) — it is excluded from the app too, so it is dead code in both directions.

**Fix:** add a `com.apple.product-type.app-extension` target with `NSExtensionPointIdentifier = com.apple.share-services`, and embed it in the app.

**Exploration notes.**
- **Ruled out:** "the extension is built but not embedded." There is no extension target in the project. `AudioShare/ShareViewController.swift` is a file sitting on disk that nothing references.
- **Ruled out:** "a legacy target was disabled rather than removed." No such target object exists in `project.pbxproj`.
- **To confirm:** `xcodebuild -list` shows the full set of targets. If the extension is not listed, it is not built and no amount of container tuning will make the path work.
- **Blocked by:** [A3](#a3-app-group-entitlement-is-empty). Even once a target exists, the app group must be fixed first or the two halves still cannot see each other.

### B3 `punches://openAndPlay` is not registered

**High.**

`Punches3-Info.plist` contains only `UIBackgroundModes: [audio]`. No `CFBundleURLTypes`. `silly_speed.swift` implements `onOpenURL` for that scheme; the system can therefore never deliver it, and the extension's `UIApplication.shared.open(url)` call has no receiver.

**Fix:** add the `CFBundleURLTypes` entry.

**Exploration notes.**
- **Ruled out:** "the scheme is registered in the Info.plist." `CFBundleURLTypes` is absent — the plist declares exactly one key, `UIBackgroundModes`. Nothing in the app bundle advertises `punches://`.
- **Ruled out:** "a SwiftUI `.onOpenURL` handler is sufficient." The handler exists but iOS will never deliver a URL that is not registered, so the code is unreachable as written.
- **To confirm:** `plutil -p Punches3-Info.plist` — two keys, no URL types. Then `xcrun simctl openurl booted punches://openAndPlay` and watch nothing happen.
- **Note:** this is a plist-only fix and is independent of everything else in section B, so it is cheap. It still has no observable effect until [B2](#b2-no-share-extension-target-exists) exists.

### B4 Multi-file import silently takes the first file

**High.**

The document picker (`View/content_view.swift:1662`) does not set `PHPickerConfiguration.selectionLimit`, so the user can select many files, but the loop only imports the first (`:1566-1568`). No error, no message.

**Fix:** import all URLs, or set `selectionLimit = 1` so the UI matches the behaviour.

**Exploration notes.**
- **Ruled out:** "the picker is configured to allow only one selection." `PHPickerConfiguration.selectionLimit` is never set, so the picker offers multi-select and the user can select three.
- **Ruled out:** "the loop imports all and only the first is *displayed*." The import itself is truncated — the other files are never copied.
- **To confirm:** select three files and watch one appear with **no error message**. The silence is what makes this look like data loss rather than a bug, so it is easy to misreport — see [B5](#b5-import-errors-are-completely-invisible).
- **Fix shape:** iterate the full result set rather than taking `first`, and surface per-file failures.

### B5 Import errors are completely invisible

**High.**

`AudioImportService` publishes `isImporting` and `importError` (`audio_manager.swift:22-23`). **No view in the project reads either.** A DRM file, an unsupported codec, or a zero-duration file produces a console `print` and nothing else. There is no spinner, no alert, no toast.

**Fix:** observe `importError` in `SongsListView` and present an alert; use `isImporting` for a progress indicator.

**Exploration notes.**
- **Ruled out:** "the flags are unused because they are set after the view has gone." They are `@Published` on `AudioManager` (`audio_manager.swift:22-23`) and written by the import path; nothing observes them. There is no view-layer code that could have unsubscribed.
- **Ruled out:** "an alert is presented from the service." There is no presentation code anywhere in the import path. The four distinct messages built at `AudioImportService.swift:95-104` are assigned to a property no view ever renders.
- **To confirm:** import a non-audio file. `importError` is populated and nothing renders; `print("Import error: …")` at `:89` is the only output.
- **Side effect to expect when you wire the UI:** the success-path `isImporting = false` at `:87` is written from inside the `Task` with no `MainActor.run`, unlike the error path at `:91`. Observing `isImporting` will surface that off-main publish immediately — see [01 §6.7](01-getting-started-and-usage.md#67-import-errors-are-invisible).
- **Interaction to test:** combine with [B4](#b4-multi-file-import-silently-takes-the-first-file) — a batch where the first file is valid and the second is not currently produces one success, no failure, and no explanation.

### B6 Unsynchronised `fileURLs.append` in the extension

**High.**

`ShareViewController` appends to a shared `fileURLs: [URL]` from each `loadItem(forTypeIdentifier:options:)` completion. `NSItemProvider` documents that this may be a private **concurrent** queue, so with 2+ attachments this is a data race — lost entries or a corrupted buffer. The `DispatchGroup` waits correctly, but the appends themselves are unguarded. Masked in practice because the extension is usually invoked with one attachment.

**Fix:** collect into a lock-protected box, or serialise onto one queue.

**Exploration notes.**
- **Ruled out:** "`processFiles` is main-actor isolated so the appends are safe." It is not; the extension view controller calls it with no isolation, and `fileURLs` is a plain `var` on the controller.
- **Ruled out:** "iOS calls the completion handler on the main queue." It does not guarantee a queue.
- **To confirm:** run under Thread Sanitizer with a multi-file share. If TSan is unavailable, a large share is more likely to expose it than a small one — the race needs concurrent appends to land in the window.
- **Note:** this is a genuine data race, not merely a correctness nit: a lost or duplicated entry in `fileURLs` means a file that was shared never arrives.

### B7 `processPendingImports` deletes the whole directory

**High.**

`AudioImportService.swift:171` calls `removeItem(at: pendingDirectory)` — the entire `PendingImports/` folder, not just the files it imported. Any file that failed an earlier step is destroyed. The array is cleared at `:168` *before* the removal, so a crash in between leaks the directory permanently, and `cleanupOrphanedFiles` will never see it because it only scans `fileDirectory`.

**Fix:** `defer`-remove each successfully-imported file individually.

**Exploration notes.**
- **Ruled out:** "it removes only the files it imported." It removes `pendingDirectory` whole (`:171`), which is `<app group>/PendingImports/` (`:119`) — a directory it did not create and does not own. Anything else in there goes with it.
- **Ruled out:** "it wipes the user's library." It does not, and this is worth being precise about: `PendingImports/` is a **sibling** of `AudioFiles/`, both under the app group root. The library itself is untouched. The loss is limited to files still sitting in the pending directory — including any that failed an earlier step of *this* very batch.
- **Ordering, and it is the reverse of what you would guess:** this bug is currently **unreachable**. The first statement of `processPendingImports` is `guard let groupURL = containerURL(...)` (`:112`), which returns early while the app group entitlement is empty ([A3](#a3-app-group-entitlement-is-empty)). Fix A3 and this becomes live. Test them in that order, and do not conclude from a dry run today that B7 is harmless.
- **To confirm:** once A3 is fixed, place a sentinel file in `PendingImports/` alongside a real import. After the import, check whether the sentinel survived. It will not.
- **A second, smaller race in the same lines:** `pendingFiles` is cleared from `groupDefaults` at `:168`, *before* the removal at `:171`. A crash between the two leaves the directory on disk with no record of what was in it, so it leaks permanently — `cleanupOrphanedFiles` never sees it, because that scans `fileDirectory`, not `PendingImports/`.
- **This is a data-loss bug, not a cleanup one.** It belongs in the "stop losing user data" phase — see the fix order.

### B8 `processPendingImports` has no reentrancy guard

**High.**

Called from `AudioManager.init` and from a `scenePhase` handler in `silly_speed.swift`, plus a `punches://` URL path. No flag prevents overlap, and there is no explicit main-actor annotation. Two concurrent runs will interleave `pendingFiles` reads and directory removals.

**Fix:** an `isProcessing` flag on the main actor, checked at entry.

**Exploration notes.**
- **Ruled out:** "`isImporting` guards re-entry." `isImporting` is written (set `true` at the start, `false` in both completion paths) but never *read* as a precondition, so it is a display flag only.
- **Ruled out:** "the two call sites cannot overlap." They can — the app processes pending imports at launch (`audio_manager.swift:84-88`) and the share extension processes its own batch whenever the user shares again. Both write the same container.
- **To confirm:** share a second batch while the first import is still in flight, or trigger a share immediately after launching with pending files.
- **Fix shape:** an actor or a lock around the pending directory, plus an actual precondition check — and see [B6](#b6-unsynchronised-fileurlsappend-in-the-extension) for the same class of bug in the extension process.

### B9 Playlist-detail share hands out the live file

**High.**

`PlaylisList_view.swift:304-309` shares `audioManager.urlForSharing($0)` — the real file in `fileDirectory` — and "Delete N Files" sits at `:310-312` in the same menu. Deleting during or right after a share leaves the receiving app with a URL that no longer resolves. The Songs tab avoids this by copying to a temp directory first; the playlist path and the single-song menu (`View/content_view.swift:1611-1614`) do not.

**Fix:** route every share through `prepareFilesForSharing`.

**Exploration notes.**
- **Ruled out:** "it copies to a temporary location like the multi-select path does." Only the multi-select path copies, via `prepareFilesForSharing`. The single-song and playlist-detail paths hand out `audioManager.urlForSharing`, which is the live file (`AudioLibraryService.swift:125-127`).
- **Ruled out:** "the receiving app copies before the sender can delete." Share extensions are handed a security-scoped URL; nothing guarantees the sender keeps the file.
- **To confirm:** share a song from playlist detail, then delete the song in the app, then open the shared item. It fails, because the path no longer resolves.
- **Contrast worth keeping:** the multi-select path already does the right thing, so this is a case of one correct implementation and two incorrect ones rather than a missing capability. See [B10](#b10-preparefilesforsharing-leaks-and-drops-files) for why the correct path is not simply reusable.

### B10 `prepareFilesForSharing` leaks and drops files

**Medium.**

`View/content_view.swift:1443-1448` creates `temporaryDirectory/<uuid>/`; `onDismiss` (`:863-865`) removes only the files inside, never the directory — one empty directory leaked per share session. And `:1381-1384` copies by `lastPathComponent`, so two same-named files in one selection collide, the `copyItem` fails, the `print` at `:1387` swallows it, and that file is silently omitted from the share.

**Fix:** remove the directory; de-duplicate destination names with a counter suffix.

### B11 `ContentView.shareURL` is dead code

**Medium.**

`@State private var shareURL: URL?` (`View/content_view.swift:25`) is threaded into `applySheets` (`:76`, `:608`, `:617`) and read at `:617`, but **nothing ever assigns it.** The share sheet at `:616-620` can never present. Every live share uses the plural `shareURLs`.

**Fix:** delete the state, the parameter, and the sheet.

### B12 The extension reaches for `UIApplication`

**Medium.**

`ShareViewController` walks the responder chain to call `UIApplication.shared.open`. This is not permitted from an app extension, and with no URL scheme registered ([B3](#b3-punchesopenandplay-is-not-registered)) there is nothing to open. Use `extensionContext.completeRequest` / `open(_:completionHandler:)` instead.

### B13 `Punches3-Info.plist` has no `UIFileSharingEnabled`

**Low.**

No iTunes/Files file sharing, and no `LSSupportsOpeningDocumentsInPlace`. Intentional or not, it means the imported `AudioFiles/` directory is only reachable by the app.

---

## C — Data Integrity & Persistence

### C1 Master-playlist recovery destroys every user playlist

**Critical.**

If `masterPlaylistID` becomes unreadable for any reason — decode failure, partial `UserDefaults` write, a schema change to `Playlist` that makes `loadPlaylists()` return fewer entries, a sync conflict — `clearZombiePlaylists` deletes **all** playlists including the user's, and rebuilds only the master. No backup, no prompt, no undo. `AudioLibraryService`'s `:63-67` back-fill is also O(n²).

**Fix:** fail loudly and keep the old data; never delete a playlist that is not provably the master. Add a unit test.

**Exploration notes.**
- **Ruled out:** "the master playlist ID is stable, so recovery never runs." It is re-read from `UserDefaults` every launch, and *any* mismatch — a wiped key, a failed `loadPlaylists`, a decode throw — routes into `clearZombiePlaylists`, which assigns `playlists = []` and saves that over the top.
- **Ruled out:** "the guard is `playlists.contains(where:)`, so an empty array simply fails gracefully." Failing gracefully is the problem: an empty array makes the check fail, which triggers the wipe.
- **To confirm:** delete only the `masterPlaylistID` key and relaunch. Every user playlist is gone and cannot be recovered.
- **Fix shape:** never destroy user data during recovery. Create a new master playlist alongside the existing ones and leave them untouched. This is the same "recovery must not be destructive" rule as [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) — consider fixing them with one shared code path.
- **Note:** this entry is referenced from the [reported symptoms table](14-known-issues.md#reported-symptoms) as a data-loss contributor.
- **⚠️ This is the trap that made the album feature dangerous.** Albums added three stored properties to `Playlist` (`isAlbum`, `coverIsManual`, `artist` — [08 §2.2](08-playlists-and-library.md#22-playlist)). With the **synthesised** decoder, all three would be *required* keys, every existing blob would throw, `loadOrCreateMasterPlaylist` would catch it, and **every user playlist and album would be deleted on the next launch** — with no migration and no error. The working tree avoids this by giving `Playlist` a hand-written `init(from:)` in which every added key uses `decodeIfPresent(…) ?? default`. So this entry is **still Critical**: the underlying recovery path is untouched, and any *future* field added without `decodeIfPresent` re-opens it. Nothing enforces that convention — there is no test, no lint, and the compiler will not object.
- **Suggested regression test:** encode a `Playlist` array with the pre-album key set (`id`, `name`, `audioFileIDs`, `dateAdded`, `artworkImageName` only), decode it, and assert all three new fields take their defaults and that `audioFileIDs` order survives. This is the single highest-value test in the project and the test targets are empty ([A2](#a2-both-test-targets-are-empty)).

### C2 `cleanupOrphanedFiles` deletes untracked files

**Critical.**

`AudioLibraryService.cleanupOrphanedFiles()` (`:92-106`) removes anything in `fileDirectory` that is not in the persisted `audioFiles` array, with a single hardcoded exemption for the literal name `"Artwork"` (`:101`). A file present on disk but absent from `UserDefaults` — after a failed save, a partial migration, or a restore from backup — is destroyed on next launch.

**Fix:** only delete files matching a known import-name pattern *and* older than some threshold; or invert to an allowlist of files the app itself wrote and never GC on launch at all.

**Exploration notes.**
- **Ruled out:** "the exemption list is just incomplete." The single hardcoded name is a symptom. Even a complete list would not help, because the rule is "delete anything not in `UserDefaults`", and the index is the least reliable thing in the app — see [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) for how it becomes empty.
- **Aggravating factor:** the two `fileDirectory` branches are not the same directory. With the app group available it appends `"AudioFiles"` (`audio_manager.swift:49`); without it — the committed state, see [A3](#a3-app-group-entitlement-is-empty) — it returns the **Documents root** (`:53`). In the fallback case this function scans and deletes the user's entire Documents directory, not an app-owned subdirectory.
- **To confirm:** log the resolved `fileDirectory` path once at launch. If it is not the app group, every non-`"Artwork"` entry in Documents is a candidate for deletion.
- **Suggested test:** put a file in Documents that the app never imported, launch, and check whether it survives. It should not.

### C3 `Task.detached` races `savePlaylists()` on the same key

**High — FIXED in the working tree, uncommitted.**

`PlaylistService.createPlaylist` (`:118-129`) snapshots `manager.playlists` and writes it to `UserDefaults` from a `.utility` detached task. Every other mutator writes the same key synchronously from main. `UserDefaults.set` is last-writer-wins, so a create followed by any faster mutation loses the playlist. It is intermittent because `.utility` usually loses to main. The detached task also reads `self.manager.playlistsKey` off the main actor — an isolation violation, unobserved only because of [A1](#a1-the-target-compiles-7-of-30-swift-files).

**Fix:** delete the `Task.detached` and call `savePlaylists()`. — **Done.** `createPlaylist(name:isAlbum:artist:)` is now `PlaylistService.swift:197-201`: append, `savePlaylists()`, inline. `AudioManager.createAlbum` (`:150-153`) is a plain synchronous call for the same reason. The `DispatchQueue.main.async` hop in `AudioManager.createPlaylist` (`:144-147`) is redundant but harmless, since the whole app is `@MainActor` by default ([03](03-project-structure-and-build.md)).

**Exploration notes.**
- **Ruled out:** "`UserDefaults` serialises writes, so there is no race." It serialises access to the plist; it does not make a read-modify-write across two tasks atomic. Both tasks can encode the same stale array, and the last writer wins.
- **Ruled out:** "the detached task only ever appends." It re-encodes the whole array from whatever `manager.playlists` holds at that moment.
- ~~**To confirm:** reorder playlists quickly enough to hit both the `Task.detached` save and the `DispatchQueue.main.async` save in `createPlaylist`. The lost write is intermittent by nature, so a single run proves nothing — run it in a loop.~~ **No longer applicable** — there is one writer path now, so the race is structurally impossible. Verify instead that a rapid create-then-rename-then-add sequence leaves all three changes on disk.
- **Fix shape:** a single serial writer (an actor, or one dedicated queue) for all `UserDefaults` mutations. The same fix closes [E6](#e6-taskdetached-writes-userdefaults-off-main) and part of [C9](#c9-no-serial-write-queue-for-userdefaults). ⚠️ **Only the `createPlaylist` half is done.** The serial-writer recommendation still stands for every other key — see [C9](#c9-no-serial-write-queue-for-userdefaults) and [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see).

### C4 Reordering does not update `playbackQueue`

**High.**

`PlaylistService.reorderPlaylistSongs` (`:91-101`) mutates `manager.playlists[index].audioFileIDs` but never rebuilds `manager.playbackQueue`, unlike its Songs-tab sibling `updatePlaylistOrder` (`:103-114`) which does. Drag-reordering inside a playlist therefore leaves the playing queue in the old order for the rest of the session.

**Fix:** mirror `updatePlaylistOrder`'s queue rebuild.

**Exploration notes.**
- **Ruled out:** "`playbackQueue` is derived, so it cannot go stale." It is a stored array, assigned at `init`, on play when the context is empty, and on import. Reordering does not recompute it.
- **Ruled out:** "reorder always updates the queue." `reorderSelectedSongs` updates it in exactly one of its two branches, and the `onMove` path for the Songs tab goes through a different function entirely.
- **To confirm:** reorder two songs in the Songs tab, then press next. The queue follows the pre-reorder order.
- **Note:** this compounds [C14](#c14-manual-sort-order-is-silently-discarded) — the manual order is not only discarded on read, it is never applied to the queue either. Fixing the ordering model first would make this easier to reason about.

### C5 `reorderPlaylistSongs` captures `index` across a dispatch hop

**High.**

The same function hops to `DispatchQueue.main.async` (`:97`) before writing `self.manager.playlists[index] = updatedPlaylist`. The closure captures the integer `index` by value. Any playlist created, deleted or reordered in that window writes to the wrong row or resurrects a deleted playlist. The hop is unnecessary — the code is already on the main actor.

**Fix:** delete the `async`.

**Exploration notes.**
- **Ruled out:** "the index is recomputed inside the async block." It is captured by value at the call site and used later, so it refers to the list as it was *before* any concurrent mutation.
- **Ruled out:** "the mutation is main-actor isolated so the capture is safe." The capture happens before the hop; the isolation does not retroactively make it correct.
- **To confirm:** reorder in playlist detail and inspect the persisted `audioFileIDs`. The order will not match what is on screen.
- **Note:** the multi-select variant of the same operation is [E7](#e7-reorderplaylistsongs-mutates-state-across-a-dispatch-hop). Both stem from a computed value crossing a concurrency boundary; a single `let snapshot = …` taken on the main actor immediately before the work would fix both.

### C6 tempo, pitch and loop are not persisted

**High.**

`audio_manager.swift:14` (`tempo`), `:15` (`pitch`), `:18` (`isLooping`) are plain `@Published` vars with no `UserDefaults` writer. These are exactly the three states a user expects to survive a relaunch. Almost certainly unintentional — every other playback preference is saved.

**Fix:** three keys, three `didSet` writers, three load lines.

**Exploration notes.**
- **Ruled out:** "they are persisted somewhere else, like the theme values." They are not. `ThemeManager` persists 30 comparable values, which is precisely the inconsistency — the pattern exists and was simply not applied here.
- **Ruled out:** "the engine restores them." The engine reads the current in-memory values on `play`; nothing reads a stored value.
- **To confirm:** change tempo, force-quit, relaunch. `tempo` is `1.0` again, and `isLooping` is `false`.
- **Interaction:** [D1](#d1-loop-is-honoured-only-at-the-end-of-the-queue) is the other half of the loop story — the flag is read but mis-scoped, and not persisted. Fix both together or the control stays confusing.

### C7 Search shows an empty list with no empty state

**Medium.**

`filteredSongs` filters the manual order, but `songsPage`'s empty-state check (`View/content_view.swift:234`) tests `audioManager.audioFiles.isEmpty` — the **unfiltered** array. With a search active and no matches, the user sees a blank list with no "no results" message. Playlists have the same bug at `:172` (`playlists.count == 1`).

**Fix:** test the filtered arrays.

### C8 The two `AudioFile.title` fallbacks disagree

**Medium.**

`Models.swift` import path gives `title == "song"`; the `?? fileName` fallback gives `"song.mp3"`. The fallback is currently unreachable — a non-optional `String` makes the synthesised `init(from:)` **throw** on a missing key rather than pass `nil` — so this is latent. A hand-written decoder or a schema migration would activate it.

**Fix:** use `deletingPathExtension`.

### C9 No serial write queue for `UserDefaults`

**Medium.**

There is no serialisation or coalescing anywhere: `savePlaylists`, `saveAudioFiles` and `saveVisualisationMode` all write from wherever they are called. This is what makes C3 possible.

**Fix:** a single serial writer on the main actor.

### C10 `hexString` quantises on every save

**Low.**

`Int(r * 255)` truncates rather than rounds (`View/setting_View.swift:896`), so each save/load round-trip can shift a channel by up to 1/255, and alpha is dropped entirely. Harmless for shipped presets; a user-set custom colour drifts slightly on every relaunch.

### C11 `Color(hex:)` truncates on 3-digit input

**Low.**

`View/setting_View.swift:831-839` scans the string as one hex integer, so `#abc` becomes `r=0, g=0xa, b=0xc` — near-black, not `#aabbcc`. All 35 presets use 6-digit form, so this is latent. There is also no failure path: a string with no hex digits yields opaque black rather than the caller's fallback.

### C12 An empty library index makes the app delete every file it can see

**Critical.**

> **User report:** *"there is no file permanence when you add files, it disappears after closing the application."*

This is the mechanism behind that report, and it is the most destructive defect in the codebase. The library index is a **single JSON blob in `UserDefaults.standard`**, and the app treats "index missing or undecodable" as "library is empty" and then **deletes the audio files from disk**.

The chain, in launch order:

1. `AudioLibraryService.loadAudioFiles()` (`:11`) opens with `guard let data = UserDefaults.standard.data(forKey: manager.audioFilesKey) else { return }` (`:12`). If the key is absent, the function returns with `manager.audioFiles` still `[]` — it does **not** fall back to scanning the directory.
2. The decode is **all-or-nothing over the whole array** (`:15`): `try JSONDecoder().decode([AudioFile].self, from: data)`. A single throw is caught and printed (`:25-27`), leaving `audioFiles == []`. Every song is lost from the index, not just the bad one.
3. `AudioFile` (`:3` of `Models.swift`) uses **synthesized `Codable`** — no `CodingKeys`, no `init(from:)`, no `decodeIfPresent` defaults. Any field added, renamed, or retyped between two installs of the app invalidates the entire blob, and the app cannot be built twice with a changed model without losing every library.
4. Still in `AudioManager.init`, a `Task` runs `processPendingImports()` and then `cleanupOrphanedFiles()` (`audio_manager.swift:84-88`).
5. `cleanupOrphanedFiles` builds `trackedFileNames` from the now-empty `audioFiles` (`:93`) and removes **every** entry in `fileDirectory` that is not literally named `"Artwork"` (`:99-104`).

The files are not hidden — they are unlinked. There is no Trash, no backup, and no confirmation.

Aggravating factor: the two branches of `fileDirectory` (`audio_manager.swift:47-55`) are not the same directory. With the app group available it appends `"AudioFiles"` (`:49`); without it — which is the committed state, see [A3](#a3-app-group-entitlement-is-empty) — it returns the **Documents root** (`:53`). So `cleanupOrphanedFiles` scans and deletes the user's entire Documents directory minus one hardcoded name.

**Fix:** treat the directory as the source of truth and `UserDefaults` as a cache. Scan `fileDirectory` on launch and reconcile against the index rather than the other way round; delete nothing on a launch where the index failed to load. If a GC is wanted at all, restrict it to files matching a known import pattern that are older than a grace period, and never run it on the same launch as a failed decode.

**Exploration notes.**
- **Ruled out:** "the Documents directory is cleared on relaunch." iOS preserves `Documents/` across ordinary launches; the wipe is this code path, not the platform.
- **Ruled out:** "imports are never saved." `saveAudioFiles()` is called on every import (`AudioImportService.swift:68`), and the write is synchronous `UserDefaults.set`.
- **Ruled out:** "a non-finite duration corrupts the blob." The importer rejects NaN/infinite durations and deletes the copy before throwing (`AudioImportService.swift:59-62`), so `JSONEncoder` should not see one.
- **To confirm:** the *mechanism* is proven from source; the *trigger* is not. Instrument `loadAudioFiles` to log which branch it took and the decode error verbatim, and make `cleanupOrphanedFiles` log a dry-run summary (`would delete N files`) before it deletes anything. Then ask the reporter what they did immediately before the files vanished — reinstall, Xcode "Run" with a changed model, iCloud restore, or a `UserDefaults` reset are the candidates that fit.
- **Watch for:** the same all-or-nothing pattern in `loadPlaylists` (`PlaylistService.swift:81`) and in `loadOrCreateMasterPlaylist` (`:53-56`), which is the root of [C1](#c1-master-playlist-recovery-destroys-every-user-playlist).

### C13 The app opens on the oldest import, not the top of the list

**High.**

> **User report:** *"songs should default to the top of the list not the bottom… when you open the application it is defaulted to the oldest imported song."*

The sort is correct. `sortedAudioFiles` sorts `$0.dateAdded > $1.dateAdded` — newest first — in **both** branches (`PlaylistService.swift:14` and `:19`). The bug is that two different arrays are used for two different jobs, and only one of them is sorted.

- `manager.audioFiles` is the raw array. It is only ever `append`ed to (`AudioImportService.swift:67`) and `removeAll`-filtered on delete. **Nothing ever sorts it**, and `saveAudioFiles` persists it in that append order, so the order survives relaunch.
- `manager.displayedSongs` is the sorted snapshot the list actually renders (`View/content_view.swift:270`).

The player page falls back to the **unsorted** array:

```swift
// View/content_view.swift:258
if let file = selectedAudioFile ?? audioManager.audioFiles.first {
```

`selectedAudioFile` is `@State`, so it is `nil` on every fresh launch. `audioFiles.first` is therefore the **first song ever imported**. The same fallback exists on the Player tab button (`:487-488`). So on launch the app selects the oldest song while the Songs list shows newest-first.

Secondary defect in the same area: the refresh of `displayedSongs` on import sits **inside** the master-playlist guard (`AudioImportService.swift:70-75`). If the master playlist cannot be resolved, the file is appended and saved but the snapshot is never rebuilt, so the new song does not appear until relaunch.

**Fix:** use `sortedAudioFiles` (or `playbackQueue`) for the fallback instead of `audioFiles.first`, and move the `displayedSongs` assignment in the import path outside the master-playlist guard.

**Exploration notes.**
- **Ruled out:** "the sort comparator is inverted." `$0.dateAdded > $1.dateAdded` is unambiguously newest-first in both branches; confirmed by inspection, not inferred.
- **Ruled out:** "SwiftUI is dropping an off-main `@Published` update, so the list shows a stale append order." The mutation is wrapped in `await MainActor.run` (`AudioImportService.swift:66`), so the publish is on the main actor. This was worth checking because `displayedSongs` is a snapshot rather than a computed property, but it is not the cause.
- **Ruled out:** "the list itself is misordered." The list reads `displayedSongs`, which is correctly newest-first after any import, delete, or rename. The defect is confined to which song the *player* defaults to.
- **To confirm:** log `audioFiles.first?.title` and `displayedSongs.first?.title` at first render. They should differ by the whole library.

### C14 Manual sort order is silently discarded

**Medium.**

`sortedAudioFiles` reads the master playlist's `audioFileIDs` — which is the user's manual order, written by `reorderSongs` (`PlaylistService.swift:118-128`) — and then **re-sorts it**, throwing that order away:

```swift
// Services/PlaylistService.swift:17-19
return masterPlaylist.audioFileIDs
    .compactMap { id in manager.audioFiles.first { $0.id == id } }
    .sorted { $0.dateAdded > $1.dateAdded }
```

Drag-to-reorder mutates `displayedSongs` in place and persists the IDs, so the new order *looks* correct. The next time anything recomputes `displayedSongs = sortedAudioFiles` — import, delete, rename, artwork change, `reorderSelectedSongs`, or the next `init` — the list silently snaps back to date order. There are three sources of truth for one ordering: the master playlist's ID array, the `displayedSongs` snapshot, and the date sort applied on read.

**Fix:** choose one. If manual order is the intent, drop the `.sorted` on line 19 and append new imports to the end of `audioFileIDs`. If date order is the intent, remove the reorder affordance rather than accepting an order that is discarded.

**Exploration notes.**
- **Ruled out:** "reorder is not persisted." It is — `savePlaylists()` is called on the reordered IDs. It is persisted and then ignored on read.
- **To confirm:** reorder two songs, then trigger any mutation (rename one), and observe the order revert. The revert is the tell.
- **Note:** this interacts with [C4](#c4-reordering-does-not-update-playbackqueue) and [C5](#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop) — all three are consequences of the same split between "the order in the ID array" and "the order the view shows."

---

## D — Dead Code & Unfinished Features

### D1 Loop is honoured only at the end of the queue

**High.**

> **Correction to an earlier revision of this register:** this entry previously claimed *"`isLooping` has no reader anywhere in the codebase."* That was wrong. `isLooping` **is** read, at `Services/AudioPlaybackService.swift:190`. The control is not dead; it is mis-scoped, which is a smaller and more fixable problem than a dead one.

`View/audio_player_view.swift:217` toggles `audioManager.isLooping` and switches the icon between `repeat` and `repeat.1` (`:219`). The single read is the **end-of-queue** branch of `skipNextSong`:

```swift
// `Services/AudioPlaybackService.swift:189-196`
} else {
    if manager.isLooping {
        if let firstFile = manager.playbackQueue.first { ... }
    } else {
        stop()
    }
}
```

So the actual behaviour is: reaching the end of the queue wraps around to the first song if the flag is set. Nothing else consults it. The mid-queue advance (`:185-188`) never repeats, and neither of the two advance mechanisms in [E15](#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song) reads the flag at all.

The visible mismatch is the icon: `repeat.1` means *repeat this song*, but the code performs *repeat the whole queue*. A user who taps the button expecting the current track to loop gets a single pass through the queue instead, with no feedback that the two meanings differ.

**Fix:** decide which semantic is wanted. If repeat-one, check `isLooping` at the top of `skipNextSong` and re-play the current file. If repeat-all, the icon should be `repeat`, and the flag should also be persisted (see [C6](#c6-tempo-pitch-and-loop-are-not-persisted)).

**Exploration notes.**
- **Ruled out:** "the toggle does not write." It does — `audioManager.isLooping.toggle()` at `audio_player_view.swift:217` sets the `@Published` property, and the icon at `:219-221` reflects it.
- **Ruled out:** "a missing reader means the feature was never wired." The queue-wrap read exists; the feature is partially wired, which is why it appears broken only in the repeat-one case.
- **To confirm:** with one song in the queue and the flag on, finishing it wraps to the same song — so a single-song queue cannot distinguish the two semantics. Use a three-song queue and press next on the last track.

### D2 Tempo control is commented out

**High.**

`tempoControl` is fully implemented — `View/audio_player_view.swift:230-266`, a `0.1...1.9` slider on `audioManager.setTempo` with a reset button at `:306-315`. The call site is `//tempoControl` at **line 22**. `AudioManager.setTempo` and the `AVAudioUnitTimePitch.rate` plumbing are all still present.

**Fix:** un-comment line 22. While there, the right-hand end label reads `2.0x` (`:260`) but the range maximum is `1.9` (`:248`).

**Exploration notes.**
- **Ruled out:** "the control is present but disabled." The tempo row is commented out at the call site in `PitchControl`; the rest of the control (pitch) renders normally, so the layout looks deliberately reduced rather than broken.
- **Ruled out:** "`setTempo` is unimplemented." It is implemented and forwarded to the engine's `AVAudioUnitTimePitch`. Only the UI is missing.
- **To confirm:** this is a visual check. Open the player and compare against `PitchControl` — the tempo row is absent from the source entirely.
- **Fix shape:** uncomment and add the same `ThemeManager` property + `UserDefaults` persistence the pitch control already uses, which also closes [C6](#c6-tempo-pitch-and-loop-are-not-persisted).

### D3 Unused `AudioHealthHUD`

**High.**

`AudioHealthHUD.swift` (root level) is the only file in that directory position that gets a `PBXBuildFile` entry (`:19`, `:399`) — so it **is** in the target, and it is the only debug view that is. It has **zero call sites**: nothing constructs `AudioHealthHUD()`. It displays `tapCallbackMaxUs` and `tapOverrunCount`, which is exactly the instrumentation that would have caught [E1](#e1-rt-thread-allocates-19-mbs).

**Fix:** add it to the player's `ZStack` behind `#if DEBUG`, or delete it.

**Exploration notes.**
- **Ruled out:** "it is wired behind a debug menu." It is behind `#if DEBUG` and has **no call site at all** — the grep for its type name outside its own definition returns nothing.
- **Ruled out:** "it is reachable from SwiftUI by type name." SwiftUI needs an instantiation site; there is none.
- **To confirm:** `grep -rn AudioHealthHUD --include=*.swift` returns only the definition. In a Debug build it is compiled and never shown.
- **Recommendation:** delete rather than wire. It reads the analyser on the main thread at UI rate, which is the same cost problem as [E12](#e12-goniometer-iir-filtering-runs-on-the-main-thread-at-ui-rate) — building it out would reintroduce that. See also [D5](#d5-spectrumview-has-zero-call-sites) and [D6](#d6-goniometermanagerswift-is-a-tombstone) for the same pattern.

### D4 No volume control

**High.**

`@State private var volume: Float = 1.0` (`View/audio_player_view.swift:8`) is declared and never read. No `MPVolumeView`, no `outputVolume` binding, no slider. The user has hardware volume only.

**Fix:** add a slider, or delete the dead `@State`.

**Exploration notes.**
- **Ruled out:** "volume is handled by the system or by the lock screen." Neither. `AVAudioPlayerNode.volume` is left at its default of `1.0` and nothing in the app changes it.
- **Ruled out:** "there is a volume control that was hidden." `setVolume` exists and is forwarded to the engine, but there is no UI that calls it, no `@Published` property behind it, and no persisted value.
- **To confirm:** there is no route from any screen to volume. This one needs no instrumentation.
- **Related:** the same "the plumbing exists, the UI does not" shape as [D2](#d2-tempo-control-is-commented-out) and [C6](#c6-tempo-pitch-and-loop-are-not-persisted). Both are small once the persistence pattern is in place.
- **Note:** volume is not persisted, so it will need to join the [C6](#c6-tempo-pitch-and-loop-are-not-persisted) work rather than be bolted on separately.

### D5 `SpectrumView` has zero call sites

**Medium.**

`View/SpectrumView.swift`, 109 lines. The only references are three commented-out lines (`View/audio_player_view.swift:51`, `:61`). Superseded by `Q3SpectrumView` in every respect.

**Fix:** delete it.

### D6 `goniometerManager.swift` is a tombstone

**Medium.**

The file exists solely to explain that `GoniometerManager` was **deleted** — because only one tap is permitted per mixer bus and `UnifiedAudioAnalyser` already owns it. It is 30 lines of comment and no code, and it is in the `AudioMeters` exclusion list (`:84`).

**Fix:** keep it; this is exactly what a tombstone is for. But move the note to the top of `goniometerView.swift` so it is found from the live code.

### D7 `FrequencyAllignmenttest.swift` is not a test

**Medium.**

No `XCTestCase`, no `test` methods. A print-based utility with a `FrequencyMapper` enum documented as "the central source of truth" for the whole project — which nothing imports ([G7](#g7-frequencymapper-is-referenced-by-nothing)). It is in `Punches3Tests`' exclusion list, so it never even builds as a test bundle.

**Fix:** move `FrequencyMapper` into the app target and make it real ([G3](#g3-three-incompatible-frequencyband-conventions)); leave the prints in a separate utility.

### D8 The 32-band analyser output is unused

**Medium.**

`UnifiedAudioAnalyser` computes a full 32-band spectrum alongside the 128-band Q3 path, and 16 of its 18 `@Published` properties have no consumer. Three FFTs run per frame where one would do ([G4](#g4-three-ffts-per-frame-with-no-consumer)).

**Fix:** delete the 32-band path if the 32-band layout mode is gone.

### D9 Commented-out visualisation modes

**Low.**

`.both` (`View/audio_player_view.swift:49-63`) and `.spectrumOnly` (`:65-69`) are both fully written and both commented out. `VisualisationMode` has three live cases. If they are not coming back, delete them and the cases.

### D10 The root `README.md` requirements are wrong by a decade

**Medium.**

`README.md:38-41` says "iOS 16 or later / Xcode 15 or later". The deployment target is **iOS 26.2** (`project.pbxproj:489`, `:544`) and the project uses `objectVersion = 77` (`:6`), which Xcode 15 cannot open at all. `README.md:20` also names the spectrum mode "Analyser" when the case is `Spectrum`, and `README.md:45` claims AudioKit underpins the graph when it is unused by the engine.

### D11 The root `README.md` overstates the goniometer's filtering

**Low.**

`README.md:25` says the bands are formed by "IIR low-pass filters" as though a crossover. They are three independent first-order low-passes, so the bands overlap heavily and neither 300 Hz nor 3 kHz is a −3 dB crossover. The zoom and phase-correlation claims are accurate.

### D12 Artwork decoding is not cached at the call site

**Medium.**

`audioManager.artworkService.loadArtworkImage(name)` runs inside `AudioPlayerView.body` (`View/audio_player_view.swift:81`), and `body` re-evaluates at up to 60 Hz whenever any observed object publishes. A full JPEG decode from disk on every evaluation, 60 times a second, while the visualiser is animating.

**Fix:** load once into `@State`, or cache in `ArtworkService` by name.

### D13 `SettingsView` has no audio settings at all

**Medium.**

`View/setting_View.swift:1158` is a theme and background-effect editor. No volume, pitch, tempo, loop, output routing, session, import, or diagnostics. Titled "Settings" behind a gear, reachable only from the Songs tab's overflow menu (`View/content_view.swift:366-368`).

### D14 No metadata is read anywhere; the title is the filename

**High.**

> **User report:** *"there is no effective metadata integration."*

This is not a display gap. **The codebase never reads audio metadata at all.** A repository-wide search for `AVMetadataItem`, `commonMetadata`, `artist`, `album`, `genre` returns **zero hits in any `.swift` file**. The only `AVAsset` usage in the project is the import service's single-property duration read.

The model cannot represent metadata even if some were available (`Models.swift:3-32`). `AudioFile` carries exactly six fields — `id`, `fileName`, `dateAdded`, `audioDuration`, `artworkImageName`, `title` — and **no artist, album, genre, track number, year, or comment**. There is no `Codable` upgrade path for adding any, because the conformance is synthesized with no `decodeIfPresent` defaults (see [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see)).

What exists instead:

| Concern | Current behaviour | Where |
|---|---|---|
| Title | filename minus extension, set once at import | `Models.swift:21` |
| Duration | `try await asset.load(.duration)` — the **only** metadata read | `AudioImportService.swift:55-57` |
| Artist / album / genre | no field on `AudioFile`, no read, no UI | — |
| **Album** | **a user-constructed collection, not metadata** — `Playlist` with `isAlbum` and a manually-typed `artist`, both persisted | `Models.swift:40-113` |
| Embedded artwork | never extracted; only set by hand via `ArtworkService.setArtwork` | `Services/ArtworkService.swift` |
| Search | matches `title`; also matches album title and **manually-typed** album artist | `View/content_view.swift:272`, `:282-287` |

> **The album feature makes this entry more visible, not smaller.** An album *looks* like the thing audio metadata would give you, so a user reading the grid will reasonably expect the artist line to be the real one from the file's tags. It is not: it is a string the user typed into an alert, and the album's membership is whatever order they added the songs in. `Playlist.artist` was added **specifically to `Playlist`, not `AudioFile`**, because adding fields to `AudioFile` is the [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) trigger. The honest framing is that albums are a manual curation feature layered on top of a library with no metadata, not a first step toward reading it.

Two of the table's rows are the same defect wearing different clothes. The import path builds `AVURLAsset(url: options: nil)` (`AudioImportService.swift:55`), so an asset still backed by iCloud is read **synchronously and un-awaited** at that point rather than being told to fetch; and the two `AudioFile` initialisers disagree about the title — `:21` strips the extension, the decoding initialiser at `:30` keeps the full `fileName` — which is [C8](#c8-the-two-audiofiletitle-fallbacks-disagree).

**Fix:** read `AVURLAsset.commonMetadata` (or `load(.commonMetadata)`) during import and extend `AudioFile` with artist/album/genre/track/year, adding a `CodingKeys` enum and `init(from:)` that uses `decodeIfPresent` with defaults for every added field. Migrate existing entries on next launch. Surface artist under the title, and let search match artist and album as well as title. Extract embedded artwork into the existing `artworkImageName` path rather than inventing a second one.

**Exploration notes.**
- **Ruled out:** "the metadata is there but the UI does not show it." The model has no fields for it, so this is not a view-layer omission.
- **Ruled out:** "artwork comes from embedded tags." It does not — `ArtworkService` only ever receives images pushed from the UI, and the import path never touches `commonMetadata`.
- **Ruled out:** "the `AVAsset` call is already doing it." `AudioImportService.swift:56` awaits exactly one key path, `.duration`.
- **To confirm:** drop a tagged M4A with a non-matching filename tag into the picker. Title, duration, and artwork should all come from the filename and from a manual set, proving nothing is read.
- **Ordering hazard:** adding fields to `AudioFile` *without* a custom decoder is the exact trigger for [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) wiping the library. Fix C12 first, or land the two changes together.
- **Confirmed by the album work:** this hazard is not theoretical. Adding `isAlbum` / `coverIsManual` / `artist` to `Playlist` would have triggered [C1](#c1-master-playlist-recovery-destroys-every-user-playlist) — deleting every user playlist and album on next launch — and was only safe because `Playlist` was given a hand-written `init(from:)` with `decodeIfPresent` defaults ([08 §2.2](08-playlists-and-library.md#22-playlist)). **`AudioFile` still has no such decoder.** Whoever implements the fix above has to write one, and the same regression test should cover both types.
- **Suggested test:** import a tagged M4A whose ID3 artist/album differ from the filename, and assert both currently come out as nothing. Then, post-fix, assert they survive a relaunch — that second half is the part that is dangerous.

---

## E — Threading & Concurrency

### E1 RT thread allocates 1.9 MB/s

**Critical.**

`writeToRingBuffer` (`AudioMeters/UnifiedAudioAnalyser.swift:391-419`) is called directly from the `installTap` callback (`:339-343`, a real-time thread) and allocates **five heap arrays per buffer** before touching the ring buffer — two via `Array(UnsafeBufferPointer(...))` (`:398-399`), three via `[Float](repeating:)` (`:401-403`). At `hopSize = 2048` and 48 kHz that is 40 KB per tap, ≈47 taps/s, **≈1.9 MB/s of garbage on a real-time thread.** The `vDSP` calls are fine; the array construction around them is not.

**Fix:** preallocate five `UnsafeMutablePointer<Float>` buffers once and write vDSP results straight into them.

**Exploration notes.**
- **Ruled out:** "the allocation is amortised across the file." It is per buffer, per tap callback, and the callback rate is fixed by the hop size.
- **Ruled out:** "Swift's allocator reuses the memory so the cost is negligible." Reuse is not the issue; the issue is that the operation happens on a real-time thread, where any heap call may block. The rule exists for the worst case, not the average.
- **To confirm:** the arithmetic is closed-form — taps/s = `sampleRate / hopSize`; bytes = taps/s × frames × 4 × array count. An Instruments *Allocations* run scoped to the audio thread makes it authoritative.
- **Ruled out:** "the visualiser drives the tap rate." The tap rate is fixed by the hop size and is independent of frame rate. Lowering the visualiser's workload will not reduce this.
- **Note:** see [A5](#a5-the-rt-thread-allocates-on-a-real-time-queue), which is the same finding recorded from the build side.

### E2 RT closure calls a main-actor method

**Critical.**

With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`project.pbxproj:585`, `:624`), `UnifiedAudioAnalyser` **is** main-actor-isolated, yet `self?.writeToRingBuffer(buffer)` (`:343`) is invoked from the RT closure. That is an isolation violation, unobserved only because of [A1](#a1-the-target-compiles-7-of-30-swift-files). It becomes a compile error the moment membership is repaired.

**Fix:** make `RingBuffer` a non-isolated value type and the analyser's RT entry point `nonisolated`. Do this together with E1.

**Exploration notes.**
- **Ruled out:** "the tap callback runs on the main queue." It runs on the audio render thread, which is the whole problem.
- **Ruled out:** "the default `SWIFT_DEFAULT_ACTOR_ISOLATION` setting makes the hop implicit and therefore free." The hop is a real `DispatchQueue.main.async` — which is exactly why it is not RT-safe. The build setting hides the *call site* requirement, not the cost.
- **To confirm:** this is currently latent only because [A1](#a1-the-target-compiles-7-of-30-swift-files) keeps the file out of the target. Repair membership and the compiler will name the actor violation directly. No runtime instrumentation needed.
- **Trade-off to evaluate, not assume:** hopping to the main actor is safe but adds latency to the audio path. The alternative is to keep the update on the render thread and let the visualiser read a lock-protected snapshot. Both are defensible; the current code is neither.

### E3 `mach_timebase_info` on every tap callback

**High.**

`UnifiedAudioAnalyser.swift:346-347` calls it inside the DEBUG timing wrapper to convert absolute-time units to nanoseconds — in the one place you must not do work. Hoist to a `static let`.

**Exploration notes.**
- **Ruled out:** "it is a pure function of a constant, so the compiler hoists it." It is behind a closure and the result is not provably constant to the optimiser; nothing in the source hoists it.
- **Ruled out:** "it only runs once per file." It runs on every tap callback, which is roughly 47 times per second at the default hop size.
- **To confirm:** hoist it out of the closure and measure, or count calls with `dtrace`. The fix is a one-line hoist and can be validated by inspection afterwards.
- **Note:** same category as [E1](#e1-rt-thread-allocates-19-mbs) — per-callback RT-thread work that is constant across calls. Worth sweeping the tap callback for others at the same time; see [A5](#a5-the-rt-thread-allocates-on-a-real-time-queue).

### E4 The generation cancellation gate is never wired up

**High.**

`attach(to:generation:isCurrent:)` (`:298-313`) documents that "AudioManager bumps its generation counter on every new song so stale closures self-cancel". `AudioManager` calls it as `attach(to: engine)` (`audio_manager.swift:265`), so `generation` is always `0` and `isCurrent` is always `{ true }`. The described mechanism does not exist; grepping for `generation` returns only the four lines in `UnifiedAudioAnalyser`.

**Impact:** a skip during the 150 ms window lets the stale closure install a tap on the wrong engine — wrong-track analysis, or an "already has a tap" ObjC exception.

**Fix:** implement the counter the comment already describes. Five lines.

**Exploration notes.**
- **Ruled out:** "the generation counter is incremented on play and checked on the callback." The parameter exists on `attach` and defaults to a closure that always returns `true`; nothing in the app passes a real generation check.
- **Ruled out:** "the old analyser is torn down on stop." `detach`/`reset` are never called from the playback path.
- **To confirm:** play a file, immediately stop and play another, and inspect which analyser instance the tap is feeding. A stale instance writing into a new one is the symptom.
- **Fix shape:** thread a real generation counter through `AudioManager` and gate the tap callback on it. Note the callback is [E1](#e1-rt-thread-allocates-19-mbs)'s thread, so the check must be cheap and lock-free — this is the case the existing `os_unfair_lock` pattern in the goniometer was written for.
- **Note:** this is the safeguard the code comments *describe* as existing. Read the comments before assuming the behaviour is there.

### E5 `withCheckedThrowingContinuation` can trap

**High.**

`AudioImportService.swift:36-53` has two unguarded `resume` paths — inside the `NSFileCoordinator` accessor and again for `coordinationError` at `:50-52`. `CheckedContinuation` traps on double resume. The coordinator can both invoke the accessor and report an error when a coordinated file changes mid-read. `var coordinationError: NSError?` is also a local captured by an escaping closure and written through an `NSError**` bridging shim — an exclusive-access violation in waiting.

**Fix:** single exit point guarded by a flag or an actor.

**Exploration notes.**
- **Ruled out:** "the continuation is resumed exactly once." It is resumed in the success and in-throw paths of the coordination handler **and again** in the `coordinationError` check, which is not mutually exclusive with the handler having already run.
- **Ruled out:** "`CheckedContinuation` tolerates a double resume." It traps at runtime. This is a crash, not a wrong value.
- **To confirm:** trigger a coordination failure — a file that vanishes or is unreadable between selection and copy. It should trap rather than throw a catchable error.
- **Fix shape:** use an `Unsafe*` continuation, or a flag guarding the resume, or `withTaskCancellationHandler`. Whichever is chosen, the resume must be provably single.
- **Note:** this is one of the few entries where the failure mode is a hard crash in Release too, which makes it worth fixing ahead of its nominal phase.

### E6 `Task.detached` writes `UserDefaults` off-main

**High — FIXED for the playlist key in the working tree, uncommitted.**

See [C3](#c3-taskdetached-races-saveplaylists-on-the-same-key). The only `Task.detached` writer in the app was `createPlaylist`; it is gone, so this specific off-main `UserDefaults` write no longer exists.

**Exploration notes.**
- **Ruled out:** "it is safe because `UserDefaults` is thread-safe." The individual `set` is safe. The read-modify-write around it is not — this is the same defect as [C3](#c3-taskdetached-races-saveplaylists-on-the-same-key), on a different key.
- **Ruled out:** "the detached task only ever appends." It encodes the whole array from whatever it observes.
- ~~**To confirm:** two concurrent playlist mutations in a loop; the lost write is intermittent, so a single run is not evidence either way.~~ **No longer applicable** — there is a single writer path for the playlist key. The remaining exposure is the *absence* of a serial writer for every other key, which is [C9](#c9-no-serial-write-queue-for-userdefaults).
- **Fix shape:** one serial writer for all `UserDefaults` mutations — an actor or a dedicated queue — and use it from `PlaylistService`, `LibraryService` and `ThemeManager` alike. Fixing this and [C3](#c3-taskdetached-races-saveplaylists-on-the-same-key) and [C9](#c9-no-serial-write-queue-for-userdefaults) together is cheaper than three times. **C3 and E6 are now done; C9 is not.**

### E7 `reorderPlaylistSongs` mutates state across a dispatch hop

**High.**

See [C5](#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop).

**Exploration notes.**
- **Ruled out:** "the mutation is main-actor isolated." It crosses a dispatch hop before mutating state that the UI is simultaneously observing.
- **Ruled out:** "the array is a value type so this is safe." Value semantics make the copy safe; they do not make a write that is based on a stale snapshot correct.
- **To confirm:** reorder repeatedly in quick succession and compare the persisted `audioFileIDs` against what is on screen. A mismatch is the signature.
- **Note:** the single-item variant is [C5](#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop). Both are fixed by taking one snapshot on the main actor and doing all the work from it.
- **Related:** the ordering model itself is contested in [C14](#c14-manual-sort-order-is-silently-discarded). Settle that before spending effort on the persistence race, or the persisted order will be an order nobody wants.

### E8 Audio setup is sequenced with sleeps

**Medium.**

`AudioManager.attachAnalyzerSafely` uses `asyncAfter(+0.12)` (`audio_manager.swift:261-269`); `UnifiedAudioAnalyser.attach` uses `+0.15` (`:311`); `AudioPlaybackService.swift:98` uses `+0.15`. The comment at `:308-309` says the 150 ms is "enough for AVAudioEngine to finish its internal graph reconfiguration" — an earlier version stacked delays and the fix was to stack fewer. The right answer is to observe the engine's actual state.

### E9 `RingBuffer` is labelled "Lock-Free" and is not

**Medium.**

The section header at `:8` says "Lock-Free Ring Buffer". `RingBuffer` is a `class` with `private let lock = NSLock()` (`:15`). The *discipline* is correct — `lock(); defer { unlock() }` at `:23-24` and `:33-34`, the only properly-guarded lock in the project — but `write` holds it across a 2048-sample loop, and a genuine SPSC ring would need no lock at all.

### E10 Isolation is invisible in the source

**Medium.**

Zero type-level `@MainActor`, zero `nonisolated`, zero `actor`, zero `@Sendable`, zero `@unchecked Sendable` in the whole repository. Only two method-level `@MainActor` annotations exist (`View/content_view.swift:119`, `audio_manager.swift:260`). Everything else is isolated by a build setting, so `class RingBuffer` reads as plain unannotated Swift while being main-actor-bound. Document it in `AGENTS.md`.

### E11 `ThemeManager` is not `@MainActor`

**Medium.**

`View/setting_View.swift:903` is a plain `final class ObservableObject` with `didSet` writes to `UserDefaults` and no actor annotation. Swift 6 strict-concurrency checking will flag the whole `@Published` mutation surface.

### E12 Goniometer IIR filtering runs on the main thread at UI rate

**Medium.**

The three band filters are applied in `updateUIView` (`AudioMeters/goniometerView.swift:194-199`), i.e. at SwiftUI's refresh rate, not the analyser's 60 Hz. Moving them into `UnifiedAudioAnalyser` is the single highest-value fix in the presentation layer.

### E13 DSP, shaders and layout share one budget

**Low.**

The 60 Hz analysis `Timer` (`:286-291`), three shader clocks and SwiftUI layout all run on the main run loop. Defensible at 8192-point FFT, but there is no yielding.

### E14 An interruption leaves state that reads as "still playing"

**Critical.**

> **User report:** *"when a song is playing and the user gets a call, the music stops playing but it is still registered as playing."*

The `.began` handler does three things (`Services/AudioSessionService.swift:101-105`): sets `manager.isPlaying = false`, invalidates the timer, and calls `currentEngine?.pause()`. It does **not** clear `currentlyPlayingID`, does **not** call `updateNowPlayingInfo()`, and does **not** clear `MPNowPlayingInfoCenter`. Four consequences follow:

1. **The system still reports the track as live.** `MPNowPlayingInfoPropertyPlaybackRate` is written from `manager.isPlaying` at `:186` and is never rewritten, so it keeps its last value of `1.0`. Control Center and the lock screen show the song as playing. This is the "still registered as playing" the user sees — the app's own flag is correct, the *published* one is stale.
2. **The in-app mini-player keeps a track and a frozen progress bar.** `currentlyPlayingID` survives, and `currentTime` stops updating because the timer was invalidated.
3. **Nothing restarts it.** For a phone call, `.ended` arrives **without** `.shouldResume` — the normal outcome — and that branch (`:107-119`) is gated entirely on the option, so it does nothing at all. The timer stays dead.
4. **Returning to the app does not repair it.** The `willEnterForeground` handler (`:163-174`) re-activates the session but never restarts the engine or the timer.

Recovery therefore requires a user action. `startTimer()` is reached from exactly three places — `load` (`AudioPlaybackService.swift:59`), `togglePlayPause` (`:88`), and `skipNextSong` (`:172`, only when `timer == nil`) — and **every one of them is user-initiated**. No automatic path restarts it: not the `.ended` branch, not `willEnterForeground`. The player stays frozen until the user taps something.

`stop()` has the same gap (`Services/AudioPlaybackService.swift:63-75`): it never clears `MPNowPlayingInfoCenter` either, so the identical symptom appears whenever the queue ends and `:195` calls `stop()`.

Two structural problems sit underneath:

- **`manager.isPlaying` and `AVAudioPlayerNode.isPlaying` are two unreconciled sources of truth for one fact.** `togglePlayPause` *branches* on the engine's (`:80`) but *writes* the manager's (`:82`, `:87`). Any path that moves one without the other leaves them disagreeing, and the UI reads the manager's.
- **`pause()` is the only engine mutation not serialised.** `load`, `play`, `stop`, and `seek` all dispatch onto `audioQueue` (`AudioEngines/AppleAudioEngine.swift:176`, `:192`, `:226`, `:241`), but `pause()` calls `playerNode.pause()` directly on whatever thread the notification arrived on (`:221-223`) — so it races in-flight scheduling work on the queue.

**Fix:** in the `.began` branch, also call `updateNowPlayingInfo()` (or set the rate to `0` and clear `nowPlayingInfo`) and decide explicitly whether `currentlyPlayingID` should survive. Handle the `!shouldResume` case by presenting a paused-but-resumable state rather than silently stalling. In `stop()`, clear `MPNowPlayingInfoCenter.default().nowPlayingInfo`. Then make `AppleAudioEngine.pause()` go through `audioQueue` like every sibling.

**Exploration notes.**
- **Ruled out:** "the `.began` branch is missing." It exists and does set `isPlaying = false` — which is why the bug is confusing to chase. The stale state is in the *published* now-playing info, not the flag.
- **Ruled out:** "`AVAudioPlayerDelegate` cleans up the leftover state." `AudioManager` conforms at `audio_manager.swift:270` and implements `audioPlayerDidFinishPlaying` (`:249-255`), but **nothing in the codebase is an `AVAudioPlayer`** — the engine is `AVAudioEngine` + `AVAudioPlayerNode`. That delegate method is dead and can never repair this.
- **Ruled out:** "the route-change handler is responsible." `.oldDeviceUnavailable` (`AudioSessionService.swift:125-146`) *does* call `updateNowPlayingInfo()` and correctly declines to auto-resume. A phone call is an interruption, not a route change.
- **To confirm:** log the interruption `type` and `options` raw values, plus `MPNowPlayingInfoCenter.default().nowPlayingInfo?["MPNowPlayingInfoPropertyPlaybackRate"]` immediately before and after a call. Expect `.ended` with an empty options set and a rate still at `1.0`.
- **Checked, and worth stating explicitly so nobody re-checks it:** this is **not** the same trigger as [E16](#e16-remote-commands-are-registered-inside-the-session-setup-do-block). A throw in `setupAudioSession` (`audio_manager.swift:95`) cannot suppress the interruption observer — `setupInterruptionObserver()` is called independently on the next line (`:90`), outside the `do`. So a failed session setup makes remote commands inert while interruptions are still handled normally. The two reports are separate bugs; do not merge their investigations.

### E15 Two racing mechanisms advance the queue, and a stale completion can skip a just-started song

**High.**

> **User report:** *"auto next song needs some work."*

Auto-advance is wired — but it is wired **twice**, with no coordination.

| # | Mechanism | Where |
|---|---|---|
| 1 | `engine.onPlaybackFinished = { skipNextSong() }`, fired from the last buffer's completion callback | `Services/AudioPlaybackService.swift:47-49` → `AudioEngines/AppleAudioEngine.swift:152-156` |
| 2 | the 0.2 s timer checks `currentTime >= duration && duration > 0` | `Services/AudioPlaybackService.swift:134-136` |

Both are live simultaneously, neither records that an advance is in progress, and `skipNextSong` (`:178-203`) is not re-entrant. `stopTimer()` at `:179` cancels the pending timer fire, which hides the collision in the common case — but only for mechanism 2, and only if the callback had not already been dispatched.

**The concrete failure: mechanism 1's guard is checked on the wrong queue.** The completion handler checks `isUserStopped` on `audioQueue` (`AppleAudioEngine.swift:144`) and then hops to the main queue to run the action (`:154`) **with no second check**. A completion callback that was already past the guard when the user pressed Next will therefore call `skipNextSong()` *after* the replacement track has started, skipping it. The window is real because `stop()` sets `isUserStopped = true` (`AppleEngines/AppleAudioEngine.swift:227`) but **does not clear `onPlaybackFinished`**, and `play()` reassigns that closure for the *new* track (`:47`) before the stale callback lands.

Two further problems with mechanism 2:

- **It compares two different clocks.** The left side is `engine.currentTime`, derived from `playerNode.playerTime(forNodeTime:)` (`AudioEngines/AppleAudioEngine.swift:36-40`) — a *rendered-position* clock. The right side is `manager.duration`, which is the **import-time metadata** duration (`AudioPlaybackService.swift:58` ← `AudioFile.audioDuration`). Any drift between the two makes the check fire early, cutting the track off, or never fire at all.
- **It is unreliable exactly where auto-advance matters most.** `Timer.scheduledTimer` (`:119`) runs in the default run-loop mode, so it does not fire while the user is scrolling or dragging, and it is throttled once the app is backgrounded. In the background, mechanism 1 is the *only* path that works.

`isLooping` is consulted by neither mechanism mid-queue — see the corrected [D1](#d1-loop-is-honoured-only-at-the-end-of-the-queue).

**Fix:** keep exactly one advance mechanism. Firing from the last rendered buffer is the correct signal, so delete the `currentTime >= duration` branch and drive the queue from `onPlaybackFinished` alone. Clear `onPlaybackFinished` in `AppleAudioEngine.stop()` and `load()`, and re-check `isUserStopped` on the main queue immediately before invoking it. Read `duration` from the same clock the comparison uses.

**Exploration notes.**
- **Ruled out:** "there is no auto-advance at all." It is wired twice; the problem is duplication, not absence.
- **Ruled out:** "`AVAudioPlayerDelegate` is the real completion path." `audio_manager.swift:271-278` looks like one but can never fire — no `AVAudioPlayer` exists in the project. Anyone reading `audio_manager.swift` alone will draw the wrong conclusion here.
- **Ruled out:** "the double-advance is the common cause." `stopTimer()` at `:179` normally cancels mechanism 2 in time, which is why ordinary playback behaves. The reported unreliability is more consistent with the narrow stale-callback window and the background timer throttling.
- **To confirm:** put a `print` of the `currentlyPlayingID` at entry to `skipNextSong` with a monotonic timestamp, plus the originating mechanism. A double entry within a few milliseconds of a track end is the signature. The most reliable reproduction is pressing Next exactly as a track ends.
- **Also check:** whether the track cuts out early — that is mechanism 2 comparing the render clock against the metadata duration, and it is a separate symptom of the same duplication.

### E16 Remote commands are registered inside the session-setup `do` block

**High.**

> **User report:** *"songs sometimes don't skip when out of the app."*

`beginReceivingRemoteControlEvents()` and `setupRemoteTransportControls()` are **inside the same `do` block** as the two throwing session calls:

```swift
// Services/AudioSessionService.swift:16-26
do {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playback, mode: .default)
    try audioSession.setActive(true)
    UIApplication.shared.beginReceivingRemoteControlEvents()   // :21
    setupRemoteTransportControls()                              // :22
} catch {
    print("failed to set up audio \(error.localizedDescription)")   // :24
}
```

If **either** `try` throws, control transfers to the `catch` at `:23`, which only prints — and **no remote command target is ever added**. The lock screen, Control Center, and headphone buttons are then permanently inert, with nothing in the log but a `print`.

This is a strong candidate for the word "sometimes" in the report, because the throw is environmental rather than deterministic. `setupAudioSession()` is called from `AudioManager.init` (`audio_manager.swift:95`) **before** `engineService.initialiseEngine()` (`:88`), i.e. at launch with no file loaded and no engine running — precisely the state in which `setActive(true)` is most likely to fail.

Three further defects in the same handlers, which apply even when registration succeeds:

- **`playCommand` is not idempotent.** It calls `manager.togglePlayPause()` (`:34`), which branches on `engine.isPlaying` (`AudioPlaybackService.swift:80`). The system sends `playCommand` meaning *begin or resume*; the app answers with *toggle*. Whenever the engine's idea of "playing" disagrees with what the user last asked for — which is exactly the state an interruption or a swallowed session error leaves behind — the lock screen **Play** button pauses instead. `pauseCommand` (`:55`) uses the same toggle, so both buttons have the same defect and there is no state in which the pair behaves symmetrically.
- **Next and previous always report success.** `nextTrackCommand` (`:48-52`) and `previousTrackCommand` (`:41-45`) return `.success` unconditionally, even when `skipNextSong`/`skipPreviousSong` did nothing because the queue was empty or the track was not in it. The system is told the command worked.
- **Scrub works while stopped.** `changePlaybackPositionCommand` (`:59-67`) calls `seek` without checking that anything is playing, so the scrubber moves with no audio.

**Fix:** move `beginReceivingRemoteControlEvents()` and `setupRemoteTransportControls()` out of the `do` block so registration is unconditional, and log session failures with `os.Logger` instead of `print`. Give the play command a real play/pause distinction, and return `.commandFailed` when a skip is a no-op.

**Exploration notes.**
- **Ruled out:** "the background mode is missing." `Punches3-Info.plist:4-6` declares `UIBackgroundModes: ["audio"]` and `.playback` is set at `AudioSessionService.swift:19` — a background-audio app keeps running.
- **Ruled out:** "iOS suspends the app so the commands do not arrive." With an active `.playback` session the process is not suspended; the command does arrive, there is simply no handler.
- **Ruled out:** "the handler is registered but the queue is empty." That would be a different symptom, and the same report would appear on **every** skip rather than *sometimes*.
- **Checked, and worth stating explicitly so nobody re-checks it:** the interruption observer does **not** share this failure path. `setupInterruptionObserver()` is a separate call at `audio_manager.swift:98`, outside the `do`, so a thrown `setActive` skips remote-command registration but leaves interruptions handled normally. [E14](#e14-an-interruption-leaves-state-that-reads-as-still-playing) therefore has an independent trigger — do not merge the two investigations.
- **To confirm:** log a line on entry to `setupRemoteTransportControls`, and log the session error with its domain and code. If the line is missing on the affected launches, the `try` threw. Then verify the `playCommand` inversion independently — it should reproduce 100% of the time and is the easier of the two to confirm.

---

## F — Theming & Settings

### F1 `appearanceMode` never reaches the SwiftUI environment

**High.**

`appearanceMode` is persisted, drives which preset list is shown, and decides which theme `applyActiveTheme()` loads (`View/setting_View.swift:1141-1142`) — but is never applied as a colour scheme. The only `preferredColorScheme` in the repository is a hardcoded `.dark` on the player (`View/audio_player_view.swift:31`). A user on a Dark device who picks a light theme gets light Punches surfaces with dark `Toggle`, `Slider`, `Menu`, keyboard and status bar.

**Fix:** `.preferredColorScheme(theme.appearanceMode == .dark ? .dark : .light)` at the app root.

**Exploration notes.**
- **Ruled out:** "the value is applied through `.preferredColorScheme` on the root." The player view hardcodes `.preferredColorScheme(.dark)`, which overrides whatever the theme manager holds.
- **Ruled out:** "the setting is applied somewhere else, like an asset catalog." The light/dark toggle only drives shader parameters and UI colours; it never reaches the SwiftUI environment.
- **To confirm:** there is no `.environment(\.colorScheme, …)` write anywhere in the project. Grep confirms it; no runtime check needed.
- **Note:** the app *looks* correct under both settings because the theme drives its own colours explicitly. That is why this has survived — the symptom is only visible to a user who switches the system appearance and expects a native response.

### F2 The tunnel effect does not compile

**High.**

See [G1](#g1-missing-grainoverlay-shader-and-bluenoise64-asset).

**Exploration notes.**
- **Ruled out:** "the tunnel shader file is missing." It exists; the defect is the Swift wrapper's call, which is recorded as [A4](#a4-grainoverlay-is-undefined-and-tunneleffect-is-mis-called). Same root cause, recorded from the settings side.
- **Ruled out:** "it is gated behind a quality tier and never built." It is in the live tunnel path and compiles whenever membership is repaired.
- **To confirm:** duplicate of A4 — one compiler diagnostic settles both. Do not spend separate time here.
- **Fix order note:** the "drop the call, then restore it" advice under [A4](#a4-grainoverlay-is-undefined-and-tunneleffect-is-mis-called) applies verbatim; this entry should be closed by the same change.

### F3 Water, tunnel and smoke are mutually exclusive by construction

**High.**

`AppBackground` draws `backgroundColor`, then water, then tunnel, then smoke, then fog. The middle three are **opaque full-screen fills**, not blend layers, so enabling two shows only the later one while the earlier still burns GPU. Settings presents four independent toggles with no warning, no mutual exclusion and no explanation. Only the `Mist` theme (water + fog) actually shows both, because fog is the only non-replacement layer.

**Fix:** radio-style exclusivity among the three, or make them blend.

**Exploration notes.**
- **Ruled out:** "the effects layer and composite." A single `switch` returns exactly one view. There is no path by which two background effects are both installed.
- **Ruled out:** "the user can enable all three and something breaks." The UI presents them as exclusive, so this is arguably working as designed — it is a naming and expectation problem rather than a code defect, which is why it is filed under theming rather than as a bug.
- **To confirm:** read the switch. If a product decision is that they should be combinable, the fix is a `ZStack` over the background; if not, the fix is to rename the control so "tunnel" does not read as a modifier of "water".
- **Ask before building.** This entry needs a product answer, not a code change.

### F4 The Low Power Mode override is invisible

**Medium.**

`effectiveQuality` forces `.low` for water, tunnel and smoke when Low Power Mode is on (`View/ShaderEffects.swift:91-93`, `:234-236`, `:324-326`), but the segmented picker still displays the user's stored tier. A user on Balanced sees "Balanced" and gets Low. The setting is not overwritten and correctly snaps back — the disclosure is what is wrong.

### F5 Water ignores its theme's background colour

**Medium.**

`WaterShaderView` fills its `Rectangle` with `theme.waterColor` (`ShaderEffects.swift:51`) and tints with it (`:56`), but `waterColor` is a hardcoded `let` `#2A7FAA` (`setting_View.swift:948`) — not `backgroundColor` and not the Water theme's `#020e1e`. Fog (`:119`), tunnel (`:179`) and smoke (`:287`) all correctly fill with `theme.backgroundColor`; water is the odd one out. Compounding it, the Settings subtitle at `setting_View.swift:1385` claims "Uses the current background colour".

### F6 Fog speed is applied twice

**Medium.**

`AppBackground` passes `time * theme.fogSpeed` to `FogShaderView` (`ShaderEffects.swift:389`) and `FogShaderView` multiplies by `fogSpeed` again internally, so the effective speed is squared. Water and smoke scale in Swift; tunnel scales inside the shader. Three different conventions, one of them wrong.

### F7 `Settings` is unreachable from two of three tabs

**Medium.**

The gear is only in the Songs tab's overflow menu (`View/content_view.swift:366-368`), and that menu is itself hidden while a multi-selection is active.

### F8 Adding a setting is six unverified edits

**Medium.**

`ThemeKey` (`:851-887`), the `@Published` property, the `init` load, the `ThemePreset` struct, **all 35 `AppTheme` cases**, and a control. Missing the load or apply step produces a value that saves but never loads, with no diagnostic. The riskiest part is the 35 cases.

### F9 `waterColor` is a non-`@Published` `let`

**Low.**

`setting_View.swift:948`. No view observing `ThemeManager` can invalidate from it, and it is not persisted — so the water tint is identical in every theme regardless of the preset.

### F10 Hardcoded colour in the preview badge

**Low.**

`setting_View.swift:1211` and `:1214` use `Color(hex: "#2dd4bf")` for the Water badge, which ignores the theme and disagrees with `waterColor`'s `#2A7FAA`. Every other badge is theme-derived.

### F11 No reset-to-defaults

**Low.**

The only way back to stock is selecting a preset, which does not restore manually-tuned slider values.

### F12 Inconsistent slider labels

**Low.**

"Speed" is formatted `%.1fx` on all three effects, implying a multiplier it is not (`setting_View.swift:1409`, `:1461`, `:1558`). The fog "Density" slider is bound to `fogIntensity` (`:1508`).

### F13 `fogColor`, `fogSpeed`, `tunnelColor` have no controls

**Low.**

All three are `@Published`, persisted, and set by every preset — reachable **only** by choosing a preset, never individually.

---

## G — Analysis, Rendering & Dependencies

### G1 Missing `grainOverlay` shader and `BlueNoise64` asset

**Critical.**

Three defects in ~30 lines of `View/ShaderEffects.swift`:

1. **`ShaderLibrary.grainOverlay` does not exist.** Called at `:209-214`; defined in **no** `.metal` file in the repository. `ShaderLibrary` only exposes `[[ stitchable ]]` functions, so this is a **compile error**, not a blank render.
2. **`BlueNoise64` cannot resolve.** The header comment at `:158-159` admits it "requires 'BlueNoise64' to be added to Assets.xcassets". It was never added — `Assets.xcassets/` has only `AccentColor.colorset` and `AppIcon.appiconset`. The PNG exists loose at `View/BlueNoise64.png`, but that is not sufficient: it is not in the catalogue, **and** it is in the `View` folder's `membershipExceptions` (`project.pbxproj:120`) so it is excluded from the target and never copied into the bundle.
3. **`tunnelEffect` is mis-called.** `ShaderEffects.swift:181-191` passes **8** explicit arguments; `tunnelEffect` declares **7**. By positional binding `.float(Float(quality.foldIterations))` would be read as `qualityFolds` while `.image(...)` fails to bind. `TunnelShader.metal` has no `[[texture(n)]]` attribute anywhere — the intended `texture2d` parameter was never added.

**Fix:** move the PNG into `Assets.xcassets`, add a `texture2d<half, access::sample>` parameter to `tunnelEffect` in declaration and call order, and write `grainOverlay` — or, to unblock the build first, drop the `grainOverlay` `colorEffect` at `:209-214` and the 8th argument.

**Exploration notes.**
- **Ruled out:** "`BlueNoise64.png` is missing from the repository." It exists, at `View/BlueNoise64.png`.
- **Ruled out:** "it is in the asset catalog." It is not — it is a loose file in `View/`, it is absent from `Assets.xcassets`, and the target membership exception excludes the whole `View/` folder. So it is in the repository and not in the app.
- **Ruled out:** "the `grainOverlay` call is dead code." It is on the live tunnel path.
- **Two different failure modes, one entry.** The missing shader function is a **compile error**. The missing asset is a **runtime nil** — `Image("BlueNoise64")` compiles and returns nothing, so it will only surface visually once the build is fixed. Expect to find the second problem only after fixing the first.
- **To confirm:** after the build is repaired, set the Grain slider to a non-zero value and look for a visible change in the tunnel background. There will be none.

### G2 Unsynchronised `Q3Renderer` state

**High.**

`Q3MetalRenderer`'s `bands`, `peaks`, `enhancedMode` and `inspectFraction` (`AudioMeters/Q3SpectrumView.swift:153-156`) are plain `var`s written on the main thread by `updateUIView` and read on the Metal render thread by `draw(in:)`. `bands` is reassigned wholesale every 60 Hz tick (`AudioMeters/UnifiedAudioAnalyser.swift:679-683`). Concurrent array mutation and read is undefined behaviour, not "a frame of tearing". Currently latent because both threads happen to be the same; it becomes a real race the moment the Q3 update moves off main.

`goniometerView` solves this correctly with `os_unfair_lock` (`:263`, `:311-316`, `:325-330`) — the pattern already exists 200 lines away.

**Fix:** copy the model to the Metal thread in one `os_unfair_lock`-guarded assignment, exactly as the goniometer does.

**Exploration notes.**
- **Ruled out:** "`updateUIView` and `draw(in:)` already run on different threads." They currently coincide on the main thread, which is precisely why this is **latent** rather than an observed crash. The comment at `Q3SpectrumView.swift:152` even states the intent ("written by the SwiftUI layer (main thread) and read each draw call") — the code does not yet match the comment.
- **Ruled out:** "Metal serialises the reads." The render thread is separate from main; the unsynchronised access is between the SwiftUI layer and the renderer.
- **To confirm:** move the Q3 update off the main actor and run under Thread Sanitizer. Until then, treat this as a landmine for whoever does that work rather than a live bug.
- **Fix shape:** either confine `Q3MetalRenderer` to one queue, or publish immutable snapshots. Do not add a lock on the render path without measuring — see [G4](#g4-three-ffts-per-frame-with-no-consumer) for the frame budget already being spent here.
- **Dependency:** fixing this correctly depends on [G4](#g4-three-ffts-per-frame-with-no-consumer) being addressed first, otherwise the lock protects an expensive path.

### G3 Three incompatible frequency↔band conventions

**High.**

| # | Location | Band 0 | Band 127 | For |
|---|---|---|---|---|
| 1 | `UnifiedAudioAnalyser.swift:636-640`, `+Testing.swift:57-61` | [20, 21.1) Hz | [20 000, 21 000) Hz | FFT bin **edges** |
| 2 | `Tests/FrequencyAllignmenttest.swift:16-20` | 20 Hz | 20 000 Hz | display **centres** |
| 3 | `Tests/Q3analysertests.swift:25-32` | 20 Hz | 20 000 Hz | test expectations |

Convention 1 is **half a band** off 2 and 3 — about a 4.5 % frequency error at 1 kHz. Its top band sits above the audible range, and `Q3MetalRenderer` independently maps its axis to 20 Hz–20 kHz (`Q3SpectrumView.swift:302-304`), so the rightmost visible band is effectively dead. There is a **fourth** copy in `freqToX`/`bandToX` (`:290-304`).

**Fix:** adopt `FrequencyMapper` as the single source, move it out of `Tests/` into the app target, and slice bins from its `bandFrequencyRange(index:totalBands:)`.

**Exploration notes.**
- **Ruled out:** "one of the three conventions is dead code." All three are live, in different consumers: the standard analyser path, the 32-band `processQ3FFT` path, and the renderer's own axis mapping. Each is internally consistent; they disagree with each other.
- **Ruled out:** "it is only an off-by-one and is visually irrelevant." Convention 1 is half a band off the others, roughly a 4.5% frequency error at 1 kHz, and its top band sits above the audible range — so the rightmost visible band is effectively dead.
- **To confirm:** `Q3analysertests.swift` is the existing arbiter and it is not compiled — see [A2](#a2-both-test-targets-are-empty). Restoring test membership is the cheapest way to pin the correct convention before unifying, and it is why A2 sits in Phase 1 of the fix order.
- **Recommendation:** do not "fix" this by editing a band count. Pick one convention deliberately, state it, and have the test assert against it.

### G4 Three FFTs per frame with no consumer

**High.**

`updateSpectrum` (`:421+`) runs an 8192-point FFT three times per tick: the 32-band path, the A-weighted path, and `processQ3FFT` (`:436`, `:589`). Only the Q3 result has a live consumer — the 32 bands are dead ([D8](#d8-the-32-band-analyser-output-is-unused)) and 16 of 18 `@Published` properties have no reader ([07](07-meters-and-hud.md)). All of it runs on the main thread at 60 Hz ([E13](#e13-dsp-shaders-and-layout-share-one-budget)).

**Fix:** delete the 32-band path and fold A-weighting into the Q3 pass unless the A-weighted view is coming back.

**Exploration notes.**
- **Ruled out:** "the extra FFTs are cached between frames." They are recomputed on every tick; there is no memoisation anywhere on the path.
- **Ruled out:** "only one of the three is on the render path." The 32-band analyser output has no consumer at all (see [D8](#d8-the-32-band-analyser-output-is-unused)), so a whole FFT per frame is spent producing a value nobody reads.
- **To confirm:** the 60 Hz `Timer` in the analyser is the driver. Count FFT invocations per tick and multiply by 60. Removing the unused one is a deletion, not an optimisation, and is the cheapest win in this section.
- **Interaction:** this is the frame budget that [G2](#g2-unsynchronised-q3renderer-state) would have to protect. Fix this before adding synchronisation there, or the lock is paying to protect work that should not happen.
- **Note:** [E13](#e13-dsp-shaders-and-layout-share-one-budget) records the broader version of the same problem — DSP, shaders and layout all drawing from one budget with nothing yielding.

### G5 AudioKit dependency is vestigial

**Medium.**

One file in the entire repository imports it: `AudioMeters/UnifiedAudioAnalyser.swift:2`. The engine is hand-rolled `AVAudioEngine` / `AVAudioPlayerNode` / `AVAudioUnitTimePitch` (`AudioEngines/AppleAudioEngine.swift`, `Services/AudioEngineService.swift`). AudioKit pulls in `audiokitui` and `controls` behind it, and it is linked into the app's Frameworks phase (`:187-195`) even though its only consumer is excluded from the target ([A1](#a1-the-target-compiles-7-of-30-swift-files)). The root `README.md:45` says the graph is "built on `AVAudioEngine`" — correct — but implies AudioKit is central; it is not.

**Fix:** remove the package, or stop linking it into the app target.

### G6 `GonioVertex` stride comment is wrong

**Low.**

`goniometerView.swift:209-210` says "float2 position + float4 color + float age = 36 bytes". `float4` is 16-byte aligned, so both sides place `color` at offset 16 and pad the struct to a multiple of 16 — `MemoryLayout<GonioVertex>.stride` is **48**. The code is correct; the comment is not. `Q3Vertex` is 32 for the same reason. Add a `MemoryLayout` assertion to a test.

### G7 `FrequencyMapper` is referenced by nothing

**Medium.**

`Tests/FrequencyAllignmenttest.swift:6-7` instructs that it be used "in BOTH UnifiedAudioAnalyser and Q3MetalRenderer". Neither imports it, and there is no `Q3MetalRenderer` reference anywhere in the project. Aspirational documentation in a file that is not a test and does not build ([D7](#d7-frequencyallignmenttestswift-is-not-a-test), [G3](#g3-three-incompatible-frequencyband-conventions)).

### G8 The analysis runs in every visualisation mode

**Medium.**

Switching to `.Artwork` does not detach the tap, stop the 60 Hz timer, or free the ring buffers — `saveVisualisationMode()` persists the choice but nothing else reacts to it (`View/content_view.swift:345`). The DSP keeps running behind a full-screen photo.

**Fix:** on mode change to `.Artwork`, invalidate the timer and remove the tap; re-attach on the way back.

---

## Recommended fix order

**Phase 1 — make it build.** Nothing else is verifiable until this is done.

1. [A1](#a1-the-target-compiles-7-of-30-swift-files) target membership
2. [G1](#g1-missing-grainoverlay-shader-and-bluenoise64-asset) — drop the `grainOverlay` call to unblock, then restore it
3. [E2](#e2-rt-closure-calls-a-main-actor-method) will now fail to compile; fix with [E1](#e1-rt-thread-allocates-19-mbs)
4. [A3](#a3-app-group-entitlement-is-empty) entitlements
5. [A2](#a2-both-test-targets-are-empty) test membership, so [G3](#g3-three-incompatible-frequencyband-conventions) can be verified against `Q3analysertests.swift`

**Phase 2 — stop losing user data.** All are independent of the build and all can corrupt a library.

6. [C12](#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) **first** — the directory must become the source of truth before anything else in this phase is safe to test
7. [C1](#c1-master-playlist-recovery-destroys-every-user-playlist) · [C2](#c2-cleanuporphanedfiles-deletes-untracked-files) · [C3](#c3-taskdetached-races-saveplaylists-on-the-same-key) · [C5](#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop)
8. [B7](#b7-processpendingimports-deletes-the-whole-directory) · [B6](#b6-unsynchronised-fileurlsappend-in-the-extension)

**Phase 3 — make the audio thread correct.**

9. [E1](#e1-rt-thread-allocates-19-mbs) + [E2](#e2-rt-closure-calls-a-main-actor-method) together
10. [E4](#e4-the-generation-cancellation-gate-is-never-wired-up) · [E3](#e3-mach_timebase_info-on-every-tap-callback) · [E5](#e5-withcheckedthrowingcontinuation-can-trap)

**Phase 4 — make the features real.**

11. [D2](#d2-tempo-control-is-commented-out) (one line) · [D1](#d1-loop-is-honoured-only-at-the-end-of-the-queue) · [D4](#d4-no-volume-control) · [C6](#c6-tempo-pitch-and-loop-are-not-persisted)
12. [E16](#e16-remote-commands-are-registered-inside-the-session-setup-do-block) (move two lines out of a `do` block) · [E14](#e14-an-interruption-leaves-state-that-reads-as-still-playing) (update now-playing info in two branches)
13. [E15](#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song) — pick one advance mechanism, clear `onPlaybackFinished` on stop
14. [B4](#b4-multi-file-import-silently-takes-the-first-file) · [B5](#b5-import-errors-are-completely-invisible) · [B9](#b9-playlist-detail-share-hands-out-the-live-file)
15. [F1](#f1-appearancemode-never-reaches-the-swiftui-environment) · [F3](#f3-water-tunnel-and-smoke-are-mutually-exclusive-by-construction)
16. [D14](#d14-no-metadata-is-read-anywhere-the-title-is-the-filename) — **only after C12 lands**, or the schema change will trigger the library wipe

**Phase 5 — correctness and cost.**

17. [C13](#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list) (one line: use the sorted array) · [C14](#c14-manual-sort-order-is-silently-discarded) (decide whether manual order means anything)
18. [G2](#g2-unsynchronised-q3renderer-state) · [G3](#g3-three-incompatible-frequencyband-conventions) · [G4](#g4-three-ffts-per-frame-with-no-consumer)
19. [E12](#e12-goniometer-iir-filtering-runs-on-the-main-thread-at-ui-rate) · [D12](#d12-artwork-decoding-is-not-cached-at-the-call-site) · [E8](#e8-audio-setup-is-sequenced-with-sleeps)

**Phase 6 — cleanup.**

20. Delete [D5](#d5-spectrumview-has-zero-call-sites), [D8](#d8-the-32-band-analyser-output-is-unused), [D9](#d9-commented-out-visualisation-modes), [B11](#b11-contentviewshareurl-is-dead-code), [A8](#a8-workspace-file-is-copied-into-the-app-bundle), the dead `@State volume`, the `AVAudioPlayerDelegate` conformance on `AudioManager` (`audio_manager.swift:270-278`, unreachable — see [E15](#e15-two-racing-mechanisms-advance-the-queue-and-a-stale-completion-can-skip-a-just-started-song)), and the `#if DEBUG` timing wrapper's per-callback syscall.
21. Fix [D10](#d10-the-root-readmemd-requirements-are-wrong-by-a-decade) — the root README actively misleads anyone trying to build this.

---

## See also

- [01](01-getting-started-and-usage.md) — what works and what does not, from a user's perspective
- [03](03-project-structure-and-build.md) — the build configuration behind section A
- [05](05-signal-analysis.md) — the DSP behind section G
- [08](08-playlists-and-library.md) — the data model behind section C
- [09](09-file-import-and-sharing.md) — the import/share paths behind section B
- [13](13-concurrency-and-threading.md) — the full threading analysis behind section E
