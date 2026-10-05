# 08 — Playlists & Library

> `AudioFile`/`Playlist`, the hidden `__MASTER_SONGS__` playlist that *is* the Songs tab, `AudioLibraryService`, `PlaylistService`, `ArtworkService`, and the Songs/Playlists/Albums/Playlist-Detail views.
> Companion: [12-persistence-and-keys.md](12-persistence-and-keys.md) (the on-disk schema), [09-file-import-and-sharing.md](09-file-import-and-sharing.md) (how files get in), [04-audio-pipeline.md](04-audio-pipeline.md) (what `playbackQueue` drives).

> **Albums are playlists.** There is no `Album` type, no `AlbumService`, and no `albums` array. An album is a `Playlist` with `isAlbum == true`, rendered on its own page with a cover-first layout. Everything in §3–§7 applies to albums unchanged; §8.6 covers only what is different about the presentation.

---

## 1. Files

| File | Lines | Role |
|---|---|---|
| `Models.swift` | 297 | all four model types |
| `Services/AudioLibraryService.swift` | 129 | the `audioFiles` array + filesystem reconciliation |
| `Services/PlaylistService.swift` | 407 | the `playlists` array + the master playlist |
| `Services/TagAlbumProjector.swift` | 462 | derived albums — **§5.1** |
| `Services/ArtworkService.swift` | 147 | artwork files, refcounted by name, now with an image cache |
| `View/PlaylisList_view.swift` | 379 | `PlaylistDetailView` + its 3 context menus (note the typo'd filename) |
| `View/Album_view.swift` | 828 | `AlbumsListView`, `AlbumDetailView`, `AlbumGridCell`, `AddSongsToAlbumSheet`, `EmptyAlbumView` |
| `View/content_view.swift` | 1886 | `SongsListView` (`:910`), `PlaylistsListView` (`:1050`), `playlistsPage` (`:179`), `albumsPage` (`:207`), `songsPage` (`:235`), `MiniPlayerBar` (`:1154`), `AudioFileRow` (`:1625`) |

All three long-lived services are constructed once by `AudioManager` and hold it **`unowned`**:

```swift
// AudioLibraryService.swift:12 / PlaylistService.swift:6 / ArtworkService.swift:5
unowned let manager: AudioManager
```

`TagAlbumProjector` deliberately does **not**: it is created per run and given the manager strongly, because it is not owned by `AudioManager` as a stored property — `refreshTagAlbums()` builds one, uses it, and drops it. A projector that outlived the run would keep a whole library snapshot alive for nothing.

`unowned` is a retain-cycle break, and it means **`manager` is a dangling reference the moment `AudioManager` deallocates.** These are singletons in practice, but any code that lets a service outlive its manager will crash on the next property access rather than cleanly no-op.

---

## 2. Models (`Models.swift`)

### 2.1 `AudioFile`

```swift
// Models.swift:3
struct AudioFile: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let dateAdded: Date
    let audioDuration: Float
    var artworkImageName: String?
    var title: String

    // MARK: Metadata — every one optional, read from the file's own tags
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?

    var fileURL: URL { AudioManager.fileDirectory.appendingPathComponent(fileName) }
}
```

Only `id`, `fileName` and `dateAdded` are `let`; everything else is `var`. **Mutating a `let`-backed field is impossible**, which is why every artwork/title/tag change rebuilds the whole struct via the 16-argument `init` instead of assigning a field. `ArtworkService.setArtwork(_:for:)`, `removeArtwork(from:)`, `LibraryStore.applyTags` and `AudioLibraryService.renameAudioFile(_:to:)` all do this.

**Ten tag fields, all `String?`/`Int?`, and the `nil`-vs-`""` distinction is load-bearing.** A file need not be tagged, and "the user typed an empty artist" is a different thing from "nobody ever asked" — a file with no artist and a file with an empty artist must not collapse into one row in the projector (§5.1). The comment in the source says so; the reason it is not enforced by a type is that the tag reader has to stay cheap enough to run on every import.

Two initialisers:

| Init | Used by | `title` behaviour |
|---|---|---|
| `init(fileName:audioDuration:artworkImageName:)` (`:42`) | the **import** path, and the picker's "add a library file" path | `title = Self.title(from: fileName)` |
| `init(id:fileName:dateAdded:audioDuration:artworkImageName:title:…)` (`:51`, 16 arguments) | the **Codable** path and every mutation | `title = title ?? Self.title(from: fileName)` |

> **The two `title` fallbacks now agree**, which they used not to: both route through the one private `static func title(from:)` (`:38`). It used to be `(fileName as NSString).deletingPathExtension` in the import init and bare `fileName` in the other, so importing `song.mp3` gave `"song"` and any other path gave `"song.mp3"`. That inconsistency was latent rather than live — a non-optional `String` makes synthesised `Codable` **throw** on a missing `title` rather than passing `nil`, so `?? fileName` was unreachable — but it would have woken up the moment the schema moved off JSON. There is now exactly one place to change it.

> `audioDuration` is a `Float`, and `fileURL` and `title` are **computed**. `Float` is not a `Codable` primitive that round-trips losslessly through every encoder path, and there is no validation on decode — a corrupt value yields `NaN`, which then makes the `timeSlider` range `0...max(NaN, 0.01)` (see [07](07-meters-and-hud.md#43-timeslider-138-170)). Consider `Double` or a `decode` guard.

### 2.2 `Playlist`

```swift
// Models.swift:144
struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var audioFileIDs: [UUID]
    let dateAdded: Date
    var artworkImageName: String?
    var isAlbum: Bool
    var coverIsManual: Bool
    var artist: String?
    var sortOrder: Double?     // schema v3
    var tagKey: String?        // schema v3
}
```

The last three fields are what make an album. `isAlbum` routes the record to the Albums page; `artist` is album-level metadata that is **not** derived from member songs; `coverIsManual` records whether `artworkImageName` is a user choice or just the first member song's artwork (see §8.6).

The two nullable fields are separate concerns, and **neither of them means "album"**:

- **`sortOrder`** is the user's position on its page. `nil` means the page has never been arranged. Nullable because "never arranged" and "arranged, currently first" are different states, and collapsing the second onto the first would rearrange every untouched page the next time any one of them was dragged. Only `moveCollection(in:from:to:)` writes it, and only for the page it was handed (§5).
- **`tagKey`** marks the row as a **projection of a group of file tags** rather than something the user built. `nil` — the ordinary case — is what tells `TagAlbumProjector` it has no business rewriting it. It is opaque, not a readable tag: `"<tag>\u{1F}<normalised value>"`, and only the projector decodes it (§5.1). A hand-made album has `tagKey == nil` forever.

`init(name:artworkImageName:isAlbum:artist:tagKey:)` is the convenience initialiser. The designated one takes every field, including the two new nullable ones, **with no defaults** — deliberately, so a new call site cannot silently forget one. The Codable path is hand-written.

**`Playlist` has a hand-written `init(from:)` — this is load-bearing, not boilerplate.**

```swift
// Models.swift:225
enum CodingKeys: String, CodingKey {
    case id, name, audioFileIDs, dateAdded, artworkImageName
    case isAlbum, coverIsManual, artist
    case sortOrder, tagKey
}
```

Every key the app added after launch 1 uses `decodeIfPresent(…) ?? default`. The reason is §3.1: `loadOrCreateMasterPlaylist` catches any throw from the decode and calls `clearZombiePlaylists()`, which **writes back an array containing only the master playlist — deleting every user playlist and album**. Synthesised `Codable` throws on a missing non-optional key, so *adding any required field to `Playlist` silently wipes user data on the next launch.* If you add a field here, it goes in `decodeIfPresent` with a default, and the checklist in §9 is not optional.

`audioFileIDs` also uses `decodeIfPresent … ?? []` even though it is non-optional, which is harmless and slightly more tolerant than synthesis. `sortOrder` and `tagKey` follow the same shape with `?? nil`, which is what lets a blob written before schema v3 decode at all — and an *unset* value is omitted from the encoded form rather than written as `0`.

> Adding `artist` to **`AudioFile`** instead would be the genuinely dangerous version of this: `AudioFile` decode failure routes into `AudioLibraryService`'s reconciliation, which deletes files that are not on disk. The reason album artists cannot be read per-song is not that it was avoided here — it is that this codebase has no embedded-metadata reader at all. See [12](12-persistence-and-keys.md).

**Membership is stored as `[UUID]`, not as embedded `AudioFile`s.** Consequences:

- `getAudioFiles(for:)` (`PlaylistService.swift:403-406`) is now **one dictionary lookup per id** off the service's shared `[UUID: AudioFile]` index, rather than the `manager.audioFiles.first { $0.id == id }` scan it used to do. It is still called from `PlaylistDetailView.playlistSongs` (`View/PlaylisList_view.swift:24`), which is a **computed property read inside `body`** and is evaluated 7× per `body` pass.
- **`songsByPlaylistID(for:)` (`PlaylistService.swift:79-90`) is the shape that fixes it properly**, and it is what the Albums grid uses: it builds one `[UUID: AudioFile]` index of the library, then one dictionary entry per collection, so resolving N collections costs one pass over the library instead of N. Converting `PlaylistDetailView` to it is still open (§9).
- **Dangling IDs are silently dropped** by `compactMap`. Deleting a song scrubs the IDs eagerly (`AudioLibraryService`), so this only leaks if that scrub is bypassed.
- **Order is meaningful** — `audioFileIDs` order *is* the playlist's manual sort order, and it is also the album's **track number**. `reorderPlaylistSongs` and `reorderSelectedSongs` both rely on it, and `AlbumDetailView`'s numbered rows read it directly.
- **Duplicates are prevented within one call, not across two.** `addAudioFiles(_:to:)` seeds a `Set` from the current members, so appending N songs to an album of M is **O(N + M)** rather than O(N × M) — and `inserted` is what makes it idempotent. But `AddSongsToAlbumSheet` and the batch dialogs each re-read `playlist` from the view's copy, so two rapid adds that overlap in a single run-loop pass can still each see a stale value and both append. The window is narrow and the cost is a duplicated track number; not fixed.
- **A derived album's order is a hybrid** — retained songs keep their positions, genuinely new ones append in tag order (§5.1). That is why `TagAlbumProjector` must merge rather than rebuild.

### 2.3 `LibraryFilter` and `LibraryItem`

```swift
// Models.swift:254
enum LibraryFilter: Hashable { case songs, playlists, albums, player }
```

Live: it is the `TabView(selection:)` tag for the four-page `TabView` in `View/content_view.swift`, driven by `@State private var libraryFilter: LibraryFilter = .songs` (`:10`). Only `.player` hides the bottom bar. `.albums` sits **between** Playlists and Songs, with a `square.stack` glyph.

`case albums` has no default value and no `Hashable` concern, but note that `switch` statements over `LibraryFilter` elsewhere must be exhaustive — adding a case is a compile error at every such site, which is the intended safety net.

```swift
// Models.swift:261
enum LibraryItem: Identifiable { case song(AudioFile); case playlist(Playlist) /* + id, dateAdded */ }
```

**`LibraryItem` is entirely unused** — the only occurrence in the whole repo is its own declaration. It is the vestige of a unified-library design that shipped as two separate lists. Both `id` and `dateAdded` are implemented, so it looks live; it isn't. Safe to delete.

### 2.4 `ArtworkTarget`

```swift
// Models.swift:281
enum ArtworkTarget: Identifiable {
    case audioFile(AudioFile)
    case playlist(Playlist)
    case multipleFiles(Set<UUID>)
}
```

`Identifiable` is required for `.sheet(item:)`. Note the `id` for `.multipleFiles` is `"multiple-" + ids.sorted().map { $0.uuidString }.joined()` (`:292`) — **sorted**, so the identity is order-independent, which is correct for a `Set`. But it means a 50-file selection produces a ~1850-character id string rebuilt on every `body` evaluation. Harmless, wasteful.

---

## 3. The master playlist — the most important thing in this document

**The Songs tab is a playlist.** There is no separate "all songs" store. `PlaylistService.loadOrCreateMasterPlaylist()` (`:175-208`) ensures one exists, named:

```swift
// Services/PlaylistService.swift:180
let fresh = Playlist(name: "__MASTER_SONGS__")
```

Its `id` lives in the **`meta` table**, as a bare UUID string rather than as `Data` (`LibraryStore.loadMasterPlaylistID` `:526`). The `UserDefaults` blob is kept only as a *legacy read* (`loadLegacyMasterID()` `:141-144`) so a store that opens with no master row can still adopt the id an older build wrote.

### 3.1 Lifecycle (called once, from `AudioManager.init`)

`audio_manager.swift:112-114`, **synchronously**, so the first frame is not empty:

```swift
libraryService.loadAudioFiles()                    // :112  — [TrackRecord] from SQLite
playlistService.loadPlaylists()                    // :113  — [PlaylistRecord] → [Playlist]
playlistService.loadOrCreateMasterPlaylist()       // :114  — resolve or create the master
```

The same three run again inside `prepareLibrary` (`:154-156`) after the environment resolves, in case the store was not ready on the first pass.

`loadOrCreateMasterPlaylist` is **two** branches, not three:

| Condition | Action |
|---|---|
| `masterPlaylistID` is set **and** names a playlist that exists | adopt it; go straight to membership repair |
| otherwise | create a fresh master, **leave every existing playlist alone**, then membership repair |

**`clearZombiePlaylists()` no longer exists, and its removal is the single most important thing in this section.** It used to be nuclear: wipe `manager.playlists`, save the empty array, remove the master key — and it ran whenever the stored id failed to resolve, *including on an unrelated decode failure*. The user's playlists were rebuilt as empty shells and the next `savePlaylists()` overwrote the old blob permanently. A missing master is a one-row problem, so it is now repaired as one.

Membership repair (`:190-207`) is the second half, and it is a separate concern with a separate trigger: `expected` is every `audioFiles` id, `present` is the master's, and if they differ the master is **reconciled** — dangling ids dropped, missing ids appended — then saved. This is the self-heal for "the file is on disk but not in the app", which was the largest single cause of it.

> **The save is conditional on the *repair*, not on the *creation*, and that is deliberate.** The membership repair originally saved only when it changed something — which meant a freshly created master on an empty library had no members, there were no tracks, `present == expected`, the guard returned early, and **the master row never reached the database at all**. `manager.masterPlaylistID` then named a playlist existing only in memory, and the *first import on a brand-new install* failed to add a membership row for it. The fix keeps membership repair conditional (it has nothing to do when the sets already agree) and drives the save off `createdMaster` instead. The 22-line doc comment above the function is the clearest statement in this file of why both halves are shaped the way they are.

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
// Services/PlaylistService.swift:23-70
var sortedPlaylists: [Playlist] {
    ordered(unmasteredCollections.filter { !$0.isAlbum })
}
var sortedAlbums: [Playlist] {
    ordered(unmasteredCollections.filter { $0.isAlbum })
}

/// Every user collection except the master, in the order both pages render it.
private var unmasteredCollections: [Playlist] {
    manager.playlists.filter { $0.id != manager.masterPlaylistID }
}

/// Manual position first, then newest first.
private func ordered(_ collections: [Playlist]) -> [Playlist] {
    collections.sorted { lhs, rhs in
        switch (lhs.sortOrder, rhs.sortOrder) {
        case let (left?, right?) where left != right:
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.dateAdded > rhs.dateAdded
        }
    }
}
```

`unmasteredCollections` is `private` so the exclusion cannot drift between the two pages, and it is deliberately left **un**ordered. **Each page slices and then orders itself**, which is the point: the previous shape sorted one shared array, so a position written on the Albums page would have shuffled the Playlists page too. Only albums are currently arranged (§5.1), and Playlists keeps the newest-first behaviour it has always had.

`ordered(_:)` is a **total order**, so its answer is well defined: position where both sides have one and it differs, then the nil/non-nil split, then `dateAdded`. Unpositioned rows sort *after* positioned ones rather than interleaving by date — a half-arranged page is a transient state (one drag assigns the whole page), and interleaving would make the not-yet-dragged remainder leap around as positions fill in. A page the user has never touched therefore renders exactly as it did before `sort_order` existed.

Three consequences to respect:

1. **`deletePlaylist(_:)` (`PlaylistService.swift:310`) guards the master by id** — `guard playlist.id != manager.masterPlaylistID`. It used to have *no* guard and was safe only because the filter hid the row; any new call site that passes a playlist from `manager.playlists` directly would previously have deleted the master and triggered the nuclear reset on next launch.
2. **The Playlists tab's empty state is no longer a magic number** — `View/content_view.swift:182` was `audioManager.playlists.count == 1`, which assumed `count == 1` ⟺ "only the master exists" and lied if the master were ever missing. It is now `audioManager.sortedPlaylists.isEmpty`, and `albumsPage` uses `audioManager.sortedAlbums.isEmpty`.
3. **A new collection lands at the end of an arranged page, not the top.** `sortOrder == nil` for anything created outside `moveCollection`, and `ordered(_:)` puts nil after every position. A newly created album appearing after the ones the user arranged is the correct reading: it has not been placed.

### 3.3 Four orderings of the same data

There is no single order for "the songs". Four arrays hold one, and only one of them is the user's:

| Accessor | Source | Sort | Used by | Preserves manual order? |
|---|---|---|---|---|
| `manager.audioFiles` | `[TrackRecord]` from SQLite, mapped `\.audioFile` (`AudioLibraryService.swift:23-27`) | **none — never sorted**; SQLite returns rows in whatever order the query plans | the **player's default song**, and what `saveAudioFiles` persists | n/a |
| `PlaylistService.sortedAudioFiles` (`:12-21`) | `masterPlaylist.audioFileIDs` → resolved, **falling back to `audioFiles` sorted by `dateAdded` desc if the master is missing** (`:14-16`) | `dateAdded` desc — **re-sorts and discards the manual order** (`:20`) | `displayedSongs` on init, after delete/rename/import | **no** |
| `manager.displayedSongs` | mutable snapshot of the above | as set | the Songs tab | yes, until the next recompute |
| `manager.playbackQueue` | copied from whichever of the above produced the play action | as copied | next/previous, auto-advance | yes, until the next play |

Two distinct bugs fall out of this table:

**The player opens on the oldest song.** The Songs tab renders `displayedSongs`, which is newest-first. The player reads `audioManager.audioFiles.first` — a raw array nothing ever sorts, whose order is now **whatever SQLite's query plan returns**, which is not even the old append order and is not something to reason about. That is [14 · C13](14-known-issues.md#c13-the-app-opens-on-the-oldest-import-not-the-top-of-the-list).

**The manual order is persisted and then ignored.** `reorderSongs` (`PlaylistService.swift:210-223`) writes the new order into `masterPlaylist.audioFileIDs` and saves it. `sortedAudioFiles` then re-sorts what it just read:

```swift
// Services/PlaylistService.swift:18-20
return masterPlaylist.audioFileIDs
    .compactMap { id in manager.audioFiles.first { $0.id == id } }
    .sorted { $0.dateAdded > $1.dateAdded }     // ← throws the manual order away
```

So the reorder *looks* correct on screen, and reverts the next time anything recomputes `displayedSongs = sortedAudioFiles` — import, delete, rename, artwork change, `reorderSelectedSongs`, or the next `init`. That is [14 · C14](14-known-issues.md#c14-manual-sort-order-is-silently-discarded).

**The one thing that does preserve it** is `reorderSongs`'s direct mutation:

```swift
manager.displayedSongs.move(fromOffsets: source, toOffset: destination)   // :211
...
manager.playlists[index].audioFileIDs = reorderedIDs                      // :217
savePlaylists()                                                          // :218
if manager.playingFromSongsTab { manager.playbackQueue = manager.displayedSongs }   // :220-222
```

⚠️ Note that `reorderSongs` and `reorderPlaylistSongs` (§6.2) now differ only in *semantics*, not in safety. Both find their target index before mutating, both write back synchronously, and both rebuild `playbackQueue` — under opposite `playingFromSongsTab` guards. `reorderSongs` writes the **master** playlist; `reorderPlaylistSongs` writes the **named** one.

Import a single new file and your entire hand-sorted Songs list reverts to newest-first. That is a real, user-visible bug class, not a hypothetical.

> **The decision to make first:** is manual order or date order the intent? If manual, drop the `.sorted` on `PlaylistService.swift:20` and append new imports to the end of `audioFileIDs`. If date order, remove the reorder affordance rather than accepting an order that is discarded. Everything above is a consequence of that answer being deferred — including [C4](14-known-issues.md#c4-reordering-does-not-update-playbackqueue) and [C5](14-known-issues.md#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop), which are the queue-side and capture-side versions of the same split.

2. **Every "other collections" list must union both pages.** Albums and playlists are one array, so a list that filters to one page silently makes the other unreachable as a target. Three different shapes are in use, and all three are correct as long as the union is present:
   - **Single unioned list** — `PlaylistDetailView.transferTargets` (`View/PlaylisList_view.swift:29`) and `AlbumDetailView.transferTargets(excluding:)` (`View/Album_view.swift:680`) are `sortedPlaylists + sortedAlbums` minus the current collection. One dialog, every destination.
   - **Two labelled submenus** — `PlaylistAudioFileContextMenu` (`View/PlaylisList_view.swift:360`, `:367`) and `AudioFileContextMenu` (`View/content_view.swift:1780`, `:1795`) split into *"Add to Another Playlist"* and *"Add to Album"*, each with its own `ForEach`. Arguably better for discovery than one undifferentiated list.
   - ⚠️ The concatenation is **all playlists then all albums**, newest-first within each — not one newest-first list. If a merged dialog ever looks out of order, this is why.

   The failure mode to watch for is the pre-existing one this feature is vulnerable to: any list written as `manager.playlists.filter { $0.id != current.id }` includes albums *and* the master playlist, while `sortedPlaylists` alone excludes albums. Both wrong in different directions.

### 3.4 Search

```swift
// View/content_view.swift:274
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
var filteredAlbums: [Playlist] {                    // :286
    let base = audioManager.sortedAlbums
    if searchText.isEmpty { return base }
    return base.filter {
        $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
}
```

All three are **computed properties, not `@State`** — the full array is re-filtered on every `body` evaluation, on every tab, on every keystroke, and on every `audioManager` publish. Albums match on **title or artist**, because "beatles" should find the album. And critically:

> **⚠️ Search empty states remain broken.** `filteredSongs` filters `displayedSongs` (the manual order) but `songsPage`'s empty-state check uses `audioManager.audioFiles.isEmpty` — the *unfiltered* array. So with a search active and no matches, the user sees an **empty `List` with no empty-state message and no "no results" affordance.** The playlist and album pages use the correct unfiltered test for *whether the page is empty at all*, which is the right call — but it means the three pages now have three different empty-state semantics: "library is empty" for one, "filter matched nothing" for none.

---

## 4. `AudioLibraryService` — the files array

129 lines, and every one of them is either a load, a save, or a deletion. It no longer touches the filesystem for reconciliation — that moved to `LibraryReconciler` when the SQLite layer landed.

### 4.1 `loadAudioFiles()` — SQLite, with a read-only legacy fallback

```swift
// Services/AudioLibraryService.swift:22-41
func loadAudioFiles() {
    if let store {
        let records = (try? store.loadTracks()) ?? []
        manager.audioFiles = records.map(\.audioFile)
        return
    }
    // …UserDefaults fallback, lossyDecode, then fileExists filter
}
```

**The fallback exists so a store failure degrades to a stale read instead of an empty library.** If the database cannot be opened, the app still shows the `UserDefaults` JSON from the pre-SQLite era rather than claiming the user has no songs. The comment is emphatic about what it must *not* do: **never write back to `UserDefaults` in that state**, because two writers to the same key is exactly how the old all-or-nothing write lost data. `lossyDecode` is what makes the read safe — a single un-decodable row must not lose the other 4,999.

The `fileExists` filter in the fallback branch is the historical behaviour and is still worth naming: a record whose bytes are gone is **dropped from the array but not scrubbed from `UserDefaults` or from any playlist**, so it is re-checked and re-dropped on every launch until something writes. That asymmetry is the old [14](14-known-issues.md) C-series defect, and it only survives on this fallback path.

### 4.2 `deleteAudioFile(_:)` — row first, then bytes

```swift
// Services/AudioLibraryService.swift
```
1. capture the **successor** — the track after this one in `playbackQueue`, if this is the current track
2. `if currentlyPlayingID == audioFile.id { manager.stop() }`
3. drop it from `audioFiles`, from **every** playlist's `audioFileIDs`, and from `playbackQueue`
4. `saveAudioFiles()` — **one** `persist`, not three saves
5. `reconciler.moveToTrash(audioFile.fileURL, reason: "deleted")`
6. `deleteArtworkIfUnused`
7. `displayedSongs = sortedAudioFiles` — **re-sorts, destroying the manual order (§3.3)**
8. `playbackService.handover(to: successor)` — see below

**The order of 4 and 5 is the whole point, and it is inverted from the obvious one.** The row is written before the bytes are moved. If the move fails, the reconciler finds an untracked file and picks it up on the next pass; if the row write fails, the bytes are still in `Trash/` and recoverable. Doing it the other way round — delete the file, then fail to write the row — leaves a library row pointing at nothing with no way back. `try?` on the move is deliberate and commented as such: the bytes are already gone from the library's point of view, so a failure is not worth interrupting the user for.

**Step 1 and 8 are the queue-integrity half.** Deleting the track you are on used to leave *no* current track: `stop()` cleared `currentlyPlayingID`, and the next tap of Play started from `playbackQueue.first` — so deleting the fifth song of twelve rewound you to song one. The successor is now captured before the removal (afterwards the deleted track's index no longer exists) and handed to `AudioPlaybackService.handover(to:)`, which loads it **at whatever play/pause state you were in** rather than forcing a track on you. `isLooping` is deliberately not consulted: loop decides what happens when a track *ends*, and this one is being removed while you are looking at it.

The `displayedSongs` reset at `:97` happens **after** step 2 scrubbed the id, so unlike the old ordering it no longer reads a dangling ID — but it still re-sorts, which is the remaining defect in this function.

With no reconciler available (no store, no environment) it falls back to a bare `FileManager.removeItem`, which is genuinely unrecoverable. That is the same degraded mode as §4.1, and it is the only path in the app that can delete bytes permanently.

### 4.3 What replaced `cleanupOrphanedFiles()`

`cleanupOrphanedFiles` and `generateUniqueFileName` **no longer exist.** Both were deleted with the filesystem-era import pipeline, and the doc comments in `LibraryReconciler`, `LibraryEnvironment`, `LibraryMigration` and `LibraryImportPipeline` all name them as the things they were written to fix. Do not go looking for them; the history is in [09](09-file-import-and-sharing.md) and in those comments.

The one-line version:

| Was | Now |
|---|---|
| `cleanupOrphanedFiles()` — a blanket `rm` of the tracks directory keyed on "is it in `audioFiles`?", skipping the literal `"Artwork"`, `try?`-ing every failure, running on every launch after imports | `LibraryReconciler.reconcile()` — **move-only**. Untracked files go to `Trash/`, never to the void, and `reclaimUntrackedFiles` / `reclaimStagedFiles` are separate passes with separate rules |
| `generateUniqueFileName(for:)` — a `while true` stat probe | handled inside `LibraryImportPipeline`, which stages first and commits by id, so two imports of `song.mp3` cannot collide at all |

The old `AudioManager.fileDirectory` fallback that made the blanket delete dangerous — group container when the entitlement exists, otherwise the **Documents root** — is also gone. It is now always `LibraryEnvironment.shared.tracks`, a directory this app owns. The comment on the property says why, in as many words.

### 4.4 `renameAudioFile(_:to:)`

`Services/AudioLibraryService.swift:102-111`. **Renames the title only, not the file**, and that is now documented rather than surprising: `fileName` is an opaque on-disk name and `title` is display metadata. The new value is not validated, so it may contain `/` or NUL — harmless precisely because it never touches the path.

It mutates a **copy in place** (`var updated = audioFile; updated.title = newTitle`) rather than calling the 16-argument init. Every artwork mutation does the same, and the reason is written in `ArtworkService.setArtwork(_:for:)`: rebuilding means restating every field, and any field added later is silently dropped — which is exactly how the ten tag fields would have been lost every time a user picked a cover.

---

---

## 5. `PlaylistService` — mutations

Every mutator follows the same shape: `guard let index = firstIndex(where: id)`, mutate, `savePlaylists()`.

| Method | Line | Guard | Notes |
|---|---|---|---|
| `sortedPlaylists` / `sortedAlbums` | `:23`, `:27` | master id | each takes its own slice of `unmasteredCollections` **and orders it itself** — see §3.2 |
| `ordered(_:)` | `:55` | — | position first, then newest-first; private |
| `unmasteredCollections` | `:38` | master id | the filtered list, deliberately **un**ordered |
| `songsByPlaylistID(for:)` | `:79` | — | one library index → one `[UUID: [AudioFile]]` for a whole page |
| `coverName(for:songs:)` | `:92` | — | manual cover → first member song's artwork → `nil` |
| `savePlaylists()` | `:109` | — | one `LibraryStore.persist` mirror of the whole library |
| `loadPlaylists()` | `:125` | — | replaces `manager.playlists` wholesale |
| `loadOrCreateMasterPlaylist()` | `:175` | — | §3.1 |
| `reorderSongs(from:to:)` | `:210` | index | §6.1 |
| **`moveCollection(in:from:to:)`** | **`:238`** | **page is non-empty** | **renumbers the whole page densely, one save** — §5.1 |
| `reorderPlaylistSongs(in:from:to:)` | index | index | §6.2 — writes ids **and** rebuilds `playbackQueue` |
| `updatePlaylistOrder(_:with:)` | index | index | writes ids **and** rebuilds `playbackQueue` |
| `createPlaylist(name:isAlbum:artist:)` | `:291` | none | **returns the new `Playlist`** so a caller can fill it in the same turn |
| `deletePlaylist(_:)` | `:310` | master id | also `deleteArtworkIfUnused`, **and records a tag suppression** — §5.1 |
| `renamePlaylist(_:to:)` | `:324` | index | no empty-name check |
| `setArtist(_:for:)` | `:330` | index | trims; **empty/whitespace normalises to `nil`** rather than storing `""` |
| **`addAudioFiles(_:to:)`** | **`:353`** | index | **the batch primitive — one save for the whole batch** |
| `addAudioFile(_:to:)` | `:374` | index | a one-line forward to the above; **idempotent** — `if !contains` |
| **`removeAudioFiles(_:from:)`** | **`:384`** | index | **the batch primitive** |
| `removeAudioFile(_:from:)` | `:399` | index | a one-line forward to the above |
| `getAudioFiles(for:)` | `:403` | — | an indexed resolve, not the O(n·m) scan |

> **Batch membership is one save, and the single-song methods are forwards to it.** `addAudioFiles(_:to:)` and `removeAudioFiles(_:from:)` accumulate membership and call `savePlaylists()` **once**. Every multi-select path used to be a `for` loop over the single-song methods, and `savePlaylists()` is a `LibraryStore.persist` **mirror** — upsert every track, prune, upsert every playlist, prune, in one transaction — so "add these 12 songs" performed **12 complete library mirrors**. Measured: **300 row changes for 12 songs, against 25** for the same 12 batched, with byte-identical resulting databases. The single-song methods delegate rather than duplicate, so there is no second code path to drift.

> **`createPlaylist` returns the `Playlist` it made.** It previously returned `Void`, so "new playlist from selection" had to create and then re-find the playlist to populate it. `AudioManager.createPlaylist`/`createAlbum` are plain synchronous forwards, and the redundant `DispatchQueue.main.async` both used to wrap is gone — every `AudioManager` method is already `MainActor`-isolated under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the hop was only adding a run-loop pass of latency.

> **`deletePlaylist` guards the master by id**, which is stronger than relying on `sortedPlaylists`' filter happening to exclude it. Albums and playlists share the path, so the guard is what stops an album delete from nuking the Songs tab. It also records a **tag suppression** when the album being deleted was derived (§5.1), and does so in the service rather than in the projector's own remove path so that *every* entry point gets it.

> **`savePlaylists()` has no queue and no coalescing.** One save is proportional to the whole library by design — `persist` mirrors, so a partial write is impossible — which is why the fix above is batching the *calls* rather than making each one cheaper. Making `persist` incremental would trade that guarantee for throughput, and the defect was throughput spent on redundant work, not a missing capability.

> **`addAudioFile` does not touch `displayedSongs`** — correct, since neither playlists nor albums own the Songs list. But it also does not check whether the file still exists.

> **`setArtist` writes to a playlist, not an `AudioFile`, and stores `nil` for blank input.** This is deliberate: an empty `artist` must fall back to the "Add Artist" affordance in the UI and to the song-count subtitle in the grid, and `""` would satisfy neither while still round-tripping through JSON as an empty string.

### 5.1 Two capabilities that own a field

`sort_order` and `tag_key` are each owned by exactly one piece of code, and both were added together in schema v3 because neither had shipped. Everything else about them is a consequence of that single-writer rule.

#### `moveCollection(in:from:to:)` — where an album's position comes from

```swift
// Services/PlaylistService.swift:238
func moveCollection(in page: [Playlist], from source: IndexSet, to destination: Int)
```

Renumbers the **whole page** rather than the moved rows alone: positions have to be dense and gap-free, or a later insert cannot be dropped between two albums without renumbering everything anyway. One save for the page — `savePlaylists()` mirrors the entire library, so renumbering 30 albums one call at a time would rewrite the library 30 times. A move that changes nothing returns before saving.

**The page is a parameter, not something the service looks up.** `AlbumsListView` renders `filteredAlbums` — a *search result* — so a service that discovered the page itself would write one album's position to another. The caller owns the question "which array am I looking at?"; the service owns "what does that order mean".

#### `TagAlbumProjector` — where a derived album's membership comes from

`Services/TagAlbumProjector.swift`. Builds albums from the library's own tags — **genre, album artist, decade** — and keeps them current as files are imported, retagged or removed. Not the album tag: a group of that would be one album per album, which is what the manual Albums page already does.

Runs from two places in `AudioManager`, both chosen so the work is proportional to *changes* rather than library size: after `LibraryTagSweep.run()` (the only other thing that can newly supply tags), and from `finishOneImport()` **once per completed batch** — a projector run per file would make a 200-file import do 200 full passes, each saving. It saves only if something changed.

The rules that keep it from being destructive are the design, not an afterthought:

| Rule | Mechanism |
|---|---|
| Only rows it created are ever touched | eligible **only** when `tagKey != nil`, and `tagKey` is written only here |
| A renamed derived album is found, not duplicated | matched by `tagKey`, never by name |
| A hand-made album of the same name is **not adopted** | adopting it would overwrite its contents the first time a matching file appeared |
| Deleting one sticks | the tag is recorded in `meta` under `tag_albums_suppressed`, newline-joined; keyed by **tag**, not by the album's id, which is gone |
| "Detach from Tags" hands it over | clears `tagKey` and any suppression; the album keeps its songs and becomes ordinary |
| A group with no files leaves no album | otherwise an album appears and disappears as files move, which is alarming on the Albums page |

Every one of those is expressed in terms of the single nullable field, so there is no second flag to fall out of step. The `meta` accessors are the generic `metaValue(forKey:)`/`setMetaValue(_:forKey:)` pair on `LibraryStore` — `meta` had only two hardcoded keys (the master pointer) before this and no generic accessor at all.

**Membership is hybrid, not rebuilt.** Retained songs keep their positions; genuinely new ones append in tag order. Rebuilding from the tags would revert any reorder the user made, so the app would appear to save the change and then undo it — worse than not offering the gesture. Retagged songs leave, since a derived album's contents is the library's answer. The one thing that does **not** stick is *adding* a song: it is not in the tag group, and the next run would remove it again.

**A derived album claims no `artist` field**, because that field means something else — a user-typed string. Its cell shows `Genre · rock` instead, so a derived album named "Rock" is visibly a different kind of object from a hand-made one of the same name. `TagAlbumProjector.descriptor(for:)` is the only decoder of a `tagKey`, deliberately kept off the model so nothing holding only a `Playlist` can parse one.

**Keys are `"<tag>\u{1F}<value>"`** with `U+001F`, the ASCII unit separator: not legal in a path and not meaningful in a tag value, so a genre literally named `"artist: rock"` cannot collide with an album-artist group called `"rock"`. Values are normalised — trimmed, interior whitespace collapsed, lowercased — which is what stops `"Rock"`, `"rock"` and `" rock"` becoming three one-member albums. Normalisation also guarantees no value contains a newline, which is what makes the newline-joined suppression set unambiguous without a decoder that can fail.

---

## 6. Reordering

Three entry points, all funnelling into the same array-of-UUIDs representation.

### 6.1 Single-item move, Songs tab

`PlaylistService.reorderSongs(from:to:)` (`:210-223`) — `move` on `displayedSongs`, mirror into the **master** playlist, save, and reset `playbackQueue` if playing from the Songs tab.

### 6.2 Single-item move, inside a playlist

`PlaylistService.reorderPlaylistSongs(in:from:to:)` — copies the playlist out, moves on the **local copy**, then writes back:

```swift
var updatedPlaylist = manager.playlists[index]
updatedPlaylist.audioFileIDs.move(fromOffsets: source, toOffset: destination)
manager.playlists[index] = updatedPlaylist
if !manager.playingFromSongsTab { /* rebuild playbackQueue from updatedPlaylist.audioFileIDs */ }
self.savePlaylists()
```

**This used to be wrong in two ways, both now fixed.** It hopped to `DispatchQueue.main.async` before writing, and the closure captured the **integer `index`** by value — so if any playlist was deleted, created, or reordered in that window, `index` pointed at a *different* playlist and overwrote it wholesale. And unlike its Songs-tab sibling, it did not rebuild `playbackQueue` at all, so reordering inside a playlist left the playing queue in the old order for the rest of the session ([14 · C4](14-known-issues.md#c4-reordering-does-not-update-playbackqueue), [C5](14-known-issues.md#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop)).

The `playingFromSongsTab` guard is the same asymmetry §6.3 uses, and for the same reason: the playlist is the source of truth unless the Songs tab is.

### 6.3 Multi-select drag

`AudioPlaybackService.reorderSelectedSongs(selectedIDs:to:in:playlist:)` (`:205-246`). This is the most careful code in the layer:

```swift
let selectedIndices = currentSongs.enumerated()                      // :206-210
    .filter { selectedIDs.contains($0.element.id) }
    .map { $0.offset }
    .sorted()
let selectedSongs = selectedIndices.map { currentSongs[$0] }         // :211
var songs = currentSongs                                             // :212
for index in selectedIndices.reversed() { songs.remove(at: index) }  // :214-216  ← reversed!
let adjustedDestination = destination
    - selectedIndices.filter { $0 < destination }.count              // :217-219
songs.insert(contentsOf: selectedSongs, at: adjustedDestination)     // :220
```

Three things it gets right that the others don't:

- **Remove in reverse index order** (`:214`) so earlier removals don't invalidate later indices.
- **Adjust the destination** (`:217-219`) to account for the selections that were removed from *before* it — the standard multi-drag correction.
- **Persist and re-sync `playbackQueue`**, and branch on `playingFromSongsTab` to mirror the two single-item variants.

Its caller in `View/content_view.swift:972-988` guards it correctly: it only takes the multi-select path `if isMultiSelectMode && !selectedFileIDs.isEmpty` (`:973`) **and** `source.allSatisfy({ selectedIndices.contains($0) })` (`:978`) — i.e. a drag that starts on a non-selected row falls through to the plain single-item move.

> **The `playlist:` parameter is still dead.** `reorderSelectedSongs(selectedIDs:to:in:playlist:)` defaults `playlist` to `nil` and **no caller passes it** — the playlist-detail list's `.onMove` only calls `reorderPlaylistSongs` (§6.2). Both are now correct, so the *reason* the dead parameter mattered is gone, but `PlaylistDetailView` still has no multi-select drag despite having a full multi-select mode, and the more capable primitive still cannot reach it. **Still open, and worth doing:** make `PlaylistDetailView`'s `.onMove` call `reorderSelectedSongs(in:playlist:)` and pass the playlist. It is left undone because it is a behaviour change to a path that now works, not a bug fix.

---

## 7. `ArtworkService`

```swift
// Services/ArtworkService.swift:46
func saveArtwork(from image: UIImage) -> String? {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }
    let filename = "artwork_\(UUID().uuidString).jpg"
    …write to manager.artworkDirectory…
}
```

- **JPEG at quality 0.8, no resizing.** A 12-megapixel photo from the picker is encoded at full resolution and written to the app group. `PhotosPicker` does return large images.
- Filename is a fresh UUID every time, so **setting artwork twice never overwrites** — it creates a second file and relies on `deleteArtworkIfUnused` to reap the first.
- `loadArtworkImage(_:)` (`:63-76`) is `Data(contentsOf:)` + `UIImage(data:)`, but now goes through an `NSCache<NSString, UIImage>` keyed on the filename. That fixes the worst of the pre-cache behaviour (every re-render re-reading every visible JPEG) for repeat renders, but **the first load of each image is still a synchronous disk read and decode inside `body`**, so a long scroll still does blocking I/O on the main thread. It is a mitigation, not a fix; a real fix is an async loader or a downsample-to-display-size image at save time.
- `deleteArtworkIfUnused(_:)` (`:135-146`) is a **name-based refcount** across `audioFiles` and `playlists`, deleting only at zero. Correct for the dedup that the UUID-per-save scheme never produces — in practice each artwork file is referenced exactly once, so this is really just a delete-if-no-one-uses-it. Because albums are playlists, **a manual album cover participates in the same refcount** and is not reaped while any song or collection still names it.
- **Asymmetry:** `setArtwork(_:for: AudioFile)` (`:78-93`) refreshes `displayedSongs`; `setArtwork(_:for: Playlist)` (`:95-107`) does not need to. But **neither** call is routed through a single code path — the two `removeArtwork` overloads (`:109-121`, `:123-133`) duplicate the same shape a third and fourth time.

### 7.1 `coverIsManual` — the manual/derived distinction

`Playlist.coverIsManual` exists because a `Playlist`'s `artworkImageName` is now **two different things** that were previously conflated:

- **Manual** — the user picked this cover. `setArtwork(_:for: Playlist)` (`:103`) sets `coverIsManual = true`. It sticks even after the songs it was derived from are removed, and `removeArtwork(from:)` (`:129`) resets it to `false`.
- **Derived** — a legacy record, or one that was never given a cover. `coverIsManual` is `false` and `PlaylistService.coverName(for:songs:)` (`:92`) falls back to the first member song with artwork:

  ```swift
  if album.coverIsManual { return album.artworkImageName }
  if let first = songs.first(where: { $0.artworkImageName != nil }) { return first.artworkImageName }
  return album.artworkImageName   // a legacy explicit cover still wins over "no cover"
  ```

The third line is the compatibility case: pre-album playlists that already had a cover store **no** `coverIsManual` key, so they decode as `false` (§2.2). Without that fallback their artwork would silently disappear the moment the first member song gained a different cover. `init(name:…)` sets `coverIsManual = artworkImageName != nil` (`Models.swift:184`), so anything created through the normal path is classified correctly on creation.

> `coverIsManual` and `tagKey` answer the same question — "did a person build this, or did the app?" — at two different layers, and neither can substitute for the other. `coverIsManual` is about *artwork only*; a hand-made album with no cover has `coverIsManual == false`, which does **not** make it a projection target. `tagKey` is the one that decides whether the app may rewrite membership, and it is the only one that says "the app made this".

> The two rules are **not** symmetric. A derived cover is a *function of the current membership*, so removing the first song with artwork re-derives the cover from the next one. A manual cover is stored, so it survives any membership change. This is intentional — "the album art is the first track's art" is a fallback, not a promise.

---

## 8. The views

### 8.1 Songs tab

`SongsListView` (`View/content_view.swift:910-1048`), a `List` of `AudioFileButton` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, `.background(Color.clear)`.

Four presentation details worth knowing, and **all four are copy-pasted into `PlaylistsListView`**:

| | `SongsListView` | `PlaylistsListView` |
|---|---|---|
| bottom fade `\.mask` — `LinearGradient`, opaque to 90 % then `.clear` | `:995-1005` | `:1133-1143` |
| `\.onScrollGeometryChange(for: CGFloat.self)` → `isScrolledDown = newOffset > 60` inside `withAnimation(.spring(response: 0.5, dampingFraction: 0.62, blendDuration: 0.15))` | `:1006-1012` | `:1144-1150` |
| spacer row `Color.clear.frame(height: 35)` | `:990` | `:1128` |
| commented-out `AddActionButton` header | `:937-943` | `:1069-1075` |

The fade mask is what lets rows dissolve under the floating bottom bar; the scroll detection drives the bar's collapse. `AddActionButton` (`View/content_view.swift:1597`) is **dead code** — both of its call sites are inside `/* … */` blocks, and adding is toolbar-only. It is worth deleting rather than leaving commented, but it is harmless and D-class.

`onMove` is at `View/content_view.swift:972-988` (see §6.3). Reorder mode is **not** an `EditButton`: there is no `EditButton` anywhere in the app. `SongsListView` sets `\.editMode` itself (`:1013-1017`), driven by `(isReorderMode || isMultiSelectMode)`, and `PlaylistDetailView` does the same with `isReorderMode` alone (`View/PlaylisList_view.swift:102`). `AlbumDetailView` and `AlbumsListView` follow the same shape. Each view owns its own `isReorderMode` state rather than sharing it, so there is no single place to look for "is the app in reorder mode" — and the Songs list conflating it with multi-select is why a drag there can fire while rows are being deleted.

### 8.2 Playlists tab

`PlaylistsListView` (`View/content_view.swift:1050-1152`) — a `List` of `NavigationLink` → `PlaylistDetailView`, each with a context menu offering Set/Change Artwork, Remove Artwork (only if set), rename, and Delete.

**All playlists are `NavigationLink`s into a `NavigationStack` inside a `TabView` page** (`View/content_view.swift:43`). Navigating to a playlist therefore switches the toolbar's leading/centre content, and the bottom bar is still shown unless `libraryFilter == .player`.

### 8.3 Playlist detail

`PlaylistDetailView` (`View/PlaylisList_view.swift:4-202`). This is the most state-heavy view in the app: **11 `@Binding`s** (`:8-13`, plus `:16-21`) threading presentation state from `ContentView` down into `PlaylistAudioFileButton` (`:204-285`) — rename alerts, share sheets, artwork targets, multi-select, and three batch dialogs. It is also the only place a row has a `.swipeActions` (`:83-92`) offering a destructive "Remove" (remove-from-playlist only; the destructive "Delete Permanently" is context-menu-only, at `:376`).

Its empty state (`:47-58`) is a 60 pt `music.note.list` glyph plus *"This playlist is empty / Go to Songs view and use the context menu to add songs here"*.

Three bugs, two of them now fixed and one still open:

> **`playlistSongs` is a computed property that does a linear resolve per row.** `audioManager.getAudioFiles(for: playlist)` (`View/PlaylisList_view.swift:24`) is called from `body`, and `ForEach(playlistSongs)` re-invokes it — the value is used **7 times** in `body`. `getAudioFiles` now goes through the service's `[UUID: AudioFile]` index, so each call is O(m) rather than O(n·m), but the *7 calls per `body` evaluation* remain. `songsByPlaylistID(for:)` is the shape that fixes it properly — `AlbumDetailView` and `AlbumsListView` both use it; this view still does not.
>
> **It read `audioManager.playlists.filter { $0.id != playlist.id }` for the "Add to Another Playlist" menu** and called `addAudioFile` in a `ForEach` over the *selected IDs* (a `Set`) — so batch-add iterated in a **non-deterministic order**. Both are now fixed: the target list is `transferTargets` (`:168`, playlists + albums, minus self) and the iteration is `selectedSongsInPlaylistOrder` (`:170`). The **per-song save cost is fixed too** — it now calls `addAudioFiles(_:to:)`, which saves once for the whole batch, instead of N full library mirrors (§5).
>
> The single-file context menu was also fixed to read `sortedPlaylists`/`sortedAlbums` instead of the raw `manager.playlists` array, which had been exposing the **master playlist** as a batch-add destination named `__MASTER_SONGS__`.

**Fixed.** The `.onMove` here calls `reorderPlaylistSongs`, which no longer has the captured-`index`-across-a-dispatch-hop defect and now rebuilds `playbackQueue` (§6.2). `AlbumDetailView` uses `updatePlaylistOrder(_:with:)`, which was already correct. The two are now equivalent.

### 8.4 Context menus, side by side

There are **four** context-menu views, and only the first is about one file:

| View | Line | Used by |
|---|---|---|
| `AudioFileContextMenu` | `View/content_view.swift:1744-1803` | Songs tab, single selection |
| `MultiSelectContextMenu` | `View/content_view.swift:1479-1595` | Songs tab, **multi** selection |
| `PlaylistAudioFileContextMenu` | `View/PlaylisList_view.swift:323-379` | Playlist detail, single selection |
| `PlaylistMultiSelectContextMenu` | `View/PlaylisList_view.swift:286-321` | Playlist detail, multi selection |

**`MultiSelectContextMenu` is the only path from a multi-selection to a collection, which makes it load-bearing rather than one-of-four.** It is the sole place that answers "which collections can this selection reach?", and it is now two `Menu` sections over `sortedPlaylists` and `sortedAlbums` — the whole set, so nothing has to be remembered as playlists-only when a fourth entry point appears — plus **"New Playlist from Selection"** and **"New Album from Selection"**. It was built from `sortedPlaylists` alone, which made albums unreachable; see [14](14-known-issues.md#b14-the-multi-select-menu-offered-only-playlists-so-albums-were-unreachable).

`libraryOrderedSelection(for:in:)` (`:1472`) picks the songs in the order the **source list shows them**, not in `Set` iteration order, so "new playlist from selection" does not silently rearrange them. This is the same correction `PlaylistDetailView` got for its own batch dialog (`View/PlaylisList_view.swift:262-263`), and the same `ForEach`-over-a-`Set` trap `reorderSelectedSongs` has to avoid (§6.3).

`PlaylistMultiSelectContextMenu` takes `selectedFileIDs: Set<UUID>` **by value** (`:270`) and the enclosing view already filters its options to selected rows, so the copy is intentional.

The playlist-detail versions use **lowercase, inconsistent labels** — `"share this file"`, `"rename"`, `"Remove from '\(playlist.name)'"` — while the Songs-tab version capitalises. The screenshots in the app will show both conventions. Every "Add to Another Playlist" submenu is a `ForEach` over *other* collections and is **empty if you have no other playlist or album**, with no disabled/empty state.

### 8.5 `MiniPlayerBar`

`View/content_view.swift:1154-1259`, shown when `audioManager.currentlyPlayingID != nil && !isMultiSelectMode` (`View/PlaylisList_view.swift:106`). `progressPercentage` (`:1238`, `:1249`) maps `currentTime / duration`. It appears in `PlaylistDetailView` but is **not** referenced from `SongsListView` or `PlaylistsListView` — so the Songs tab, which is where a track is usually started from, has no mini-player. Check before assuming both tabs have one.

### 8.6 Albums — `View/Album_view.swift`

`AlbumsListView` (`View/Album_view.swift:37-272`) is a `LazyVGrid` of three `GridItem(.flexible(), spacing: 12)` columns, one `NavigationLink` → `AlbumDetailView` per cell — **unless it is in reorder mode**, in which case it renders a `List` instead (`grid` `:134`, `reorderList(_:)` `:180`). `albumsPage` (`View/content_view.swift`) is a `ZStack` that swaps in `EmptyAlbumView` when `sortedAlbums.isEmpty`, mirroring the Playlists page. There is **no** separate songs/plural listing and no grouping; the order is the one `sortedAlbums` produces (§3.2), which is the user's arrangement if the page has one and newest-first if it does not.

`AlbumGridCell` (`:276-323`) is the only cell: `AlbumCoverThumbnail` above a `VStack(alignment: .leading)` of name, then **`artist` if set, else `subtitle(_:songCount:)`** (`:292`). The subtitle is now tag-aware — a **derived** album has no `artist` (that field means a user-typed string, §5.1), so it shows `Genre · rock` instead of a bare song count, and a derived album is visibly a different kind of object from a hand-made one of the same name. The whole cell is one tap target; the cover alone is not separately tappable on this page.

#### Reorder mode

`isReorderMode` + a toolbar button swaps the grid for a `List` and calls `moveCollection(in: page, from:to:)` (§5.1). This is the same pattern `AlbumDetailView` already uses for its *track* reorder, and it exists because `LazyVGrid` has **no** `.onMove` — iOS offers no way to drag a grid cell to a new index. Swapping containers rather than adding a drag gesture to the grid is the fix, not a workaround. The context menu is extracted to `albumContextMenu(_:)` (`:224`) so both layouts share one definition rather than drifting.

`albumContextMenu(_:)` also carries **"Detach from Tags"**, shown only when `tagKey != nil`. That is the one-way door out of being a projection: it clears the key and any suppression, and the album keeps its songs as an ordinary hand-made one (§5.1).

**Reorder is disabled while a search is active, and this is not polish.** `AlbumsListView` renders `filteredAlbums`, and `.onMove`'s indices are positions in whatever array the `ForEach` renders — dragging the third of five search results would renumber three unrelated positions against the *unfiltered* page. So `reorderableAlbums` (`:75`) returns `nil` while `isFiltered` is true, and `isFiltered` comes down from `ContentView` as `!searchText.isEmpty` — the only place that knows about the search string. Nothing re-derives "is this a search result" by filtering inside the view: the same string could filter to the whole page, and then the indices would be right by accident. This is [14](14-known-issues.md#c5-reorderplaylistsongs-captures-index-across-a-dispatch-hop)'s lesson one level up — the list being renumbered and the list on screen must be the same list, or there must be no list.

`AlbumDetailView` (`:327-695`) deliberately does **not** reuse `PlaylistDetailView`, because the presentation is different enough that forcing a shared body would mean more `if` branches than shared layout:

| | `PlaylistDetailView` | `AlbumDetailView` |
|---|---|---|
| container | `List` | `ScrollView` + `VStack` (the header scrolls away) |
| header | none | square cover, editable title, editable artist, "*n* songs · *m:ss*" |
| navigation title | album name | `""` (`.navigationBarTitleDisplayMode(.inline)`) so the bar holds only the back button |
| rows | `AudioFileRow` | `PlaylistAudioFileButton` + `trackNumber` |

> **The inline empty navigation title is load-bearing, not cosmetic.** The title is rendered as `.title2` in the header, and SwiftUI's large-title mode reserves its own vertical space. With both, the album name appears twice on open. The header's `Text` carries `.accessibilityAddTraits(.isHeader)` so VoiceOver still announces the album name as the screen title.

> **`AlbumDetailView` masks its bottom 10% with a `LinearGradient`** so rows fade under the tab bar; `PlaylistDetailView` does not. Harmless as far as it goes, but it means the two "reorderable list" screens are not visually identical, and it is part of why the *album page* needed its own reorder mode rather than sharing one.

**Track numbers are positional, not stored.** `AlbumGridCell`/`AlbumDetailView` pass `trackNumber: index + 1` from the `ForEach` over the resolved `albumSongs`, which is `audioFileIDs.compactMap { index[$0] }` — the array order (§2.2). Reordering mutates `audioFileIDs` and the numbers renumber themselves. Consequences worth knowing:

- A **dangling id is skipped silently**, so a gap in the track numbers is possible if membership and the library ever disagree (§2.2). `displayedSongs` is filtered, so **a hidden song still occupies its track number** — deliberate, since track numbers describe the album, not the current search.
- A positional number can therefore **contradict the file's own `trackNumber` tag**, which for a real tag-derived album is usually the artist's intent. For a hand-made album, positional is the only thing that exists. ⚠️ Unresolved; see [14](14-known-issues.md)'s C12/D14 area.
- `.onMove` inside `AlbumDetailView` reuses `PlaylistService.updatePlaylistOrder(_:with:)` (`:273-282`), which writes the ids back **and** rebuilds `playbackQueue`. This is the correct primitive, and it is the one the pre-existing `PlaylistDetailView` reorder path does *not* use (§6.2) — which is why the *song* reorder inside an album is safe while the one inside a playlist is not.

`AddSongsToAlbumSheet` (`:699-791`) lists `displayedSongs` minus current members, with All/Add-N multi-select. It iterates the **filtered candidate list** (`candidates` `:712`), not the `Set` of selected ids, so the insertion order is deterministic; the same fix was applied to `AlbumDetailView`'s three batch dialogs. `Add N` now calls **`addAudioFiles(_:to:)`** — one save for the whole batch, not one per song (§5).

`AlbumCoverThumbnail` (`:9-33`) is the shared cover renderer for both pages: an accent-tinted `square.stack` placeholder, or the image at `.aspectRatio(1, contentMode: .fit)` with a rounded clip. It takes a `UIImage?` and does **no loading** — the caller resolves it via `ArtworkService.loadArtworkImage` (§7).

> `View/Album_view.swift` **is** in the target. It was not for most of this project's life — see [14](14-known-issues.md#a1-target-membership-silently-swallowed-files) — but the project now uses a `PBXFileSystemSynchronizedRootGroup`, so every `.swift` file under the root is a member and new files need no `project.pbxproj` edit at all.

---

## 9. Change checklist

| If you change… | Re-verify |
|---|---|
| `AudioFile`'s stored properties | **both inits take the tag fields in a fixed order — `artist, album, albumArtist, genre, year` — and getting that order wrong compiles fine and misfiles every tag.** The Codable path needs no change, but the display-name fallback disagrees with the import path (§2.1) |
| **`Playlist`'s stored properties** | **the hand-written `init(from:)` — a new field **must** use `decodeIfPresent(…) ?? default`, or every user playlist and album is deleted on next launch (§2.2, §3.1). This is the single most dangerous edit in the codebase.** And the matching `playlist` column, `PlaylistRecord` field, `upsertPlaylist` binding, `loadPlaylists` SELECT, and the `LibraryMigration` projection — five places, and missing any one of them fails silently as `NULL` or `0` |
| **`Playlist`'s `sortOrder`** | **written only by `moveCollection(in:from:to:)` (§5.1) and only for the page it was handed.** If you add another writer, positions can go non-dense and the gap-filling breaks. `nil` must stay distinguishable from `0` — see the nullable argument in §5.1 |
| **`Playlist`'s `tagKey`** | **written only by `TagAlbumProjector`, and read only by it and `deletePlaylist`'s suppression (§5.1).** A hand-made album has `tagKey == nil`, and *that* is the only thing stopping the projector adopting a user's album just because a file arrived with a matching tag. Never infer a tag key from a name |
| `Playlist`'s `isAlbum` | `sortedPlaylists` and `sortedAlbums` both filter on it (§3.2); every "other collections" list must union both pages or albums become unreachable as batch-add targets |
| `masterPlaylistID` handling | `loadOrCreateMasterPlaylist` (`:175`) and `clearZombiePlaylists` — the reset path deletes user playlists **and albums** |
| `sortedAudioFiles` (`:12`) | it *discards* the manual order by sorting on `dateAdded`; every caller that reassigns `displayedSongs` inherits that |
| `deletePlaylist` | the master guard is now an explicit `guard playlist.id != masterPlaylistID` (§3.2) — don't rely on the filter again — **and the tag-suppression record (§5.1) must stay ahead of the row removal, keyed by tag rather than by the album's now-dead id** |
| `createPlaylist` | it **returns the `Playlist`** (§5). Callers that populate the new collection depend on that; changing the return type to `Void` breaks "new playlist from selection" at compile time, which is the good outcome |
| **`addAudioFiles` / `removeAudioFiles`** | **they are the primitives; `addAudioFile`/`removeAudioFile` forward to them (§5).** Adding a *new* single-song loop instead of calling the batch method reintroduces N library mirrors — there is no queue or coalescing to absorb it |
| `playlistsPage`'s empty-state check | already fixed to `sortedPlaylists.isEmpty`; `albumsPage` uses `sortedAlbums.isEmpty`. Neither is filter-aware (§3.4) |
| `filteredSongs` / `filteredPlaylists` / `filteredAlbums` | they filter but the empty states don't (§3.4) — searching with no matches shows a blank page with no message. **`filteredAlbums` is also why album reorder is disabled during a search (§8.6)** |
| `cleanupOrphanedFiles` | the `"Artwork"` literal exemption and the fact it runs on every launch after imports |
| `savePlaylists` | one call is a full `LibraryStore.persist` **mirror** of the library, by design and deliberately not made incremental (§5). Every batch path must funnel through it once, not once per row |
| `reorderPlaylistSongs` | it now writes synchronously and rebuilds `playbackQueue` under the `!playingFromSongsTab` guard (§6.2). **Do not reintroduce a `DispatchQueue.main.async` hop** — the closure captured the integer index by value and could overwrite a different playlist. Its dead `playlist` sibling parameter is §6.3 |
| `moveCollection(in:from:to:)` | **the page is a parameter on purpose (§5.1).** A service that discovered the page itself would renumber one list using another's indices the first time a search was active |
| `MultiSelectContextMenu` | **the only path from a multi-selection to a collection (§8.4).** Anything that adds a collection kind must be added to *both* `Menu` sections here or it is unreachable |
| `libraryOrderedSelection(for:in:)` | it exists to order by the **source list**, not by `Set` iteration (§8.4). Any new batch action built on a `Set<UUID>` needs it too |
| `TagAlbumProjector`'s run points | after `LibraryTagSweep` and **once per completed import batch**, not per file (§5.1). A third trigger is fine; a per-file one makes a large import quadratic |
| `PlaylistDetailView.playlistSongs` | it is a computed property evaluated 7× per `body`; `songsByPlaylistID` is the fix and the Albums grid already uses it (§2.2, §8.6) |
| `ArtworkService.loadArtworkImage` | now `NSCache`-backed, but first load is still a synchronous read inside `body` (§7) |
| `coverIsManual` | `coverName(for:songs:)` is the only reader and `setArtwork`/`removeArtwork` the only writers (§7.1); a legacy cover needs the third fallback line or it disappears |
| `LibraryItem` | delete it, or wire it up — it has zero references |
