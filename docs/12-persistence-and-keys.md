# 12 — Persistence and Storage Keys

> The canonical inventory of every persisted byte in the app. If you are adding a value that must survive a relaunch, this is the file to update.
> Companion: [11-settings-ui.md](11-settings-ui.md) (which keys have UI), [09-file-import-and-sharing.md](09-file-import-and-sharing.md) (app-group traffic).

---

## 1. The three storage mechanisms

| Mechanism | Where | Used for |
|---|---|---|
| `UserDefaults.standard` | app sandbox `Library/Preferences/Cam.Punches3.plist` | library, playlists, master-playlist id, selected algorithm, visualisation mode, all 30 theme values |
| `UserDefaults(suiteName: "group.Cam.punches-ios")` | shared app-group container | the share-extension handoff list only |
| Filesystem | app-group container **or** `Documents` (fallback) | audio files, artwork JPEGs, pending share drops |

> **There is no `@AppStorage` anywhere in the project.** Verified by repo-wide grep. Every value is loaded in an initialiser and written from a `didSet` observer or an explicit `save*()` call.

---

## 2. Library, playlist and mode keys

Declared as `let` properties on `AudioManager` (`audio_manager.swift:28-34`); all read/written by `Services/`.

| Constant | Literal key | Type | Written by | Read by | Default when absent |
|---|---|---|---|---|---|
| `audioFilesKey` | `"savedAudioFiles"` | `Data` — JSON `[AudioFile]` | `AudioLibraryService.saveAudioFiles()` (`:30-37`) | `loadAudioFiles()` (`:11-28`) | `[]` |
| `playlistsKey` | `"savedPlaylists"` | `Data` — JSON `[Playlist]` | `PlaylistService.savePlaylists()` (`:69-76`) — synchronous, single writer | `loadPlaylists()` (`:78-85`) | `[]` |
| `masterPlaylistKey` | `"masterPlaylistID"` | `Data` — JSON `UUID` | `loadOrCreateMasterPlaylist()` (`:70-72`) | `loadOrCreateMasterPlaylist()` (`:53-57`) | creates a new master playlist |
| `algorithmKey` | `"selectedAlgorithm"` | `String` — `PitchAlgorithm.rawValue` | `AudioEngineService.saveSelectedAlgorithm()` (`:31-33`) | `loadSelectedAlgorithm()` (`:23-29`) | `.apple` |
| `visualisationModeKey` | `"visualisationMode"` | `String` — `VisualisationMode.rawValue` | `AudioLibraryService.saveVisualisationMode()` (`:136-138`), triggered from `content_view.swift:344-345` | `loadVisualisationMode()` (`:129-134`) | `.Goniometer` (from the `@Published` initial value, `audio_manager.swift:19`) |

### Exact `rawValue` strings these keys can hold

| Enum | Raw values | Defined at |
|---|---|---|
| `PitchAlgorithm` | `"Apple (Default)"`, `"Rubber Band (Best quality for extreme changes)"`, `"SignalSmith (Modern)"` | `pitch_algorithm.swift:3-6` |
| `VisualisationMode` | `"Goniometer"`, `"Artwork"`, `"Spectrum"` | `AudioMeters/VisualisationMode.swift:3-8` |
| `AppearanceMode` | `"Dark"`, `"Light"` | `View/setting_View.swift:844-847` |
| `AppTheme` | 35 values, see [10-theming-and-shaders.md](10-theming-and-shaders.md#3-apptheme--35-cases-20-dark--15-light) | `View/setting_View.swift:255-291` |
| `TunnelQuality` / `WaterQuality` / `SmokeQuality` | `"Low"`, `"Balanced"`, `"High"` | `setting_View.swift:12`, `:66`, `:128` |

> **Gotcha — `PitchAlgorithm` raw values are display strings.** `"Apple (Default)"` is what lands in `UserDefaults`. Renaming the enum case's `rawValue` silently resets the user's selection. Same for all the other enums above: they all persist `rawValue`, never a stable identifier.

---

## 3. App-group keys

`SharedConstants.swift` is the whole file (7 lines) and is shared with the share extension:

```swift
// SharedConstants.swift:3-7
struct SharedConstants {
    static let appGroupIdentifier = "group.Cam.punches-ios"
    static let pendingFilesKey    = "pendingImportFiles"
    static let openAndPlayScheme  = "punches://openAndPlay"
}
```

| Key | Suite | Type | Written by | Read/cleared by |
|---|---|---|---|---|
| `"pendingImportFiles"` | `group.Cam.punches-ios` | `[String]` — bare **file names**, not URLs | `AudioShare/ShareViewController.swift:155-163` | `AudioImportService.processPendingImports` (`Services/AudioImportService.swift:114, 168-169`) |
| `"group.Cam.punches-ios"` | — | app-group id | — | `audio_manager.swift:48`, `AudioImportService.swift:112-113`, `ShareViewController.swift:135, 158` |

### Entitlement state — currently broken

| Entitlements file | Contains app group | Wired into a build? |
|---|---|---|
| `Punches3.entitlements` | **nothing — it is an empty `<dict/>`** | **YES** — `CODE_SIGN_ENTITLEMENTS = Punches3.entitlements` (`project.pbxproj:559, 598`) |
| `silly_speed_ios.entitlements` | `group.Cam.punches-ios` | no — file reference exists (`project.pbxproj:233`) but no target points at it |
| `AudioShare/AudioShare.entitlements` | `group.Cam.punches-ios` | no — no extension target exists |

Consequence: `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` in the signed app, so the share-extension pipeline cannot work and the app silently falls back to `Documents`. Full analysis and fix: [14-known-issues.md](14-known-issues.md#b1-app-group-entitlement-is-empty).

---

## 4. Theme keys — all 30

Defined as a `private enum ThemeKey` at `View/setting_View.swift:851-887`. Because it is `private`, **no other file can reference these string constants** — if you need one outside the file, you must redeclare it.

| Group | Keys |
|---|---|
| Palette (8) | `theme.backgroundColor`, `theme.textColor`, `theme.secondaryTextColor`, `theme.accentColor`, `theme.tint`, `theme.gonioSidesColor`, `theme.gonioMidsColor`, `theme.playButtonColor` |
| Water (4) | `theme.useWaterShader`, `theme.waterSpeed`, `theme.waterIntensity`, `theme.waterQuality` |
| Fog (4) | `theme.useFogShader`, `theme.fogColor`, `theme.fogSpeed`, `theme.fogIntensity` |
| Tunnel (6) | `theme.useTunnelShader`, `theme.tunnelColor`, `theme.tunnelSpeed`, `theme.tunnelIntensity`, `theme.tunnelQuality`, `theme.tunnelGrainStrength` |
| Smoke (5) | `theme.useSmokeShader`, `theme.smokeSpeed`, `theme.smokeIntensity`, `theme.smokeGrayscale`, `theme.smokeQuality` |
| Appearance (3) | `theme.appearanceMode`, `theme.selectedDarkTheme`, `theme.selectedLightTheme` |

### Value encoding per type

| Type | Encoding | Example | Read path | Write path |
|---|---|---|---|---|
| `Color` | `"#rrggbb"` (no alpha) | `"#2E3440"` | `Self.loadColor` (`setting_View.swift:1150-1153`) → `Color(hex:)` (`:830-840`) | `save(_:for:)` (`:1146-1148`) ← `Color.hexString` (`:891-899`) |
| `Bool` / `Double` | native plist scalar via `UserDefaults.standard.set(_:forKey:)` | `0.7` | `ud.object(forKey:) as? Bool/Double ?? presetDefault` (`:1037-1065`) | `didSet` |
| Enum | `.rawValue` as `String` | `"Balanced"` | `ud.string(forKey:)` + `init(rawValue:)`, else preset default (`:1040-1070`) | `didSet { set(x.rawValue, forKey:) }` |

> **Gotcha — `Color` loses alpha.** `Color(hex:)` (`:831-839`) initialises with `self.init(red:green:blue:)` in sRGB and no alpha, and `hexString` (`:893-897`) reads only RGB. Any theme colour authored with alpha will round-trip to fully opaque. No current preset does, so this is latent.

> **Gotcha — write amplification.** `ThemeManager.apply(_:)` (`setting_View.swift:1096-1138`) assigns ~15 properties in sequence; each assignment fires its own `didSet` → `UserDefaults.set`. Selecting a theme is therefore ~15 synchronous plist writes. Harmless at this scale, but do not call `apply` in a loop.

### Persisted but with no UI control

| Property | Key | Notes |
|---|---|---|
| `fogColor` | `theme.fogColor` | preset-driven only |
| `fogSpeed` | `theme.fogSpeed` | preset-driven only; the Settings slider labelled "Density" binds `fogIntensity` instead (`setting_View.swift:1508`) |
| `waterColor` | — | **not persisted at all.** `let waterColor: Color = Color(hex: "#2A7FAA")` with the comment "Fixed water tint — not user-configurable" (`setting_View.swift:947-948`) |

---

## 5. On-disk layout

Resolved once by a `static let`, at first access, from the app group with a `Documents` fallback:

```swift
// audio_manager.swift:47-55
static let fileDirectory: URL = {
    if let groupURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier) {
        let dir = groupURL.appendingPathComponent("AudioFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    } else {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}()
```

```
<app-group container>/                 ←  group.Cam.punches-ios
├── AudioFiles/                        ←  AudioManager.fileDirectory
│   ├── <imported filename>.mp3
│   ├── <imported filename> 2.mp3       ←  generateUniqueFileName() suffix scheme
│   └── Artwork/                       ←  AudioManager.artworkDirectory (:66)
│       └── artwork_<UUID>.jpg         ←  jpegData(compressionQuality: 0.8)
└── PendingImports/                    ←  created by ShareViewController:139
    └── <name from the share provider's file>
```

| Directory | Owner | Notes |
|---|---|---|
| `AudioFiles/` | `AudioManager.fileDirectory` | **Not cleaned by name.** `cleanupOrphanedFiles` (`AudioLibraryService.swift:92-106`) deletes any entry not in `audioFiles` *except* the literal name `"Artwork"` (`:101`) |
| `AudioFiles/Artwork/` | `AudioManager.artworkDirectory` (`:66, 69`) | also excluded from orphan GC by the same `"Artwork"` check |
| `PendingImports/` | `ShareViewController.swift:139` | removed wholesale at the end of every `processPendingImports` (`AudioImportService.swift:171`) |

> **Gotcha — the `static let` cannot recover.** `fileDirectory` is evaluated on first touch. If the app group entitlement is added in a build update, the running process still has the old value baked in. Full relaunch required; and a reinstall can leave previously-fallbacked files stranded in `Documents`.

### Filename uniqueness

`AudioLibraryService.generateUniqueFileName(for:)` (`AudioLibraryService.swift:66-90`): if the name is free, return it; otherwise strip the extension and append a space plus an incrementing counter starting at 2 (`"song.mp3"` → `"song 2.mp3"` → `"song 3.mp3"`). Files with no extension get `"name 2"`. It does not dedupe against `audioFiles` metadata, only against the filesystem.

### Artwork lifecycle

| Step | Code |
|---|---|
| Encode | `image.jpegData(compressionQuality: 0.8)`, filename `artwork_<UUID>.jpg` (`ArtworkService.swift:21-36`) |
| Assign | `setArtwork(_:for:)` rebuilds the model with the new `artworkImageName` (`:48-67` file, `:69-81` playlist). The playlist overload also sets `coverIsManual = true` (`:77`) |
| Free | `deleteArtworkIfUnused(_:)` (`:116-127`) counts references across `audioFiles` **and** `playlists`, deletes the JPEG only when both counts are 0 |
| Decode | `loadArtworkImage(_:)` reads `Data(contentsOf:)` then `UIImage(data:)`, through an `NSCache<NSString, UIImage>` (`:33-46`) — still synchronous and on whatever thread asked, so the first load of each image does blocking I/O inside `body` |

`artwork_<UUID>.jpg` is a fresh name on every save, so setting artwork twice creates two files and relies on `deleteArtworkIfUnused` to reap the first. **Albums do not add a second artwork store**: an album's cover is a row in the same `playlists` array, and `coverIsManual` records only whether that row's `artworkImageName` is a user choice or a derived value ([08 §7.1](08-playlists-and-library.md#71-coverismanual--the-manualderived-distinction)).

### The SQLite library store — the actual source of truth

Everything above describes the **legacy** `UserDefaults` layout, which the `laptop` merge replaced. It is still live in exactly one respect: `LibraryMigration` reads it once to seed the new store, and then it is stale. `AudioManager.fileDirectory` (`AudioFiles/`) remains the path for anything that has not been moved across.

Current state lives in SQLite, resolved by `LibraryEnvironment.resolve()` (`Services/LibraryEnvironment.swift:136`). The root is the app group container when the entitlement works, and `Documents/Punches/` when it does not — see [14 · A3](14-known-issues.md#a3-app-group-entitlement-is-empty), which is why the app currently degrades to the fallback:

```
Documents/Punches/                  ←  or <group container>/Library/
├── library.sqlite                  ←  LibraryEnvironment.database
├── library.sqlite-wal
├── library.sqlite-shm
├── tracks/                          ←  committed audio, one file per library row
├── staging/                         ←  in-flight imports, never a library row
├── inbound/                         ←  handed over by the share extension
├── artwork/
└── trash/                           ←  LibraryReconciler.moveToTrash
```

Five tables, created by `LibrarySchema.version1`: `track`, `playlist`, `playlist_member`, `import_job`, `meta`. `version2` adds **13 columns to `track`** for audio metadata — `artist`, `album`, `album_artist`, `genre`, `release_year`, `track_number`, `track_total`, `disc_number`, `disc_total`, `comment`, `sample_rate`, `channel_count`, `tags_read` — bringing it to 26. The schema version is stamped in `PRAGMA user_version`; `migrate()` advances it step by step inside a transaction.

> **Every v2 tag column is nullable, on purpose.** `NULL` has to keep meaning "this file carries no such tag", which is a different statement from "we have not looked yet". `sqlite3_column_int` and `sqlite3_column_double` cannot tell `NULL` from `0`, so `LibraryStore.optInt` / `optDouble` read the column type instead — otherwise every untagged track would acquire a track number of 0 and a year of 0. That distinction is the reason the backfill sweep needs the separate `tags_read` column rather than inferring "never read" from "all tags are NULL".

> **`ALTER TABLE ADD COLUMN` is not idempotent** — running it twice fails with `duplicate column name`. `version2` is therefore a `[(column, sql)]` list and `migrate()` skips any entry `PRAGMA table_info` already reports, so an install interrupted between two of the thirteen statements recovers. `migrate()` is an explicit ladder (`if current == 0 … else if current == 1 …`), not `if current == 0 { stamp currentVersion }`; the latter would stamp v2 on a fresh install without ever running the ALTERs.

> **The tags are filled in by a sweep, not by the migration.** The values live in the audio files, so reading them means opening files — slow, and fallible, neither of which belongs in a migration that would roll back its own version stamp on the first failure. `LibraryTagSweep` reads them once per file, at launch, awaiting each file so the main actor is never blocked, and yielding between them. See [14 · D14](14-known-issues.md#d14-no-metadata-is-read-anywhere-the-title-is-the-filename).

**The write path is one function, and it is the one to check first when a change "doesn't save".**

| Call | Effect |
|---|---|
| `LibraryStore.exec(_:bindings:)` | `:1125` — runs any statement for its effect. The **only** write path in the layer. |
| `LibraryStore.drain(_:onRow:)` | `:1138` — steps a prepared statement to `SQLITE_DONE`, invoking `onRow` per row. Every read and write goes through it. |
| `LibraryStore.forEachRow(_:bindings:_:)` | `:1176` — `drain` plus a per-row closure. |
| `LibraryStore.addMembership(playlistID:trackID:position:)` | `:1222` — the **only** writer of `playlist_member` from a single import or repair. Guarded; see below. |
| `LibraryStore.persist(_:)` | `:521` — the one mirror operation. Writes tracks, playlists, membership and `meta`, then `prune`s anything absent. **A full mirror, not a delta.** |

> **Gotcha — `sqlite3_prepare_v2` only compiles.** A statement that is prepared and finalised without ever being stepped executes *nothing*, with no error. `exec` is exactly that shape; it now drains through `drain`, and the two must not be split again. This was a real Critical defect for one commit — [14 · C15](14-known-issues.md#c15-exec-prepared-every-statement-and-never-stepped-it-so-no-write-ever-ran) — and it compiled and launched cleanly throughout.

> **Gotcha — `INSERT OR IGNORE` does not tolerate a foreign-key violation.** SQLite's `ON CONFLICT` clause resolves UNIQUE, NOT NULL and CHECK only; the documentation states that it *"does not apply to FOREIGN KEY constraints."* So an `INSERT OR IGNORE INTO playlist_member` with a `playlist_id` that has no row raised `SQLITE_CONSTRAINT_FOREIGNKEY` from `sqlite3_step` — and because `commitImport` writes the `track` row and the membership row in one transaction, the rollback **discarded the track that had just been committed correctly.** Do not reach for `OR IGNORE` or `OR REPLACE` to make a foreign key go away. `addMembership` uses `SELECT … WHERE EXISTS (SELECT 1 FROM playlist WHERE id = ?)`, which checks the parent in the same statement as the insert, and returns whether the row was written.

> **Gotcha — `persist` is all-or-nothing per snapshot.** `foreign_keys` is `ON` with `ON DELETE CASCADE`, so one unresolvable reference anywhere fails the insert and rolls back **every** write in that snapshot. Membership is filtered against the snapshot's own track ids for this reason. If persistence ever "silently stops", check for an orphan member id before anything else.

> **Gotcha — `meta` is not a foreign key, so it does not cascade.** `master_playlist_id` is a UUID stored as text in a key/value table, so deleting a `playlist` row leaves the pointer naming nothing, and `prune(table: "playlist")` will delete rows the projection omits. Two rules hold that together: `persist` retracts the pointer when the row it names did not survive (asking the database, not the snapshot — `prune` refuses to delete anything on an empty projection, so a row can outlive a snapshot that never mentioned it), and `loadMasterPlaylistID` joins `playlist` so it never hands back an id with nothing behind it. The master row itself is created by `loadOrCreateMasterPlaylist`, which must save whenever it mints one — a master that exists only in memory is unreferenceable, and `sortedAudioFiles` is driven entirely by master membership, so tracks added to it would be invisible rather than absent. See [14 · C17](14-known-issues.md#c17-every-import-failed-with-a-foreign-key-violation-discarding-the-track-it-had-just-committed).

---

## 6. What survives a relaunch

| State | Persisted? | Where |
|---|---|---|
| Imported audio files | ✅ | `tracks/` + the `track` table |
| Playlists, names, membership, order | ✅ | the `playlist` and `playlist_member` tables |
| Albums (as playlists with `isAlbum`), album artist, manual-vs-derived cover | ✅ | the same `playlist` table — no separate `albums` array |
| Hidden master playlist + its order | ✅ | `playlist.is_master`, plus `meta` for the id; ordered by `playlist_member.position` |
| Per-file/per-playlist artwork | ✅ | `artwork/artwork_<UUID>.jpg` + the filename column |
| Renamed titles | ✅ | `track.display_title` |
| Audio tags (artist, album, genre, year, track/disc, comment) | ✅ | the v2 `track` columns — read from the file at import, or by `LibraryTagSweep` for files imported before metadata existed |
| Visualisation mode | ✅ | `"visualisationMode"` |
| Pitch algorithm | ✅ | `"selectedAlgorithm"` |
| All 35 theme choices + 30 theme values | ✅ | `theme.*` |
| **`tempo`** | ❌ | `@Published var tempo: Float = 1.0` (`audio_manager.swift:14`) — resets every launch |
| **`pitch`** | ❌ | `@Published var pitch: Float = 0.0` (`:15`) |
| **`isLooping`** | ❌ | `@Published var isLooping: Bool = false` (`:18`) |
| `isSeeking`, `playbackQueue` | ❌ | session only |
| `AudioManager.artworkDirectory` path | derived | static from `fileDirectory` |

The three unpersisted playback flags are almost certainly unintentional — the three slider/transport states a user expects to survive a relaunch are exactly the ones that reset. Adding them is a `UserDefaults` write in `AudioPlaybackService` plus a read in `AudioManager.init`.

---

## 7. Change checklist for a new persisted value

1. Declare the `let` key constant next to the others in `audio_manager.swift:28-34` (or `ThemeKey` in `setting_View.swift:851`).
2. Add the `@Published var` with a `didSet` writer, or a `@AppStorage` — but be aware `@AppStorage` would be the first in the project, so match the surrounding style instead.
3. Load it in `AudioManager.init` (`audio_manager.swift:73-107`) or `ThemeManager.init` (`setting_View.swift:1024-1092`) with a sensible default, and make the default derivable from a preset where one exists.
4. If it is user-facing, add a control to `SettingsView` and a row to [11-settings-ui.md](11-settings-ui.md).
5. Update the relevant table above. These docs are the inventory; if you add a key and do not add a row, the docs are now wrong.
6. **If the value is a new field on `Playlist` or `AudioFile`, it is a schema change, not a key.** Tracks and playlists are rows, not `Codable` blobs, so `UserDefaults` guidance does not apply: add the column to `LibrarySchema.version1` (or, if it is already shipped, to a **new** `version2` array of `[(column, sql)]` pairs), bump `LibrarySchema.currentVersion`, and add the matching `else if current == N { … bump to N+1 … }` branch in `LibraryStore.migrate()`. Reading a column that does not exist fails at **prepare** time and takes every write in the snapshot with it, so test against a database created at the *previous* version, not a fresh one — those are different branches in `migrate()` and only one of them is a fresh install. `TrackRecord` and `PlaylistRecord` already carry the projection for this reason, as does `LibrarySchema.trackColumns`, which both SELECTs share.

   Two rules the v2 migration established, both of which the next version needs too: a tag column must be **nullable** so `NULL` can mean *not tagged* rather than being indistinguishable from a placeholder, and a column of `INTEGER`/`REAL` type must be read through `optInt`/`optDouble`, because `sqlite3_column_int` cannot tell `NULL` from `0`. If the new column is derived from the file's contents rather than from the import, it needs a way to distinguish *not read yet* from *read, and empty* — `tags_read` is how the metadata columns do it.
7. **`decodeIfPresent(…) ?? default` still matters, but for a narrower reason.** It is no longer true that a decode failure destroys the user's library — that was [14 · C1](14-known-issues.md#c1-master-playlist-recovery-destroys-every-user-playlist), now historical. It still matters for `LibraryMigration`, which decodes the **legacy** `UserDefaults` blobs into the new store, and a required key there throws away every record in that blob. `Playlist` has a hand-written `init(from:)` for exactly this reason.
8. **If the value adds a write inside an existing transaction, check what can veto it.** `commitImport` writes the `track` row and the master membership row together; a failure in the second rolls back the first, which is how a perfectly valid file was once discarded with a database error ([14 · C17](14-known-issues.md#c17-every-import-failed-with-a-foreign-key-violation-discarding-the-track-it-had-just-committed)). Two questions worth asking of any new statement in that transaction: *can a foreign key reject it?* — and note that `ON CONFLICT` will not save you, since it does not apply to foreign keys — and *is the parent row guaranteed to exist yet, or only in memory?* If it is only in memory, the statement is not safe to run inside the transaction.
