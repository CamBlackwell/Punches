# 08 — Playlists & Library

> `AudioFile`/`Playlist`, the hidden `__MASTER_SONGS__` playlist that *is* the Songs tab, `AudioLibraryService`, `PlaylistService`, `ArtworkService`, and the Songs/Playlists/Playlist-Detail views.
> Companion: [12-persistence-and-keys.md](12-persistence-and-keys.md) (the on-disk schema), [09-file-import-and-sharing.md](09-file-import-and-sharing.md) (how files get in), [04-audio-pipeline.md](04-audio-pipeline.md) (what `playbackQueue` drives).

---

## 1. Files

| File | Lines | Role |
|---|---|---|
| `Models.swift` | 92 | all four model types |
| `Services/AudioLibraryService.swift` | 139 | the `audioFiles` array + filesystem reconciliation |
| `Services/PlaylistService.swift` | 161 | the `playlists` array + the master playlist |
| `Services/ArtworkService.swift` | 111 | artwork files, refcounted by name |
| `View/PlaylisList_view.swift` | 365 | `PlaylistDetailView` + its 3 context menus (note the typo'd filename) |
| `View/content_view.swift` | 1646 | `SongsListView` (`:756`), `PlaylistsListView` (`:912`), `MiniPlayerBar` (`:1016`), `AudioFileRow` (`:1423`) |

All three services are constructed once by `AudioManager` and hold it **`unowned`**:

```swift
// AudioLibraryService.swift:5 / PlaylistService.swift:5 / ArtworkService.swift:5
unowned let manager: AudioManager
```

`unowned` is a retain-cycle break, and it means **`manager` is a dangling reference the moment `AudioManager` deallocates.** These are singletons in practice, but any code that lets a service outlive its manager will crash on the next property access rather than cleanly no-op.

---

## 2. Models (`Models.swift`)

### 2.1 `AudioFile`

```swift
// Models.swift:3-32
struct AudioFile: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let dateAdded: Date
    let audioDuration: Float
    var artworkImageName: String?
    var title: String

    var fileURL: URL { AudioManager.fileDirectory.appendingPathComponent(fileName) }
}
```

Only `id`, `fileName` and `dateAdded` are `let`; `artworkImageName` and `title` are `var`. **Mutating a `let`-backed field is impossible**, which is why every artwork/title change rebuilds the whole struct via the 6-argument `init` (`:24-31`) instead of assigning a field. `ArtworkService.setArtwork(_:for:)` (`:42-51`) and `removeArtwork(from:)` (`:75-84`) both do this, as does `AudioLibraryService.renameAudioFile(_:to:)` (`:111-120`).

Two initialisers:

| Init | Used by | `title` behaviour |
|---|---|---|
| `init(fileName:audioDuration:artworkImageName:)` (`:15-22`) | the **import** path | `title = (fileName as NSString).deletingPathExtension` — strips the extension |
| `init(id:fileName:dateAdded:audioDuration:artworkImageName:title:)` (`:24-31`) | the **Codable** path and every mutation | `title = title ?? fileName` — **falls back to the filename *with* extension** |

> **⚠️ The two `title` fallbacks disagree.** Importing `song.mp3` gives `title == "song"`; decoding the same record through the fallback gives `title == "song.mp3"`. The `?? fileName` branch is currently unreachable via `Codable` synthesis — a non-optional `String` property makes the synthesised `init(from:)` **throw** on a missing `title` key rather than passing `nil` — so this only bites if someone calls the 6-arg init without a title. If you add a hand-written decoder or migrate the schema, the whole library silently becomes untitled-but-fine, then title-with-extension. Fix the fallback to `deletingPathExtension` before it matters.

> `audioDuration` is a `Float` stored in JSON. `Float` is not a `Codable` primitive that round-trips losslessly through every encoder path, and there is no validation on decode — a corrupt value yields `NaN`, which then makes the `timeSlider` range `0...max(NaN, 0.01)` (see [07](07-meters-and-hud.md#43-timeslider-138-170)). Consider `Double` or a `decode` guard.

### 2.2 `Playlist`

```swift
// Models.swift:34-48
struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var audioFileIDs: [UUID]
    let dateAdded: Date
    var artworkImageName: String?
}
```

**Membership is stored as `[UUID]`, not as embedded `AudioFile`s.** Consequences:

- `getAudioFiles(for:)` (`PlaylistService.swift:157-160`) does `playlist.audioFileIDs.compactMap { id in manager.audioFiles.first { $0.id == id } }` — an **O(n·m) linear scan** per lookup, and `getAudioFiles(for:)` is called from `PlaylistDetailView.playlistSongs` (`:23-25`), which is a **computed property read inside `body`**. A 500-song playlist renders 500 rows, each triggering a `compactMap` over 500 IDs with an inner 500-element `first(where:)`.
- **Dangling IDs are silently dropped** by `compactMap`. Deleting a song scrubs the IDs eagerly (`AudioLibraryService.swift:56-58`), so this only leaks if that scrub is bypassed.
- **Order is meaningful** — `audioFileIDs` order *is* the playlist's manual sort order. `reorderPlaylistSongs` (`:91-103`) and `reorderSelectedSongs` (`:222-231`) both rely on it.

> `Playlist` has **only** the 1-argument `init(name:artworkImageName:)`. There is no memberwise init, so the Codable path is fully synthesised. Adding a stored property with a default requires adding it to that single init.

### 2.3 `LibraryFilter` and `LibraryItem`

```swift
// Models.swift:50-54
enum LibraryFilter: Hashable { case songs, playlists, player }
```

Live: it is the `TabView(selection:)` tag for the three-page `TabView` in `View/content_view.swift:44-54`, driven by `@State private var libraryFilter: LibraryFilter = .songs` (`:11`). Only `.player` hides the bottom bar (`:60`).

```swift
// Models.swift:56-73
enum LibraryItem: Identifiable { case song(AudioFile); case playlist(Playlist) /* + id, dateAdded */ }
```

**`LibraryItem` is entirely unused** — the only occurrence in the whole repo is its own declaration. It is the vestige of a unified-library design that shipped as two separate lists. Both `id` and `dateAdded` are implemented, so it looks live; it isn't. Safe to delete.

### 2.4 `ArtworkTarget`

```swift
// Models.swift:76-91
enum ArtworkTarget: Identifiable {
    case audioFile(AudioFile)
    case playlist(Playlist)
    case multipleFiles(Set<UUID>)
}
```

`Identifiable` is required for `.sheet(item:)`. Note the `id` for `.multipleFiles` is `"multiple-" + ids.sorted().map { $0.uuidString }.joined()` (`:88`) — **sorted**, so the identity is order-independent, which is correct for a `Set`. But it means a 50-file selection produces a ~1850-character id string rebuilt on every `body` evaluation. Harmless, wasteful.

---

## 3. The master playlist — the most important thing in this document

**The Songs tab is a playlist.** There is no separate "all songs" store. `PlaylistService.loadOrCreateMasterPlaylist()` (`:52-74`) creates a playlist literally named:

```swift
// PlaylistService.swift:59
let masterPlaylist = Playlist(name: "__MASTER_SONGS__")
```

Its `id` is stored separately as JSON-encoded `UUID` data under `"masterPlaylistID"` (`audio_manager.swift:33-34`, `PlaylistService.swift:70-71`).

### 3.1 Lifecycle (called once, from `AudioManager.init`)

`audio_manager.swift:72-74`:

```swift
libraryService.loadAudioFiles()                    // :72  — the real files
playlistService.loadPlaylists()                    // :73  — [Playlist] from JSON
playlistService.loadOrCreateMasterPlaylist()       // :74  — resolve or create the master
```

`loadOrCreateMasterPlaylist` (`:52-74`) is a three-way branch:

| Condition | Action |
|---|---|
| `masterPlaylistID` data exists **and** decodes to a `UUID` **and** that UUID is in `playlists` | adopt it (`:56`) — the happy path |
| otherwise | `clearZombiePlaylists()` → create master → back-fill with every loaded `audioFile` id → save → persist the new id (`:58-72`) |

`clearZombiePlaylists()` (`:46-50`) is **nuclear**: it wipes `manager.playlists = []`, saves the empty array, and removes the `masterPlaylistID` key. It runs whenever the stored id is missing, undecodable, **or dangling** (points at a playlist that no longer exists).

> **⚠️ The self-heal path destroys every user playlist.** If `masterPlaylistID` becomes unreadable for any reason — a decode failure on the stored `Data`, a partially-written `UserDefaults`, a schema change to `Playlist` that makes `loadPlaylists()` return fewer entries than expected, an iCloud/`UserDefaults` sync conflict — the app silently deletes all playlists, including the user's own, and rebuilds only the master. There is **no backup and no prompt**. This is the highest-severity data-loss path in the library layer. See [14-known-issues.md](14-known-issues.md).
>
> The back-fill at `:63-67` also has an O(n²) shape: for every audio file it re-scans `manager.playlists` to find the master index.

### 3.2 How the master playlist is protected

It is protected **by filtering, not by assertion**:

```swift
// PlaylistService.swift:22-26
var sortedPlaylists: [Playlist] {
    manager.playlists
        .filter { $0.id != manager.masterPlaylistID }
        .sorted { $0.dateAdded > $1.dateAdded }
}
```

`sortedPlaylists` is the only source for the Playlists tab, so `__MASTER_SONGS__` is never rendered and therefore can never be deleted, renamed, reordered, or have its context menu tapped. Two consequences to respect:

1. **`deletePlaylist(_:)` (`PlaylistService.swift:131-135`) has no master guard.** It is currently safe *only* because the filter hides the row. Any new code path that calls `deletePlaylist` with a playlist drawn from `manager.playlists` directly can delete the master and trigger the nuclear reset on next launch.
2. **The Playlists tab's empty state is a magic number.** `View/content_view.swift:172`:

   ```swift
   if audioManager.playlists.count == 1 { EmptyPlaylistView(...) } else { PlaylistsListView(...) }
   ```

   This assumes `count == 1` ⟺ "only the master exists". If the master is ever missing, or a user somehow has 0 playlists, the empty state lies. `sortedPlaylists.isEmpty` is the correct test.

### 3.3 Four orderings of the same data

There is no single order for "the songs". Four arrays hold one, and only one of them is the user's:

| Accessor | Source | Sort | Used by | Preserves manual order? |
|---|---|---|---|---|
| `manager.audioFiles` | raw `FileManager` directory listing, appended in load order (`AudioImportService.swift:67`) | **none — never sorted** | the **player's default song** (`View/content_view.swift:224`, `:487-488`), and what `saveAudioFiles` persists | n/a (append order) |
| `PlaylistService.sortedAudioFiles` (`:11-20`) | `masterPlaylist.audioFileIDs` → resolved, **falling back to `audioFiles` sorted by `dateAdded` desc if the master is missing** (`:14`) | `dateAdded` desc — **re-sorts and discards the manual order** (`:19`) | `displayedSongs` on init, after delete/rename/import | **no** |
| `manager.displayedSongs` | mutable snapshot of the above | as set | the Songs tab | yes, until the next recompute |
| `manager.playbackQueue` | copied from whichever of the above produced the play action | as copied | next/previous, auto-advance | yes, until the next play |

Two distinct bugs fall out of this table:

**The player opens on the oldest song.** The Songs tab renders `displayedSongs`, which is correctly newest-first. The player reads `audioManager.audioFiles.first` — a raw array nothing ever sorts, holding the **first song ever imported**. Since `saveAudioFiles` persists `audioFiles` in that same append order, the wrong default survives relaunch. That is [14 · C13](14-known-issues.md#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list).

**The manual order is persisted and then ignored.** `reorderSongs` (`PlaylistService.swift:76-89`) writes the new order into `masterPlaylist.audioFileIDs` and saves it. `sortedAudioFiles` then re-sorts what it just read:

```swift
// Services/PlaylistService.swift:17-19
return masterPlaylist.audioFileIDs
    .compactMap { id in manager.audioFiles.first { $0.id == id } }
    .sorted { $0.dateAdded > $1.dateAdded }     // ← throws the manual order away
```

So the reorder *looks* correct on screen, and reverts the next time anything recomputes `displayedSongs = sortedAudioFiles` — import, delete, rename, artwork change, `reorderSelectedSongs`, or the next `init`. That is [14 · C14](14-known-issues.md#c14-manual-sort-order-is-silently-discarded).

**The one thing that does preserve it** is `reorderSongs`'s direct mutation:

```swift
manager.displayedSongs.move(fromOffsets: source, toOffset: destination)   // :77
...
manager.playlists[index].audioFileIDs = reorderedIDs                      // :83
manager.playlistService.savePlaylists()                                  // :84
if manager.playingFromSongsTab { manager.playbackQueue = manager.displayedSongs }   // :86-88
```

Import a single new file and your entire hand-sorted Songs list reverts to newest-first. That is a real, user-visible bug class, not a hypothetical.

> **The decision to make first:** is manual order or date order the intent? If manual, drop the `.sorted` on `PlaylistService.swift:19` and append new imports to the end of `audioFileIDs`. If date order, remove the reorder affordance rather than accepting an order that is discarded. Everything above is a consequence of that answer being deferred — including [C4](14-known-issues.md#c4-reordering-does-not-update-playbackqueue) and [C5](14-known-issues.md#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop), which are the queue-side and capture-side versions of the same split.

### 3.4 Search

```swift
// View/content_view.swift:235-245
var filteredSongs: [AudioFile] {
    let base = audioManager.displayedSongs
    if searchText.isEmpty { return base }
    return base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
}
var filteredPlaylists: [Playlist] {
    let base = audioManager.sortedPlaylists
    if searchText.isEmpty { return base }
    return base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
}
```

Both are **computed properties, not `@State`** — the full array is re-filtered on every `body` evaluation, on both tabs, on every keystroke, and on every `audioManager` publish. And critically:

> **⚠️ Search is not sorted-correct.** `filteredSongs` filters `displayedSongs` (the manual order) but `songsPage`'s empty-state check at `:200` uses `audioManager.audioFiles.isEmpty` — the *unfiltered* array. So with a search active and no matches, the user sees an **empty `List` with no empty-state message and no "no results" affordance.** Same for playlists: `playlistsPage` checks `audioManager.playlists.count == 1` (`:172`), unfiltered.

---

## 4. `AudioLibraryService` — the files array

### 4.1 Load-time reconciliation

```swift
// AudioLibraryService.swift:11-28
manager.audioFiles = loadedFiles.filter { file in
    let exists = FileManager.default.fileExists(atPath: file.fileURL.path())
    if !exists { print("File missing: \(file.fileName) at \(file.fileURL.path())") }
    return exists
}
```

Every launch, every recorded file is `fileExists`-checked and **dropped from the array if gone** — but **not** scrubbed from `UserDefaults` and **not** scrubbed from any playlist. The stale `AudioFile` record stays in the JSON forever, so a file deleted outside the app (Files app, iCloud eviction, a restore from backup that didn't include the audio) is re-checked and re-dropped on every launch, printing a line each time. And its ID stays in `Playlist.audioFileIDs`, so `getAudioFiles` silently returns a playlist that's missing songs the user believes are in it.

`fileExists` is a synchronous stat per file, on the main thread, inside `AudioManager.init` (`:72`).

### 4.2 `deleteAudioFile(_:)` — the cascade

`AudioLibraryService.swift:39-64`, in order:

1. `if currentlyPlayingID == audioFile.id { manager.stop() }` (`:40-42`)
2. `FileManager.removeItem(at: audioFile.fileURL)` (`:44-49`) — **`try`, and only a `print` on failure.** A delete that fails (file open, permission, read-only volume) removes the record anyway, orphaning the file on disk.
3. `manager.audioFiles.removeAll { … }` (`:51`)
4. `artworkService.deleteArtworkIfUnused(audioFile.artworkImageName)` (`:52`)
5. `saveAudioFiles()` (`:53`)
6. `manager.displayedSongs = manager.sortedAudioFiles` (`:54`) — **re-sorts, destroying the manual order (§3.3)**
7. scrub the id from every playlist, then `savePlaylists()` (`:56-59`)
8. remove it from `playbackQueue` if present (`:61-63`) — **not** persisted; see [12](12-persistence-and-keys.md)

The `displayedSongs` reset at `:54` reads the master playlist *before* step 7 scrubs the ID, but `sortedAudioFiles` uses `compactMap`, so a dangling ID would be dropped anyway. The order is not a bug — but the manual-order destruction in step 6 is.

### 4.3 `cleanupOrphanedFiles()` — destructive, and runs on every launch

```swift
// AudioLibraryService.swift:92-106
let trackedFileNames = Set(manager.audioFiles.map { $0.fileName })
guard let files = try? FileManager.default.contentsOfDirectory(at: AudioManager.fileDirectory, …) else { return }
for fileURL in files {
    let fileName = fileURL.lastPathComponent
    if fileName != "Artwork" && !trackedFileNames.contains(fileName) {
        print("Deleting orphaned file: \(fileName)")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
```

Called from `AudioManager.init` **after** `await importService.processPendingImports()` (`audio_manager.swift:76-80`).

This is a blanket `rm` of the entire `AudioFiles` directory, keyed on "is it in `audioFiles`?". It skips exactly one name, the literal string `"Artwork"`. Anything else that isn't tracked **is deleted**, including:

- files mid-import if `processPendingImports()` returned before its copies finished;
- the temp/partial files a staged import might use;
- anything a future feature parks there (see [09](09-file-import-and-sharing.md));
- **anything the user put there via the Files app**, since the app group container is reachable if they use a file provider.

The only thing preventing a bad launch is that `processPendingImports()` is `await`ed first. There is no dry-run mode, no grace period, and no `isHidden`/prefix exemption. The `try?` swallows failures silently. This is the second-highest-severity data-loss path.

### 4.4 `generateUniqueFileName(for:)` and `renameAudioFile(_:to:)`

`generateUniqueFileName` (`:66-90`) is a linear `while true` probe: try the original, then `"<base> 2.<ext>"`, `"<base> 3.<ext>"`, … with a `FileManager.fileExists` stat per candidate. O(n) stats in the worst case for n same-named imports. Returns `originalName` unchanged if free.

`renameAudioFile(_:to:)` (`:108-123`) **renames the title only, not the file.** The new `AudioFile` is constructed with `fileName: audioFile.fileName` (`:113`) and `title: newTitle` (`:117`), so the on-disk name is never touched and the title can be set to anything including a string with `/` or NUL. It is a display-name editor, despite living in the library service next to real filesystem code.

---

## 5. `PlaylistService` — mutations

Every mutator follows the same shape: `guard let index = firstIndex(where: id)`, mutate, `savePlaylists()`.

| Method | Line | Guard | Notes |
|---|---|---|---|
| `createPlaylist(name:)` | `:116-129` | none | **saves on a `Task.detached(priority: .utility)`** (`:120-128`) |
| `deletePlaylist(_:)` | `:131-135` | none | also `deleteArtworkIfUnused` |
| `renamePlaylist(_:to:)` | `:137-141` | index | no empty-name check |
| `addAudioFile(_:to:)` | `:143-149` | index | **idempotent** — `if !contains` (`:145`) |
| `removeAudioFile(_:from:)` | `:151-155` | index | `removeAll { $0 == … }` |
| `getAudioFiles(for:)` | `:157-160` | — | the O(n·m) resolve |

> **⚠️ `createPlaylist` is the only async writer, and it captures a stale snapshot.** It snapshots `let playlists = manager.playlists` (`:119`) *before* dispatching, then writes that snapshot to `UserDefaults` from a detached task (`:123-124`). Two rapid creates, or a create followed by any other mutation before the detached task runs, will have the second write clobber the first — **losing a playlist**. Because it runs on `.utility` it usually wins the race, which is why this is intermittent. Every other mutator saves synchronously. There is no serial write queue and no write coalescing anywhere in the app.

> **`addAudioFile` does not touch `displayedSongs`** — correct, since playlists don't own the Songs list. But it also does not check whether the file still exists.

---

## 6. Reordering

Three entry points, all funnelling into the same array-of-UUIDs representation.

### 6.1 Single-item move, Songs tab

`PlaylistService.reorderSongs(from:to:)` (`:76-89`) — `move` on `displayedSongs`, mirror into the **master** playlist, save, and reset `playbackQueue` if playing from the Songs tab.

### 6.2 Single-item move, inside a playlist

`PlaylistService.reorderPlaylistSongs(in:from:to:)` (`:91-103`) — copies the playlist out, moves on the **local copy**, then hops to main to write back:

```swift
var updatedPlaylist = manager.playlists[index]
updatedPlaylist.audioFileIDs.move(fromOffsets: source, toOffset: destination)
DispatchQueue.main.async { [weak self] in
    self.manager.playlists[index] = updatedPlaylist
    self.savePlaylists()
}
```

> **⚠️ This async hop is both unnecessary and dangerous.** `PlaylistService` is not actor-isolated, `move(fromOffsets:toOffset:)` is called on whatever thread SwiftUI's `onMove` fires on (always main, in practice), and the closure captures the **integer `index`** by value (`:100`). If *any* playlist is deleted, created, or reordered between the `move` and the `main.async` body running, `index` now points at a **different playlist** and this line overwrites it wholesale. The mutation also does not update `playbackQueue`, unlike its Songs-tab sibling — so reordering inside a playlist leaves the playing queue stale.

### 6.3 Multi-select drag

`AudioPlaybackService.reorderSelectedSongs(selectedIDs:to:in:playlist:)` (`:205-246`). This is the most careful code in the layer:

```swift
let selectedIndices = … .sorted()                                    // :206-209
let selectedSongs   = selectedIndices.map { currentSongs[$0] }        // :211
var songs = currentSongs                                             // :212
for index in selectedIndices.reversed() { songs.remove(at: index) }   // :214-216  ← reversed!
let adjustedDestination = destination - selectedIndices.filter { $0 < destination }.count   // :218
songs.insert(contentsOf: selectedSongs, at: adjustedDestination)      // :220
```

Three things it gets right that the others don't:

- **Remove in reverse index order** (`:214`) so earlier removals don't invalidate later indices.
- **Adjust the destination** (`:218`) to account for the selections that were removed from *before* it — the standard multi-drag correction.
- **Persist and re-sync `playbackQueue`**, and branch on `playingFromSongsTab` (`:229-231`, `:242-244`) to mirror the two single-item variants.

Its caller in `View/content_view.swift:814-830` guards it correctly: it only takes the multi-select path `if isMultiSelectMode && !selectedFileIDs.isEmpty` **and** `source.allSatisfy({ selectedIndices.contains($0) })` (`:820`) — i.e. a drag that starts on a non-selected row falls through to the plain single-item move.

> The `playlist:` parameter defaults to `nil` (`:205`) and **no caller ever passes it** — the playlist-detail list's `onMove` (`PlaylisList_view.swift:80-82`) only calls `reorderPlaylistSongs`. So `reorderSelectedSongs` is only ever used for the Songs tab, and its `playlist:` branch (`:222-231`) is dead. `PlaylistDetailView` has no multi-select drag at all, even though it has a full multi-select mode.

---

## 7. `ArtworkService`

```swift
// ArtworkService.swift:11-26
func saveArtwork(from image: UIImage) -> String? {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }
    let filename = "artwork_\(UUID().uuidString).jpg"
    …write to manager.artworkDirectory…
}
```

- **JPEG at quality 0.8, no resizing.** A 12-megapixel photo from the picker is encoded at full resolution and written to the app group. `PhotosPicker` does return large images.
- Filename is a fresh UUID every time, so **setting artwork twice never overwrites** — it creates a second file and relies on `deleteArtworkIfUnused` to reap the first.
- `loadArtworkImage(_:)` (`:28-34`) is `Data(contentsOf:)` + `UIImage(data:)` — **no cache, no downscale, fully synchronous.** It is called from `AudioFileRow` and from `AudioPlayerView`'s `.Artwork` case (`View/audio_player_view.swift:76-77`), i.e. **inside `body`**. Every re-render of a song list re-reads and re-decodes every visible JPEG from disk.
- `deleteArtworkIfUnused(_:)` (`:100-110`) is a **name-based refcount** across `audioFiles` and `playlists`, deleting only at zero. Correct for the dedup that the UUID-per-save scheme never produces — in practice each artwork file is referenced exactly once, so this is really just a delete-if-no-one-uses-it.
- **Asymmetry:** `setArtwork(_:for: AudioFile)` (`:36-55`) refreshes `displayedSongs` (`:52`); `setArtwork(_:for: Playlist)` (`:57-68`) does not need to. But **neither** call is routed through a single code path — the two `removeArtwork` overloads (`:70-87`, `:89-98`) duplicate the same shape a third and fourth time.

---

## 8. The views

### 8.1 Songs tab

`SongsListView` (`View/content_view.swift:756-910`), a `List` of `AudioFileButton` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, `.background(Color.clear)`.

Two presentation details worth knowing:

- **Bottom fade mask** (`:837-847`): a `LinearGradient` `.mask` that goes opaque to 90 % then `.clear` at 1.0, so rows fade out under the floating bottom bar. `PlaylistsListView` duplicates it byte-for-byte (`:995-1005`).
- **Scroll detection** (`:848-854`): `.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y }` sets `isScrolledDown = newOffset > 60` inside `withAnimation(.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0.15))`. This drives the bottom-bar collapse. Both list views duplicate it exactly.
- A **spacer row** `Color.clear.frame(height: 35)` (`View/content_view.swift:832`, `PlaylisList_view.swift:85`) pads the list above the bar.
- The `AddActionButton` header is **commented out** in both lists (`View/content_view.swift:780-787`, `:931-939`); adding is now toolbar-only. `AddActionButton` (`View/content_view.swift:1395`) is therefore **dead code**.

`onMove` is at `View/content_view.swift:814-830` (see §6.3). `@Environment(\.editMode)` is read (`View/content_view.swift:770`) but the reorder-mode toggle itself is driven by `EditButton`/`environment(\.editMode, …)` at `View/content_view.swift:855+`, mirroring the pattern at `PlaylisList_view.swift:89`.

### 8.2 Playlists tab

`PlaylistsListView` (`:912-1014`) — a `List` of `NavigationLink` → `PlaylistDetailView`, each with a context menu offering Set/Change Artwork, Remove Artwork (only if set), rename, and Delete.

**All playlists are `NavigationLink`s into a `NavigationStack` inside a `TabView` page** (`View/content_view.swift:40-54`). Navigating to a playlist therefore switches the toolbar's leading/centre content, and the bottom bar is still shown unless `libraryFilter == .player`.

### 8.3 Playlist detail

`PlaylistDetailView` (`PlaylisList_view.swift:4-197`). This is the most state-heavy view in the app: **11 `@Binding`s** (`:8-13`, plus `:16-21`) threading presentation state from `ContentView` down into `PlaylistAudioFileButton` (`:199-277`) — rename alerts, share sheets, artwork targets, multi-select, and three batch dialogs. It is also the only place a row has a `.swipeActions` (`:70-78`) offering a destructive "Remove" (remove-from-playlist only; the destructive "Delete Permanently" is context-menu-only, at `:359-363`).

Its empty state (`:33-46`) is a 60 pt `music.note.list` glyph plus *"This playlist is empty / Go to Songs view and use the context menu to add songs here"*.

Two bugs:

> **`playlistSongs` is a computed property that does a linear resolve per row.** `audioManager.getAudioFiles(for: playlist)` (`PlaylisList_view.swift:23-25`) is called from `body`, and `ForEach(playlistSongs)` re-invokes it — the value is used **7 times** in `body` (`:33, 49, 109, 112`). For a 500-song playlist that is ~3500 `compactMap` + `first(where:)` passes per body evaluation, at 60 Hz if `audioManager` publishes. Memoising it as `@State`/a stored snapshot, or indexing `audioFiles` by UUID, is the fix.
>
> **It reads `audioManager.playlists.filter { $0.id != playlist.id }` for the "Add to Another Playlist" menu** (`:155`, `:348`) and calls `addAudioFile` in a `ForEach` over the *selected IDs* (`:157-161`) — so batch-add does one full `savePlaylists()` per song (`:147`), i.e. N JSON encodes of the whole playlist array for N songs.

### 8.4 Context menus, side by side

There are **three** near-duplicate context-menu views:

| View | Line | Used by |
|---|---|---|
| `AudioFileContextMenu` | `View/content_view.swift:1513-1563` | Songs tab |
| `PlaylistAudioFileContextMenu` | `PlaylisList_view.swift:316-365` | Playlist detail, single selection |
| `PlaylistMultiSelectContextMenu` | `PlaylisList_view.swift:279-314` | Playlist detail, multi selection |

`PlaylistMultiSelectContextMenu` takes `selectedFileIDs: Set<UUID>` **by value** (`:282`) and the enclosing view already filters its options to selected rows (`PlaylisList_view.swift:249-250`), so the copy is intentional.

The playlist-detail versions use **lowercase, inconsistent labels** — `"share this file"`, `"rename"`, `"Remove from '\(playlist.name)'"` (`:328, 342, 355`) — while the Songs-tab version capitalises. The screenshots in the app will show both conventions. Every "Add to Another Playlist" submenu is a `ForEach` over *other* playlists (`:348`, `content_view.swift` equivalent) and is **empty if you have no other playlist**, with no disabled/empty state.

### 8.5 `MiniPlayerBar`

`View/content_view.swift:1016-1121`, shown when `audioManager.currentlyPlayingID != nil && !isMultiSelectMode` (`PlaylisList_view.swift:93`). `progressPercentage` (`View/content_view.swift:1111`) maps `currentTime / duration`. It appears in `PlaylistDetailView` but is not referenced from `SongsListView` in the excerpted range — check before assuming both tabs have one.

---

## 9. Change checklist

| If you change… | Re-verify |
|---|---|
| `AudioFile`'s stored properties | both inits (`:15-22`, `:24-31`); the Codable path needs no change but the display-name fallback disagrees with the import path (§2.1) |
| `Playlist`'s stored properties | the single `init(name:artworkImageName:)`; the master playlist is a `Playlist` too, so a required field without a default breaks `loadOrCreateMasterPlaylist` |
| `masterPlaylistID` handling | `loadOrCreateMasterPlaylist` (`:52-74`) and `clearZombiePlaylists` (`:46-50`) — the reset path deletes user playlists |
| `sortedAudioFiles` (`:11-20`) | it *discards* the manual order by sorting on `dateAdded`; every caller that reassigns `displayedSongs` inherits that |
| `deletePlaylist` | the master guard is `sortedPlaylists`'s filter, not an assertion (§3.2) |
| `playlistsPage`'s `count == 1` check (`content_view.swift:172`) | use `sortedPlaylists.isEmpty` instead; the current form is a magic number |
| `filteredSongs` / `filteredPlaylists` | they filter but the empty states don't (§3.4) — searching with no matches shows a blank list |
| `cleanupOrphanedFiles` | the `"Artwork"` literal exemption (`:101`) and the fact it runs on every launch after imports |
| `createPlaylist`'s detached save | the stale-snapshot race (§5) — serialise all `UserDefaults` writes |
| `reorderPlaylistSongs`'s `main.async` | the captured `index` (`:100`) can target a different playlist after any concurrent mutation |
| `PlaylistDetailView.playlistSongs` | it is a computed property evaluated 7× per `body`; see §8.3 |
| `ArtworkService.loadArtworkImage` | no cache, called from `body`; consider an `NSCache` keyed on filename |
| `LibraryItem` | delete it, or wire it up — it has zero references |
