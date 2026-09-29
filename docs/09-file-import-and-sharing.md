# 09 — File Import & Sharing

> Every way a file gets into Punches and every way a file gets back out. Two import paths (document picker, share extension), one export path, one artwork path, and the app-group contract that connects them — which is currently broken end to end.
> Companion: [08-playlists-and-library.md](08-playlists-and-library.md) (what happens to the file afterwards), [03-project-structure-and-build.md](03-project-structure-and-build.md) (target/entitlement wiring), [12-persistence-and-keys.md](12-persistence-and-keys.md) (all keys).

---

## 1. The two doors

```
┌─ IN ────────────────────────────────────────────────────────────────┐
│                                                                  │
│  Files app / iTunes                                             │
│       │ UIDocumentPickerViewController (.audio, multi-select)     │
│       ▼                                                          │
│  DocumentPicker (content_view.swift:1565)                         │
│       │ for url in urls { audioManager.importAudioFile(from:) }   │
│       ▼                                                          │
│  AudioImportService.importAudioFile(from:)   ← security-scoped,  │
│       │                                        NSFileCoordinator│
│       ▼                                                           │
│  AudioManager.fileDirectory / <uniqueName>                        │
│                                                                  │
│  Share sheet (from Safari/Files/Mail)                            │
│       │ NSExtensionItem.attachments → UTType.audio               │
│       ▼                                                          │
│  ShareViewController (AudioShare/)  ──copies──▶  app-group        │
│                                                     PendingImports/│
│                                                     + pendingImportFiles│
│       │ onOpenURL punches://openAndPlay, or scenePhase → .active  │
│       ▼                                                           │
│  AudioImportService.processPendingImports()  ──move──▶ fileDirectory│
└──────────────────────────────────────────────────────────────────┘

┌─ OUT ──────────────────────────────────────────────────────────────┐
│  urlForSharing(_:) → ShareSheet(activityItems:)                    │
│  setArtwork(_:for:) ← PhotoPicker                                 │
└──────────────────────────────────────────────────────────────────┘
```

> **⚠️ The share-extension door does not work in the current project state.** `ShareViewController.swift` is not in any target (only `Punches3`, `Punches3Tests`, `Punches3UITests` exist), `punches://openAndPlay` is not in `CFBundleURLTypes` (`Punches3-Info.plist` contains only `UIBackgroundModes`), and `Punches3.entitlements` is an **empty `<dict/>`** despite being wired via `CODE_SIGN_ENTITLEMENTS` (`project.pbxproj:559, 598`) — so the app has no app-group entitlement, `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil`, and `fileDirectory` silently falls back to `Documents`. The correct entitlements exist in two unused files: `AudioShare/AudioShare.entitlements` and `silly_speed_ios.entitlements`, both declaring `group.Cam.punches-ios`. See [14-known-issues.md](14-known-issues.md).

---

## 2. `SharedConstants`

```swift
// SharedConstants.swift:3-7
struct SharedConstants {
    static let appGroupIdentifier = "group.Cam.punches-ios"
    static let pendingFilesKey    = "pendingImportFiles"
    static let openAndPlayScheme  = "punches://openAndPlay"
}
```

| Constant | Consumer(s) |
|---|---|
| `appGroupIdentifier` | `AudioManager.fileDirectory` (`audio_manager.swift:48`), `processPendingImports` (`AudioImportService.swift:112-113`), `ShareViewController` (`:6, 131, 158`) |
| `pendingFilesKey` | `processPendingImports` (`:114`), `saveFilesToSharedContainer` (`ShareViewController.swift:159-160`) |
| `openAndPlayScheme` | `ShareViewController.openMainApp` (`:166`) |

Note the **bundle ID is `Cam.Punches3`** but the **app group is `group.Cam.punches-ios`** — different casing, different word order, and the group predates the current bundle ID. The group is what Apple ties the entitlements to; if the App ID in the developer portal doesn't match, provisioning fails.

`struct SharedConstants` has only static members and no `init`, so it is a namespace, not a type you instantiate. `AppStorage` is not used anywhere in the project; the pending-file list is a plain `UserDefaults(suiteName:)` array of **filenames** (not URLs) — see §5.

---

## 3. Path A — document picker

### 3.1 The picker

```swift
// View/content_view.swift:1571-1574
let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
picker.allowsMultipleSelection = true
```

Presented from `applySheets` (`:613-615`):

```swift
.sheet(isPresented: showingFilePicker) { DocumentPicker(audioManager: audioManager) }
```

`showingFilePicker` is set by the "Add Songs" toolbar button (`View/content_view.swift:314-316`) and by the Songs-tab empty state (`EmptySongStateView`).

`Coordinator.documentPicker(_:didPickDocumentsAt:)` (`:1586-1592`) fires **one import per URL, on the same turn, then dismisses**:

```swift
for url in urls { parent.audioManager.importAudioFile(from: url) }
parent.dismiss()
```

There is **no serialisation** — N concurrent `Task`s, each doing a `NSFileCoordinator` copy, an `AVURLAsset` duration load, and a `saveAudioFiles()`. Selecting 50 files means 50 uncoordinated `UserDefaults` writes racing each other; the last writer wins and the library can end up with a subset of the import. See §4.3.

`updateUIViewController` is empty (`:1578-1581`) and `documentPickerWasCancelled` also dismisses (`:1593-1595`) — cancel is handled correctly.

### 3.2 `importAudioFile(from:)` — the full sequence

`Services/AudioImportService.swift:11-109`. Everything is inside an unstructured `Task` (`:15`), i.e. on the cooperative pool, **not** on main.

| Step | Lines | Detail |
|---|---|---|
| reset state | `:12-13` | `manager.isImporting = true`, `manager.importError = nil` — **both on the calling thread**, which is main |
| security scope | `:19-21` | `guard url.startAccessingSecurityScopedResource() else { throw … "No permission to access this file" }` |
| scope release | `:23-26` | `defer { url.stopAccessingSecurityScopedResource() }` — correct: scoped for the whole Task |
| unique name | `:29` | `libraryService.generateUniqueFileName(for:)` — see [08](08-playlists-and-library.md#44-generateuniquefilenamefor-and-renameaudiofile_to) |
| destination | `:30` | `AudioManager.fileDirectory.appendingPathComponent(uniqueFileName)` |
| coordinated copy | `:36-51` | `NSFileCoordinator.coordinate(readingItemAt:options:[.withoutChanges])` wrapped in `withCheckedThrowingContinuation` |
| duration | `:55-57` | `AVURLAsset(url:).load(.duration)` — the modern async `load(_:)` API |
| validation | `:59-62` | rejects `<= 0`, `NaN`, `isInfinite`; **deletes the copied file** and throws "Invalid or corrupted audio file" |
| model | `:64` | `AudioFile(fileName:audioDuration:)` — the 3-arg init, so `title` is the extension-stripped name |
| commit on main | `:66-83` | `await MainActor.run { … }` |

The commit block (`:66-83`) does five things, in order:

```swift
self.manager.audioFiles.append(audioFile)                       // :67
self.manager.libraryService.saveAudioFiles()                   // :68
if let masterID = …, let index = … {                            // :70-71
    self.manager.playlists[index].audioFileIDs.append(audioFile.id)   // :72
    self.manager.displayedSongs = self.manager.sortedAudioFiles      // :73  ← destroys manual order
    self.manager.playlistService.savePlaylists()                     // :74
}
if self.manager.playbackQueue.count == self.manager.audioFiles.count - 1 {   // :77
    self.manager.playbackQueue = self.manager.sortedAudioFiles     // :78
}
self.manager.isImporting = false                                 // :82
```

Three things to know:

- **The `audioFiles` save at `:68` happens before the playlist update at `:72`**, so `savePlaylists()` at `:74` is the second of two writes. Both go to `UserDefaults`. There is no transaction; a crash between them leaves a file in `audioFiles` whose ID is in no playlist — and `sortedAudioFiles` would then omit it from the Songs tab, making an imported song invisible until the next import/delete rebuilds `displayedSongs`.
- **`displayedSongs = sortedAudioFiles` (`:73`) re-sorts the whole Songs list by `dateAdded` descending** — the manual order the user built with drag-to-reorder is lost on every single import. This is the bug described in [08](08-playlists-and-library.md#33-four-orderings-of-the-same-data).
- **The `playbackQueue` refresh guard at `:77` is a heuristic**: "if the queue is exactly one shorter than the library, it's probably the un-imported default, so refresh it." It fires on the *first* import of a session and then stops matching, so once the user has been playing from a playlist, importing a song leaves `playbackQueue` stale.

### 3.3 Error mapping (`:85-107`)

Errors are caught and, on main, mapped to `manager.importError`:

| Condition | `importError` |
|---|---|
| `NSCocoaErrorDomain` / `NSFileReadNoPermissionError` | "No permission to read this file" |
| `NSCocoaErrorDomain` / `NSFileReadNoSuchFileError` | "File not found or still downloading" |
| `NSCocoaErrorDomain` / `NSFileReadUnknownError` | "Cannot read this file type" |
| any other `NSCocoaErrorDomain` code | "Failed to import: \(error.localizedDescription)" |
| non-Cocoa domain | `error.localizedDescription` |

> **⚠️ Import errors are completely invisible to the user.** `manager.isImporting` and `manager.importError` (`audio_manager.swift:22-23`) are `@Published`, but **no view in the project ever reads either one** (verified: the only occurrences are the two declarations and the writes in `AudioImportService`). A failed import prints to the console and is otherwise a no-op. There is no spinner, no toast, no alert. If you import a DRM-protected file or a codec iOS can't parse, nothing happens at all.

> **`FileProvider` URLs (iCloud Drive, not-yet-downloaded files) are not handled.** The "File not found or still downloading" message acknowledges the case, but nothing calls `startDownloadingUbiquitousItem` or waits for it. `NSFileCoordinator` with `.withoutChanges` does not force materialisation. Any file not already local fails.

---

## 4. Path B — the share extension

### 4.1 The UI

`AudioShare/ShareViewController.swift` is a `UIViewController` with a hand-built `UIStackView` (`:15-19`): a 24 pt bold "Import to **Punches**" title, then three buttons.

| Button | Config | Action |
|---|---|---|
| **Add to Library** | `.filled()`, `systemBlue`, medium corners, 16/32 insets (`:27-33`) | `processFiles(shouldOpenApp: false)` (`:68-70`) |
| **Add and Play** | `.filled()`, `systemGreen`, same metrics (`:37-43`) | `processFiles(shouldOpenApp: true)` (`:72-74`) |
| **Cancel** | plain `setTitle`, 16 pt (`:46-49`) | `extensionContext?.completeRequest(returningItems: nil)` (`:76-78`) |

`preferredContentSize = CGSize(width: 100, height: 160)` (`:11`) — the 100 pt width is narrower than any iPhone screen, so iOS will widen it. The layout is fully programmatic with `stackView` centred and 40 pt leading/trailing margins (`:58-65`).

**No `NSExtensionContext` `completeRequest` is called on "Add to Library" until after the copy** (`:125`) — good, the sheet stays up while the work happens. `cancel` and the "no audio attachments" path both complete with `nil` (`:82, 116, 125`).

### 4.2 `processFiles` — the data race

```swift
// ShareViewController.swift:80-128
var fileURLs: [URL] = []
let group = DispatchGroup()
for item in extensionItems {
    for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.audio.identifier, options: nil) { item, error in
            defer { group.leave() }
            if let error = error { print("Error loading item: \(error)"); return }
            if let url = item as? URL { fileURLs.append(url) }
        }
    }
}
group.notify(queue: .main) { … self.saveFilesToSharedContainer(fileURLs) … }
```

> **⚠️ `fileURLs.append` happens on N arbitrary provider queues with no lock.** `loadItem(forTypeIdentifier:options:completionHandler:)` invokes its completion on an unspecified queue, and `NSItemProvider` documents that it may be a **private concurrent queue**. `DispatchGroup` correctly waits for all of them before `notify`, but the *appends themselves* are an unsynchronised mutation of a shared `Array`. With 2+ attachments this is a data race — lost entries, or a corrupted buffer. It is masked in practice because the extension is usually given one attachment at a time.
>
> Fix: `group.enter()` around a serial `NSLock`, or collect into a per-`provider` array keyed by index, or use an `actor`.

Three further gaps in the same function:

- **Only `UTType.audio` is accepted** (`:93`). A share from a file manager that reports the type as `public.mp3` or `public.aifc` without conforming to `public.audio` is silently skipped, and the extension then shows "Add to Library" doing nothing.
- **`item as? URL` is the only success path** (`:104`). `NSItemProvider` may hand back `Data`, a `UIImage`, or an `NSSecureCoding` wrapper. If it returns `Data`, the file is dropped with no error.
- **The copy is `FileManager.copyItem`, not a move** (`:150` in `saveFilesToSharedContainer`), so `processPendingImports` has to `moveItem` it later. Two writes of every shared file. Using `NSItemProvider`'s `loadFileRepresentation(forTypeIdentifier:)` with a `moveItem` would halve the I/O.

### 4.3 `saveFilesToSharedContainer` — the hand-off

`AudioShare/ShareViewController.swift:130-163`:

```swift
let sharedDirectory = groupURL.appendingPathComponent("PendingImports", isDirectory: true)
try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)   // :137

for url in urls {
    let fileName = url.lastPathComponent
    let destinationURL = sharedDirectory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try? FileManager.default.removeItem(at: destinationURL)      // :147
    }
    try FileManager.default.copyItem(at: url, to: destinationURL)    // :150
    savedURLs.append(fileName)
}

groupDefaults.set(existing + savedURLs, forKey: SharedConstants.pendingFilesKey)   // :160
groupDefaults.synchronize()                                                          // :161
```

| Detail | Consequence |
|---|---|
| Only the **filename** is stored (`:151`, `:160`), not a URL or a bookmark | the handoff is only valid inside the shared container, which is fine — but it means `PendingImports/` **must not be cleared by anything else** |
| Existing same-named file is deleted first (`:146-148`) | **overwrites a previous pending import with the same name**, and then `existing + savedURLs` records the filename **twice** (once from the old array, once from `savedURLs`) |
| Duplicates in the array are not deduped (`:160`) | `processPendingImports` will `moveItem` the same file twice; the second `move` fails, is caught at `:152-154`, printed, and skipped. Idempotent by accident. |
| `groupDefaults.synchronize()` (`:161`) | deprecated since iOS 12 and a no-op; harmless but signals the author expected weaker durability |
| `try?` on the directory create (`:137`) | if the group container is unavailable (which it is today — §1), the copies all fail and the extension reports success |
| `print` only on per-file error (`:154`) | a partial import is indistinguishable from a complete one |

The `if fileURLs.isEmpty { cancel() }` guard (`:115-118`) is the only user-visible failure path in the whole extension.

### 4.4 `openMainApp` — the URL scheme

```swift
// AudioShare/ShareViewController.swift:165-180
guard let url = URL(string: SharedConstants.openAndPlayScheme) else { return }
var responder: UIResponder? = self
while responder != nil {
    if let application = responder as? UIApplication {
        application.open(url, options: [:]) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        return
    }
    responder = responder?.next
}
extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
```

The `UIResponder.next` walk is the standard App Extension idiom for reaching the host `UIApplication` — and it is **explicitly forbidden** for extensions shipping on the App Store ("Extensions may not access APIs that are unavailable to app extensions"). It works in development; a review rejection is the realistic outcome. The supported replacement is `NSExtensionContext.open(_:completionHandler:)`.

The `open` **completion handler is ignored** (`:171`) — the extension completes the request whether or not the URL actually opened. So even if the scheme were registered, "Add and Play" would dismiss regardless.

> **`Punches3-Info.plist` does not register the scheme.** The file's entire contents are:
> ```xml
> <key>UIBackgroundModes</key><array><string>audio</string></array>
> ```
> No `CFBundleURLTypes`, so `punches://openAndPlay` is unroutable and `onOpenURL` in `silly_speed.swift:16-22` can never fire. Note the app *does* generate an Info.plist (`GENERATE_INFOPLIST_FILE = YES` at `project.pbxproj:564, 603` **alongside** `INFOPLIST_FILE = "Punches3-Info.plist"`), and the generated keys cover category, photo-library usage, scene manifest, and orientations — but not URL types. Adding `INFOPLIST_KEY_CFBundleURLTypes_…` or the key in the plist is required.

---

## 5. `processPendingImports` — the consumer

`Services/AudioImportService.swift:111-172`, `async`, `shouldAutoPlay: Bool = false`. Called from two places:

| Call site | Trigger |
|---|---|
| `audio_manager.swift:76-80` | `Task { … await importService.processPendingImports(); cleanupOrphanedFiles() }` — once, in `init` |
| `silly_speed.swift:16-22` | `onOpenURL` matching `punches` / `openAndPlay` → `processPendingImports(shouldAutoPlay: true)` |
| `silly_speed.swift:23-29` | `onChange(of: scenePhase)` → `.active` → `processPendingImports()` |

Sequence:

```swift
guard let groupURL = …containerURL(…),
      let groupDefaults = UserDefaults(suiteName: …),
      let pendingFiles = groupDefaults.stringArray(forKey: pendingFilesKey),
      !pendingFiles.isEmpty else { return }                             // :112-117
```

— **this guard is what makes the whole path silently no-op today**, because `groupURL` is `nil` without the entitlement.

Then, per filename (`:122-155`):

1. `guard fileExists(sourceURL) else { continue }` (`:125`) — a vanished pending file is skipped silently.
2. `generateUniqueFileName` → destination in `fileDirectory` (`:127-128`).
3. `FileManager.moveItem(at:to:)` (`:131`) — note `move`, unlike the extension's `copy`.
4. `AVURLAsset(url: destinationURL)` + `await asset.load(.duration)` (`:133-134`) — the **non-optional** `options: nil` form, differing from Path A's `AVURLAsset(url:options:)`.
5. same `> 0 && !NaN && !isInfinite` validation, deleting the moved file and `continue`-ing on failure (`:138-141`) — note it does **not** restore the file to `PendingImports/`, so the content is lost.
6. `AudioFile(fileName:audioDuration:)` + `audioFiles.append` + `importedFiles.append` (`:142-144`).
7. append the id to the master playlist (`:146-149`) — **no `displayedSongs` update here**; it's batched below.

After the loop (`:157-171`):

```swift
if !importedFiles.isEmpty {
    saveAudioFiles(); savePlaylists()                                   // :158-159
    displayedSongs = sortedAudioFiles                                   // :160
    playbackQueue  = sortedAudioFiles                                   // :161  ← unconditional
    if shouldAutoPlay, let firstFile = importedFiles.first {
        manager.play(audioFile: firstFile, context: manager.sortedAudioFiles, fromSongsTab: true)   // :163-165
    }
}
groupDefaults.removeObject(forKey: pendingFilesKey)                     // :168
groupDefaults.synchronize()                                             // :169
try? FileManager.default.removeItem(at: pendingDirectory)                // :171
```

`playbackQueue` is overwritten **unconditionally** at `:161` (unlike Path A's heuristic), so a share-import clobbers a user's playlist-derived queue.

> **⚠️ `removeItem(at: pendingDirectory)` at `:171` deletes the whole directory, not the files that were imported.** Any filename in `pendingFiles` that failed at step 1 or 5 — and any file dropped from the array by the app-group copy failure — is deleted along with the rest. There is no per-file cleanup, and the array is cleared at `:168` *before* the directory removal, so a crash in between leaves orphaned bytes that `cleanupOrphanedFiles` will not see (it only scans `fileDirectory`, not `PendingImports/`). A crash between `:168` and `:171` therefore leaks the directory permanently.

> **`processPendingImports` has no reentrancy guard and no actor.** It is `async` and mutates `manager.audioFiles` (`:143`) and `manager.playlists` (`:148`) **directly, with no `MainActor` hop** — unlike Path A which wraps its commit in `await MainActor.run`. It is called from `AudioManager.init`'s `Task` (`audio_manager.swift:76`) *before* `displayedSongs`/`playbackQueue` are assigned (`:82-83`), and concurrently reachable from `onOpenURL` and `onChange(scenePhase:)`. Three concurrent executions will interleave their `append`s and their `saveAudioFiles()` calls, and the non-isolated `audioFiles` mutation is exactly the Swift-concurrency violation the rest of the file carefully avoids. See [13-concurrency-and-threading.md](13-concurrency-and-threading.md).

---

## 6. Path C — export

### 6.1 `urlForSharing`

```swift
// AudioLibraryService.swift:125-127
func urlForSharing(_ audioFile: AudioFile) -> URL? { audioFile.fileURL }
```

Returns non-optional in practice but is typed `URL?`, so every call site unwraps. Because `fileURL` is `fileDirectory.appendingPathComponent(fileName)`, the shared URL points into the **app's own container**, not a security-scoped resource — so `UIActivityViewController` can hand it to the Files app, Mail, AirDrop, and other extensions without any additional entitlement. (The app-group/`Documents` question in §1 applies: today the file is in the app's `Documents` directory, which the Files app exposes only if `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` are set — **neither is in `Punches3-Info.plist`**, so the receiving app gets a copy via the activity controller's own sandbox handling, not direct container access.)

### 6.2 `ShareSheet`

```swift
// View/content_view.swift:1499-1511
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
```

There are **three** share-sheet presentations, and **only two of them can ever appear**:

| # | Site | `activityItems` | Live? |
|---|---|---|---|
| 1 | `View/content_view.swift:616-620` (inside `applySheets`) | `if let url = shareURL.wrappedValue { [url] }` | **no — dead** |
| 2 | `View/content_view.swift:860-870` (`SongsListView`) | `shareURLs` — **temp copies** | yes |
| 3 | `PlaylisList_view.swift:151-153` (`PlaylistDetailView`) | `shareURLs` — **real container URLs** | yes |

> **Presentation 1 is unreachable.** `@State private var shareURL: URL?` (`View/content_view.swift:22`) is threaded into `applySheets` (`:76`, `:608`, `:617`) and read at `:617` — but **nothing in the project ever assigns it.** Every real share path uses the plural `shareURLs`. So `ContentView.applySheets` contains a share sheet that can never present. Delete the `shareURL` state, the parameter, and the sheet.

The two live paths are **not equivalent**, and the difference is the important part:

| | Songs tab (`:1340`) | Playlist detail (`PlaylisList_view.swift:291-296`) |
|---|---|---|
| URL source | `prepareFilesForSharing()` — **copies to a fresh temp directory** (`:1367-1392`) | `audioManager.urlForSharing($0)` — **the live file** in `fileDirectory` |
| Cleanup | `onDismiss` deletes each temp file and clears the array (`:860-867`) | **none** |
| Delete in the same menu? | "Delete N Files" is at `:1358-1364` | "Delete N Files" is at `PlaylisList_view.swift:310-312` |

The Songs tab's approach is the correct one, and it is why the `prepareFilesForSharing` helper exists. But it has two leaks:

- **The UUID subdirectory is never removed.** `prepareFilesForSharing` creates `temporaryDirectory/<uuid>/` (`:1368-1373`) and `onDismiss` only removes the files inside it (`:863-865`). Every share session leaves an empty directory behind. iOS purges `temporaryDirectory` opportunistically, not deterministically.
- **Temp copies are never de-duplicated against each other** — two files with the same `lastPathComponent` in one selection collide at `:1381-1384` (`copyItem` fails on an existing destination, is swallowed by the `print` at `:1387`, and that file is silently omitted from the share).

> **⚠️ The playlist-detail path hands out the live file, and offers Delete one row below Share in the same context menu.** `PlaylistMultiSelectContextMenu` puts "Share N Files" at `PlaylisList_view.swift:291-296` and "Delete N Files" at `:310-312`. The shared URLs point at `fileDirectory`, so a `deleteAudioFile` (which does `FileManager.removeItem` on that exact path — [08](08-playlists-and-library.md#42-deleteaudiofile_--the-cascade)) **during or immediately after the share** leaves every receiving extension with a URL that no longer resolves. The Songs tab avoids this by sharing copies; the playlist path should too. See [14-known-issues.md](14-known-issues.md).

### 6.3 Artwork export path

`PhotoPicker` (`View/content_view.swift:1599-1646`):

```swift
var config = PHPickerConfiguration(photoLibrary: .shared())
config.filter = .images
```

`Coordinator.picker(_:didFinishPicking:)` (`:1629-1644`):

1. **`parent.dismiss()` first** (`:1633`) — the sheet closes before the image loads.
2. `guard let result = results.first else { return }` (`:1635`) — **only the first selection is used**, even though `PHPickerConfiguration.selectionLimit` defaults to 0 (unlimited). The user can select 20 images and only the first is applied, with no indication.
3. `result.itemProvider.loadObject(ofClass: UIImage.self)` then `DispatchQueue.main.async { onImagePicked(image) }` (`:1637-1642`).

It uses `PHPickerViewController`, which is out-of-process and needs **no photo-library permission** — so `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` in the build settings (`project.pbxproj:567, 607`) is a *write* permission the app never requests and never needs. The string is also misleading: it says "To add photos to songs, playlists and albums" — the app reads photos for artwork, it does not add them to the library.

Wired via `.sheet(item: artworkTarget)` (`View/content_view.swift:621-638`), which dispatches on the `ArtworkTarget` case and for `.multipleFiles` calls `setArtwork(image, for: file)` **once per id in a loop** (`:629-635`) — each of which is a full `jpegData(0.8)` encode + disk write + `saveAudioFiles()`. Setting artwork on a 20-song selection writes the same image 20 times under 20 different UUID filenames. See [08](08-playlists-and-library.md#7-artworkservice).

---

## 7. What is *not* wired

| Thing | Status |
|---|---|
| `AudioShare` target | **does not exist** — only `Punches3`, `Punches3Tests`, `Punches3UITests` |
| `NSExtension` / `NSExtensionPrincipalClass` for the share extension | no `Info.plist` for it, no target to hold one |
| `CFBundleURLTypes` for `punches://openAndPlay` | absent from `Punches3-Info.plist` |
| `Punches3.entitlements` app-group | **empty `<dict/>`**, wired via `CODE_SIGN_ENTITLEMENTS` (`project.pbxproj:559, 598`) |
| `AudioShare/AudioShare.entitlements` | correct contents, **referenced by no target** |
| `silly_speed_ios.entitlements` | correct contents, **referenced by no target** |
| `isImporting` / `importError` UI | **no reader anywhere** |
| `startDownloadingUbiquitousItem` for iCloud files | not implemented |
| `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` | absent from the plist |
| `PHPickerConfiguration.selectionLimit` | not set, so multi-select is offered but only the first is used |
| `ContentView.shareURL` / the sheet in `applySheets` | declared and threaded but **never assigned** — dead (§6.2) |

---

## 8. Change checklist

| If you change… | Re-verify |
|---|---|
| `SharedConstants.appGroupIdentifier` | all three `containerURL` call sites, all three entitlements files, and the App ID in the developer portal |
| `pendingFilesKey` | both the writer (`ShareViewController.swift:160`) and the reader (`AudioImportService.swift:114`) |
| `openAndPlayScheme` | `ShareViewController.openMainApp`, `silly_speed.swift:17`, **and** `CFBundleURLTypes` in the plist |
| the `PendingImports` directory name | `ShareViewController.swift:136` and `AudioImportService.swift:119` |
| `importAudioFile(from:)` | the commit block's ordering (`:67-79`) — the two `UserDefaults` writes are not atomic |
| `processPendingImports` | it has no reentrancy guard and no main-actor isolation; three call sites can overlap |
| error handling in `processFiles` | `fileURLs.append` needs a lock; `item as? URL` is the only handled result type |
| `urlForSharing` | the URL points into the app container; any move to a shared location changes the Files-app exposure story |
| the `.multipleFiles` artwork path | one JPEG write per song, per selection |
| `PHPicker` multi-select | `results.first` only |
| the Songs-tab share sheet | see §6.2 — the Songs tab correctly shares temp copies; the playlist-detail path shares the live file and has Delete in the same menu |
| `prepareFilesForSharing` | it leaks the per-share UUID directory and drops same-named files (§6.2) |
| `applySheets`' `shareURL` | it is never assigned; the sheet at `View/content_view.swift:616-620` is dead code |
