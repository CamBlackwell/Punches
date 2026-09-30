# 08 — Playlists & Library

> `AudioFile`/`Playlist`, the hidden `__MASTER_SONGS__` playlist that *is* the Songs tab, `AudioLibraryService`, `PlaylistService`, `ArtworkService`, and the Songs/Playlists/Albums/Playlist-Detail views.
> Companion: [12-persistence-and-keys.md](12-persistence-and-keys.md) (the on-disk schema), [09-file-import-and-sharing.md](09-file-import-and-sharing.md) (how files get in), [04-audio-pipeline.md](04-audio-pipeline.md) (what `playbackQueue` drives).

> **Albums are playlists.** There is no `Album` type, no `AlbumService`, and no `albums` array. An album is a `Playlist` with `isAlbum == true`, rendered on its own page with a cover-first layout. Everything in §3–§7 applies to albums unchanged; §8.6 covers only what is different about the presentation.

---

## 1. Files

| File | Lines | Role |
|---|---|---|
| `Models.swift` | 126 | all four model types |
| `Services/AudioLibraryService.swift` | 139 | the `audioFiles` array + filesystem reconciliation |
| `Services/PlaylistService.swift` | 201 | the `playlists` array + the master playlist |
| `Services/ArtworkService.swift` | 128 | artwork files, refcounted by name, now with an image cache |
| `View/PlaylisList_view.swift` | 374 | `PlaylistDetailView` + its 3 context menus (note the typo'd filename) |
| `View/Album_view.swift` | 692 | `AlbumsListView`, `AlbumDetailView`, `AlbumGridCell`, `AddSongsToAlbumSheet` |
| `View/content_view.swift` | 1743 | `SongsListView` (`:831`), `PlaylistsListView` (`:987`), `albumsPage` (`:208`), `MiniPlayerBar` (`:1091`), `AudioFileRow` (`:1498`) |

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
// Models.swift:34-81
struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var audioFileIDs: [UUID]
    let dateAdded: Date
    var artworkImageName: String?
    var isAlbum: Bool
    var coverIsManual: Bool
    var artist: String?
}
```

The last three fields are what make an album. `isAlbum` routes the record to the Albums page; `artist` is album-level metadata that is **not** derived from member songs; `coverIsManual` records whether `artworkImageName` is a user choice or just the first member song's artwork (see §8.6).

`init(name:artworkImageName:isAlbum:artist:)` still exists as the only memberwise-style init, and the Codable path is still hand-written.

**`Playlist` has a hand-written `init(from:)` — this is load-bearing, not boilerplate.**

```swift
// Models.swift:90-107
enum CodingKeys: String, CodingKey {
    case id, name, audioFileIDs, dateAdded, artworkImageName
    case isAlbum, coverIsManual, artist
}
```

Every key the app added after launch 1 uses `decodeIfPresent(…) ?? default`. The reason is §3.1: `loadOrCreateMasterPlaylist` catches any throw from the decode and calls `clearZombiePlaylists()`, which **writes back an array containing only the master playlist — deleting every user playlist and album**. Synthesised `Codable` throws on a missing non-optional key, so *adding any required field to `Playlist` silently wipes user data on the next launch.* If you add a field here, it goes in `decodeIfPresent` with a default, and the checklist in §9 is not optional.

`audioFileIDs` also uses `decodeIfPresent … ?? []` even though it is non-optional, which is harmless and slightly more tolerant than synthesis.

> Adding `artist` to **`AudioFile`** instead would be the genuinely dangerous version of this: `AudioFile` decode failure routes into `AudioLibraryService`'s reconciliation, which deletes files that are not on disk. The reason album artists cannot be read per-song is not that it was avoided here — it is that this codebase has no embedded-metadata reader at all. See [12](12-persistence-and-keys.md).

**Membership is stored as `[UUID]`, not as embedded `AudioFile`s.** Consequences:

- `getAudioFiles(for:)` (`PlaylistService.swift:197-200`) does `playlist.audioFileIDs.compactMap { id in manager.audioFiles.first { $0.id == id } }` — an **O(n·m) linear scan** per lookup, and `getAudioFiles(for:)` is called from `PlaylistDetailView.playlistSongs` (`:23-25`), which is a **computed property read inside `body`**. A 500-song playlist renders 500 rows, each triggering a `compactMap` over 500 IDs with an inner 500-element `first(where:)`.
- **`songsByPlaylistID(for:)` (`:48-56`) is the fix**, and it is what the Albums grid uses: it builds one `[UUID: AudioFile]` index of the library, then one dictionary entry per album, so resolving N albums costs one pass over the library instead of N. `getAudioFiles(for:)` is now that same code with a single-element dictionary. Converting `PlaylistDetailView` to it is still open (§9).
- **Dangling IDs are silently dropped** by `compactMap`. Deleting a song scrubs the IDs eagerly (`AudioLibraryService.swift:56-58`), so this only leaks if that scrub is bypassed.
- **Order is meaningful** — `audioFileIDs` order *is* the playlist's manual sort order, and it is also the album's **track number**. `reorderPlaylistSongs` and `reorderSelectedSongs` both rely on it, and `AlbumDetailView`'s numbered rows read it directly.
- **Duplicates are not prevented on write.** `addAudioFile` is idempotent for a single call, but `AddSongsToAlbumSheet` and the batch dialogs do not re-check, so a race between two rapid adds could append the same id twice and number the track twice.

### 2.3 `LibraryFilter` and `LibraryItem`

```swift
// Models.swift:110-125
enum LibraryFilter: Hashable { case songs, playlists, albums, player }
```

Live: it is the `TabView(selection:)` tag for the four-page `TabView` in `View/content_view.swift:47-68`, driven by `@State private var libraryFilter: LibraryFilter = .songs` (`:11`). Only `.player` hides the bottom bar (`:60`). `.albums` sits **between** Playlists and Songs, with a `square.stack` glyph.

`case albums` has no default value and no `Hashable` concern, but note that `switch` statements over `LibraryFilter` elsewhere must be exhaustive — adding a case is a compile error at every such site, which is the intended safety net.

```swift
// Models.swift:83-88
enum LibraryItem: Identifiable { case song(AudioFile); case playlist(Playlist) /* + id, dateAdded */ }
```

**`LibraryItem` is entirely unused** — the only occurrence in the whole repo is its own declaration. It is the vestige of a unified-library design that shipped as two separate lists. Both `id` and `dateAdded` are implemented, so it looks live; it isn't. Safe to delete.

### 2.4 `ArtworkTarget`

```swift
// Models.swift:110-125
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
// PlaylistService.swift:89-97
let masterPlaylist = Playlist(name: "__MASTER_SONGS__")
```

Its `id` is stored separately as JSON-encoded `UUID` data under `"masterPlaylistID"` (`audio_manager.swift:33-34`, `PlaylistService.swift:111-112`).

### 3.1 Lifecycle (called once, from `AudioManager.init`)

`audio_manager.swift:80-82`:

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
// PlaylistService.swift:33-37
var sortedPlaylists: [Playlist] {
    manager.playlists
        .filter { $0.id != manager.masterPlaylistID }
        .sorted { $0.dateAdded > $1.dateAdded }
}
```

`sortedPlaylists` is the only source for the Playlists tab, so `__MASTER_SONGS__` is never rendered and therefore can never be deleted, renamed, reordered, or have its context menu tapped. It **also filters out albums** — Playlists and Albums are two views of one array, and neither may show the other's rows:

```swift
// Services/PlaylistService.swift:22-39
var sortedPlaylists: [Playlist] {
    sortedCollections.filter { !$0.isAlbum }
}
var sortedAlbums: [Playlist] {
    sortedCollections.filter { $0.isAlbum }
}
private var sortedCollections: [Playlist] {   // both pages, one sort, one filter
    manager.playlists
        .filter { $0.id != manager.masterPlaylistID }
        .sorted { $0.dateAdded > $1.dateAdded }
}
```

`sortedCollections` is `private` and exists so the exclusion and the sort cannot drift apart between the two pages. Both are alphabetically ordered by section rather than by name, so the name of the private helper is slightly misleading — it sorts newest-first like every other list in the app.

Two consequences to respect:

1. **`deletePlaylist(_:)` (`PlaylistService.swift:163-168`) now guards the master by id** — `guard playlist.id != manager.masterPlaylistID`. It used to have *no* guard and was safe only because the filter hid the row; any new call site that passes a playlist from `manager.playlists` directly would previously have deleted the master and triggered the nuclear reset on next launch.
2. **The Playlists tab's empty state is no longer a magic number** — `View/content_view.swift:182` was `audioManager.playlists.count == 1`, which assumed `count == 1` ⟺ "only the master exists" and lied if the master were ever missing. It is now `audioManager.sortedPlaylists.isEmpty`, and `albumsPage` uses `audioManager.sortedAlbums.isEmpty`.

### 3.3 Four orderings of the same data

There is no single order for "the songs". Four arrays hold one, and only one of them is the user's:

| Accessor | Source | Sort | Used by | Preserves manual order? |
|---|---|---|---|---|
| `manager.audioFiles` | raw `FileManager` directory listing, appended in load order (`AudioImportService.swift:67`) | **none — never sorted** | the **player's default song** (`View/content_view.swift:258`, `:487-488`), and what `saveAudioFiles` persists | n/a (append order) |
| `PlaylistService.sortedAudioFiles` (`:11-20`) | `masterPlaylist.audioFileIDs` → resolved, **falling back to `audioFiles` sorted by `dateAdded` desc if the master is missing** (`:14`) | `dateAdded` desc — **re-sorts and discards the manual order** (`:19`) | `displayedSongs` on init, after delete/rename/import | **no** |
| `manager.displayedSongs` | mutable snapshot of the above | as set | the Songs tab | yes, until the next recompute |
| `manager.playbackQueue` | copied from whichever of the above produced the play action | as copied | next/previous, auto-advance | yes, until the next play |

Two distinct bugs fall out of this table:

**The player opens on the oldest song.** The Songs tab renders `displayedSongs`, which is correctly newest-first. The player reads `audioManager.audioFiles.first` — a raw array nothing ever sorts, holding the **first song ever imported**. Since `saveAudioFiles` persists `audioFiles` in that same append order, the wrong default survives relaunch. That is [14 · C13](14-known-issues.md#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list).

**The manual order is persisted and then ignored.** `reorderSongs` (`PlaylistService.swift:117-130`) writes the new order into `masterPlaylist.audioFileIDs` and saves it. `sortedAudioFiles` then re-sorts what it just read:

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

2. **Every "other collections" list must union both pages.** Albums and playlists are one array, so a list that filters to one page silently makes the other unreachable as a target. Three different shapes are in use, and all three are correct as long as the union is present:
   - **Single unioned list** — `PlaylistDetailView.transferTargets` (`PlaylisList_view.swift:42-45`) and `AlbumDetailView.transferTargets(excluding:)` (`View/Album_view.swift:548-552`) are `sortedPlaylists + sortedAlbums` minus the current collection. One dialog, every destination.
   - **Two labelled submenus** — `PlaylistAudioFileContextMenu` (`PlaylisList_view.swift:358-375`) and `AudioFileContextMenu` (`View/content_view.swift:1645-1654`) split into *"Add to Another Playlist"* and *"Add to Album"*, each with its own `ForEach`. Arguably better for discovery than one undifferentiated list.
   - ⚠️ The concatenation is **all playlists then all albums**, newest-first within each — not one newest-first list. If a merged dialog ever looks out of order, this is why.

   The failure mode to watch for is the pre-existing one this feature is vulnerable to: any list written as `manager.playlists.filter { $0.id != current.id }` includes albums *and* the master playlist, while `sortedPlaylists` alone excludes albums. Both wrong in different directions.

### 3.4 Search

```swift
// View/content_view.swift:262-280
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
var filteredAlbums: [Playlist] {                    // :281-288
    let base = audioManager.sortedAlbums
    if searchText.isEmpty { return base }
    return base.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
}
```

All three are **computed properties, not `@State`** — the full array is re-filtered on every `body` evaluation, on every tab, on every keystroke, and on every `audioManager` publish. Albums match on **title or artist**, because "beatles" should find the album. And critically:

> **⚠️ Search empty states remain broken.** `filteredSongs` filters `displayedSongs` (the manual order) but `songsPage`'s empty-state check at `:200` uses `audioManager.audioFiles.isEmpty` — the *unfiltered* array. So with a search active and no matches, the user sees an **empty `List` with no empty-state message and no "no results" affordance.** The playlist and album pages use the correct unfiltered test for *whether the page is empty at all*, which is the right call — but it means the three pages now have three different empty-state semantics: "library is empty" for one, "filter matched nothing" for none.

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

Called from `AudioManager.init` **after** `await importService.processPendingImports()` (`audio_manager.swift:84-88`).

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
| `createPlaylist(name:isAlbum:artist:)` | `:157-161` | none | **saves synchronously**; `isAlbum`/`artist` default to `false`/`nil` so playlist callers are unchanged |
| `deletePlaylist(_:)` | `:163-168` | master id | also `deleteArtworkIfUnused` |
| `renamePlaylist(_:to:)` | `:170-174` | index | no empty-name check |
| `setArtist(_:for:)` | `:176-181` | index | trims; **empty/whitespace normalises to `nil`** rather than storing `""` |
| `addAudioFile(_:to:)` | `:183-189` | index | **idempotent** — `if !contains` |
| `removeAudioFile(_:from:)` | `:191-195` | index | `removeAll { $0 == … }` |
| `getAudioFiles(for:)` | `:197-200` | — | now an indexed resolve, not the O(n·m) scan |
| `songsByPlaylistID(for:)` | `:48-56` | — | one library index → one `[UUID: [AudioFile]]` for a whole page |
| `coverName(for:songs:)` | `:61-64` | — | manual cover → first member song's artwork → `nil` |

> **`createPlaylist` is now a synchronous writer and the stale-snapshot race is gone.** It previously snapshotted `playlists` and wrote it from a `Task.detached(priority: .utility)`, so two rapid creates lost one playlist. It now mutates the live array and calls `savePlaylists()` inline, like every other mutator. **There is still no serial write queue or coalescing** — every mutator performs a full `JSONEncoder` pass over the entire playlist array into `UserDefaults`, so adding N songs to an album is N encodes. `AudioManager.createAlbum` (`:150-153`) is a plain synchronous call for the same reason; the view shows the new album on the next run-loop pass rather than optimistically.

> **`deletePlaylist` guards the master by id** (`:164`), which is stronger than the old reliance on `sortedPlaylists`'s filter happening to exclude it. Albums and playlists share the path, so the guard is what stops an album delete from nuking the Songs tab.

> **`addAudioFile` does not touch `displayedSongs`** — correct, since neither playlists nor albums own the Songs list. But it also does not check whether the file still exists.

> **`setArtist` writes to a playlist, not an `AudioFile`, and stores `nil` for blank input.** This is deliberate: an empty `artist` must fall back to the "Add Artist" affordance in the UI and to the song-count subtitle in the grid, and `""` would satisfy neither while still round-tripping through JSON as an empty string.

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

Its caller in `View/content_view.swift:889-905` guards it correctly: it only takes the multi-select path `if isMultiSelectMode && !selectedFileIDs.isEmpty` **and** `source.allSatisfy({ selectedIndices.contains($0) })` (`:820`) — i.e. a drag that starts on a non-selected row falls through to the plain single-item move.

> The `playlist:` parameter defaults to `nil` (`:205`) and **no caller ever passes it** — the playlist-detail list's `onMove` (`PlaylisList_view.swift:93-95`) only calls `reorderPlaylistSongs`. So `reorderSelectedSongs` is only ever used for the Songs tab, and its `playlist:` branch (`:222-231`) is dead. `PlaylistDetailView` has no multi-select drag at all, even though it has a full multi-select mode.

---

## 7. `ArtworkService`

```swift
// ArtworkService.swift:21-36
func saveArtwork(from image: UIImage) -> String? {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }
    let filename = "artwork_\(UUID().uuidString).jpg"
    …write to manager.artworkDirectory…
}
```

- **JPEG at quality 0.8, no resizing.** A 12-megapixel photo from the picker is encoded at full resolution and written to the app group. `PhotosPicker` does return large images.
- Filename is a fresh UUID every time, so **setting artwork twice never overwrites** — it creates a second file and relies on `deleteArtworkIfUnused` to reap the first.
- `loadArtworkImage(_:)` (`:33-46`) is `Data(contentsOf:)` + `UIImage(data:)`, but now goes through an `NSCache<NSString, UIImage>` keyed on the filename. That fixes the worst of the pre-cache behaviour (every re-render re-reading every visible JPEG) for repeat renders, but **the first load of each image is still a synchronous disk read and decode inside `body`**, so a long scroll still does blocking I/O on the main thread. It is a mitigation, not a fix; a real fix is an async loader or a downsample-to-display-size image at save time.
- `deleteArtworkIfUnused(_:)` (`:116-127`) is a **name-based refcount** across `audioFiles` and `playlists`, deleting only at zero. Correct for the dedup that the UUID-per-save scheme never produces — in practice each artwork file is referenced exactly once, so this is really just a delete-if-no-one-uses-it. Because albums are playlists, **a manual album cover participates in the same refcount** and is not reaped while any song or collection still names it.
- **Asymmetry:** `setArtwork(_:for: AudioFile)` (`:48-67`) refreshes `displayedSongs`; `setArtwork(_:for: Playlist)` (`:69-81`) does not need to. But **neither** call is routed through a single code path — the two `removeArtwork` overloads duplicate the same shape a third and fourth time.

### 7.1 `coverIsManual` — the manual/derived distinction

`Playlist.coverIsManual` exists because a `Playlist`'s `artworkImageName` is now **two different things** that were previously conflated:

- **Manual** — the user picked this cover. `setArtwork(_:for: Playlist)` (`:77`) sets `coverIsManual = true`. It sticks even after the songs it was derived from are removed, and `removeArtwork(from:)` (`:104-114`) resets it to `false`.
- **Derived** — a legacy record, or one that was never given a cover. `coverIsManual` is `false` and `PlaylistService.coverName(for:songs:)` (`:61-64`) falls back to the first member song with artwork:

  ```swift
  if album.coverIsManual { return album.artworkImageName }
  if let first = songs.first(where: { $0.artworkImageName != nil }) { return first.artworkImageName }
  return album.artworkImageName   // a legacy explicit cover still wins over "no cover"
  ```

The third line is the compatibility case: pre-album playlists that already had a cover store **no** `coverIsManual` key, so they decode as `false` (§2.2). Without that fallback their artwork would silently disappear the moment the first member song gained a different cover. `init(name:…)` sets `coverIsManual = artworkImageName != nil` (`:55`), so anything created through the normal path is classified correctly on creation.

> The two rules are **not** symmetric. A derived cover is a *function of the current membership*, so removing the first song with artwork re-derives the cover from the next one. A manual cover is stored, so it survives any membership change. This is intentional — "the album art is the first track's art" is a fallback, not a promise.

---

## 8. The views

### 8.1 Songs tab

`SongsListView` (`View/content_view.swift:831-985`), a `List` of `AudioFileButton` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, `.background(Color.clear)`.

Two presentation details worth knowing:

- **Bottom fade mask** (`:837-847`): a `LinearGradient` `.mask` that goes opaque to 90 % then `.clear` at 1.0, so rows fade out under the floating bottom bar. `PlaylistsListView` duplicates it byte-for-byte (`:995-1005`).
- **Scroll detection** (`:848-854`): `.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y }` sets `isScrolledDown = newOffset > 60` inside `withAnimation(.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0.15))`. This drives the bottom-bar collapse. Both list views duplicate it exactly.
- A **spacer row** `Color.clear.frame(height: 35)` (`View/content_view.swift:907`, `PlaylisList_view.swift:98`) pads the list above the bar.
- The `AddActionButton` header is **commented out** in both lists (`View/content_view.swift:855-862`, `:931-939`); adding is now toolbar-only. `AddActionButton` (`View/content_view.swift:1470`) is therefore **dead code**.

`onMove` is at `View/content_view.swift:889-905` (see §6.3). `@Environment(\.editMode)` is read (`View/content_view.swift:845`) but the reorder-mode toggle itself is driven by `EditButton`/`environment(\.editMode, …)` at `View/content_view.swift:930+`, mirroring the pattern at `PlaylisList_view.swift:102`.

### 8.2 Playlists tab

`PlaylistsListView` (`:912-1014`) — a `List` of `NavigationLink` → `PlaylistDetailView`, each with a context menu offering Set/Change Artwork, Remove Artwork (only if set), rename, and Delete.

**All playlists are `NavigationLink`s into a `NavigationStack` inside a `TabView` page** (`View/content_view.swift:47-68`). Navigating to a playlist therefore switches the toolbar's leading/centre content, and the bottom bar is still shown unless `libraryFilter == .player`.

### 8.3 Playlist detail

`PlaylistDetailView` (`PlaylisList_view.swift:4-220`). This is the most state-heavy view in the app: **11 `@Binding`s** (`:8-13`, plus `:16-21`) threading presentation state from `ContentView` down into `PlaylistAudioFileButton` (`:210-291`) — rename alerts, share sheets, artwork targets, multi-select, and three batch dialogs. It is also the only place a row has a `.swipeActions` (`:70-78`) offering a destructive "Remove" (remove-from-playlist only; the destructive "Delete Permanently" is context-menu-only, at `:359-363`).

Its empty state (`:33-46`) is a 60 pt `music.note.list` glyph plus *"This playlist is empty / Go to Songs view and use the context menu to add songs here"*.

Two bugs:

> **`playlistSongs` is a computed property that does a linear resolve per row.** `audioManager.getAudioFiles(for: playlist)` (`PlaylisList_view.swift:23-38`) is called from `body`, and `ForEach(playlistSongs)` re-invokes it — the value is used **7 times** in `body`. `getAudioFiles` now goes through the service's `[UUID: AudioFile]` index, so each call is O(m) rather than O(n·m), but the *7 calls per `body` evaluation* remain. `songsByPlaylistID(for:)` is the shape that fixes it properly — `AlbumDetailView` and `AlbumsListView` both use it; this view still does not.
>
> **It read `audioManager.playlists.filter { $0.id != playlist.id }` for the "Add to Another Playlist" menu** and called `addAudioFile` in a `ForEach` over the *selected IDs* (a `Set`) — so batch-add did one full `savePlaylists()` per song, i.e. N JSON encodes of the whole collection array, **in a non-deterministic order**. Both are now fixed: the target list is `transferTargets` (playlists + albums, minus self) and the iteration is `selectedSongsInPlaylistOrder`. ⚠️ **The N-encodes-per-song cost is unchanged** — only the order and the reachability of albums were wrong.
>
> The single-file context menu (`:358-375`) was also fixed to read `sortedPlaylists`/`sortedAlbums` instead of the raw `manager.playlists` array, which had been exposing the **master playlist** as a batch-add destination named `__MASTER_SONGS__`.

### 8.4 Context menus, side by side

There are **three** near-duplicate context-menu views:

| View | Line | Used by |
|---|---|---|
| `AudioFileContextMenu` | `View/content_view.swift:1601-1660` | Songs tab |
| `PlaylistAudioFileContextMenu` | `PlaylisList_view.swift:329-385` | Playlist detail, single selection |
| `PlaylistMultiSelectContextMenu` | `PlaylisList_view.swift:305-341` | Playlist detail, multi selection |

`PlaylistMultiSelectContextMenu` takes `selectedFileIDs: Set<UUID>` **by value** (`:282`) and the enclosing view already filters its options to selected rows (`PlaylisList_view.swift:262-263`), so the copy is intentional.

The playlist-detail versions use **lowercase, inconsistent labels** — `"share this file"`, `"rename"`, `"Remove from '\(playlist.name)'"` (`:328, 342, 355`) — while the Songs-tab version capitalises. The screenshots in the app will show both conventions. Every "Add to Another Playlist" submenu is a `ForEach` over *other* collections and is **empty if you have no other playlist or album**, with no disabled/empty state.

### 8.5 `MiniPlayerBar`

`View/content_view.swift:1091-1196`, shown when `audioManager.currentlyPlayingID != nil && !isMultiSelectMode` (`PlaylisList_view.swift:106`). `progressPercentage` (`View/content_view.swift:1186`) maps `currentTime / duration`. It appears in `PlaylistDetailView` but is not referenced from `SongsListView` in the excerpted range — check before assuming both tabs have one.

### 8.6 Albums — `View/Album_view.swift`

`AlbumsListView` (`View/Album_view.swift:37-154`) is a `LazyVGrid` of three `GridItem(.flexible(), spacing: 12)` columns, one `NavigationLink` → `AlbumDetailView` per cell. `albumsPage` (`View/content_view.swift:208-230`) is a `ZStack` that swaps in `EmptyAlbumView` when `sortedAlbums.isEmpty`, mirroring the Playlists page. There is **no** separate songs/plural listing, no sorting or grouping — albums are ordered by the shared `sortedCollections` newest-first rule.

`AlbumGridCell` (`:158-187`) is the only cell: `AlbumCoverThumbnail` above a `VStack(alignment: .leading)` of name, then **`artist` if set, else the song count**. The whole cell is one tap target; the cover alone is not separately tappable on this page.

`AlbumDetailView` (`:191-563`) deliberately does **not** reuse `PlaylistDetailView`, because the presentation is different enough that forcing a shared body would mean more `if` branches than shared layout:

| | `PlaylistDetailView` | `AlbumDetailView` |
|---|---|---|
| container | `List` | `ScrollView` + `VStack` (the header scrolls away) |
| header | none | square cover, editable title, editable artist, "*n* songs · *m:ss*" |
| navigation title | album name | `""` (`.navigationBarTitleDisplayMode(.inline)`) so the bar holds only the back button |
| rows | `AudioFileRow` | `PlaylistAudioFileButton` + `trackNumber` |

> **The inline empty navigation title is load-bearing, not cosmetic.** The title is rendered as `.title2` in the header, and SwiftUI's large-title mode reserves its own vertical space. With both, the album name appears twice on open. The header's `Text` carries `.accessibilityAddTraits(.isHeader)` so VoiceOver still announces the album name as the screen title.

**Track numbers are positional, not stored.** `AlbumGridCell`/`AlbumDetailView` pass `trackNumber: index + 1` from the `ForEach` over the resolved `albumSongs`, which is `audioFileIDs.compactMap { index[$0] }` — the array order (§2.2). Reordering mutates `audioFileIDs` and the numbers renumber themselves. Consequences worth knowing:

- A **dangling id is skipped silently**, so a gap in the track numbers is possible if membership and the library ever disagree (§2.2). `displayedSongs` is filtered, so **a hidden song still occupies its track number** — deliberate, since track numbers describe the album, not the current search.
- `.onMove` reuses `PlaylistService.updatePlaylistOrder(_:with:)` (`:146-155`), which writes the ids back **and** rebuilds `playbackQueue`. This is the correct primitive, and it is the one the pre-existing `PlaylistDetailView` reorder path does *not* use (§6.2).

`AddSongsToAlbumSheet` (`:567-655`) lists `displayedSongs` minus current members, with All/Add-N multi-select. It iterates the **filtered candidate list**, not the `Set` of selected ids, so the insertion order is deterministic; the same fix was applied to `AlbumDetailView`'s three batch dialogs. ⚠️ `Add N` still calls `addAudioFile` once per song, and each call is a full `savePlaylists()` (§5) — N JSON encodes of the whole collection array for N songs.

`AlbumCoverThumbnail` (`:9-33`) is the shared cover renderer for both pages: an accent-tinted `square.stack` placeholder, or the image at `.aspectRatio(1, contentMode: .fit)` with a rounded clip. It takes a `UIImage?` and does **no loading** — the caller resolves it via `ArtworkService.loadArtworkImage` (§7).

> **`View/Album_view.swift` is not in the committed Xcode target.** `Punches3.xcodeproj/project.pbxproj` lists only a handful of `View/` and `Services/` files in its Sources phase (see [03](03-project-structure-and-build.md)), so a fresh clone does not build the real app and this new file is not in it either. It has to be added to the target in Xcode, or the project fixed.

---

## 9. Change checklist

| If you change… | Re-verify |
|---|---|
| `AudioFile`'s stored properties | both inits (`:15-22`, `:24-31`); the Codable path needs no change but the display-name fallback disagrees with the import path (§2.1) |
| **`Playlist`'s stored properties** | **the hand-written `init(from:)` — a new field **must** use `decodeIfPresent(…) ?? default`, or every user playlist and album is deleted on next launch (§2.2, §3.1). This is the single most dangerous edit in the codebase** |
| `Playlist`'s `isAlbum` | `sortedPlaylists` and `sortedAlbums` both filter on it (§3.2); every "other collections" list must union both pages or albums become unreachable as batch-add targets |
| `masterPlaylistID` handling | `loadOrCreateMasterPlaylist` (`:93-115`) and `clearZombiePlaylists` (`:87-91`) — the reset path deletes user playlists **and albums** |
| `sortedAudioFiles` (`:11-20`) | it *discards* the manual order by sorting on `dateAdded`; every caller that reassigns `displayedSongs` inherits that |
| `deletePlaylist` | the master guard is now an explicit `guard playlist.id != masterPlaylistID` (§3.2) — don't rely on the filter again |
| `playlistsPage`'s empty-state check | already fixed to `sortedPlaylists.isEmpty`; `albumsPage` uses `sortedAlbums.isEmpty`. Neither is filter-aware (§3.4) |
| `filteredSongs` / `filteredPlaylists` / `filteredAlbums` | they filter but the empty states don't (§3.4) — searching with no matches shows a blank page with no message |
| `cleanupOrphanedFiles` | the `"Artwork"` literal exemption and the fact it runs on every launch after imports |
| `savePlaylists` | every call is a full encode into `UserDefaults` with no queue or coalescing; the `createPlaylist` stale-snapshot race is fixed (§5) but the N-encodes-per-batch-add cost is not |
| `reorderPlaylistSongs`'s `main.async` | the captured `index` (`:100`) can target a different collection after any concurrent mutation — `AlbumDetailView` uses `updatePlaylistOrder` instead |
| `PlaylistDetailView.playlistSongs` | it is a computed property evaluated 7× per `body`; `songsByPlaylistID` is the fix and the Albums grid already uses it (§2.2, §8.6) |
| `ArtworkService.loadArtworkImage` | now `NSCache`-backed, but first load is still a synchronous read inside `body` (§7) |
| `coverIsManual` | `coverName(for:songs:)` is the only reader and `setArtwork`/`removeArtwork` the only writers (§7.1); a legacy cover needs the third fallback line or it disappears |
| `LibraryItem` | delete it, or wire it up — it has zero references |
