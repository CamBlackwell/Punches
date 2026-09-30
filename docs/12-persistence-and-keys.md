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

---

## 6. What survives a relaunch

| State | Persisted? | Where |
|---|---|---|
| Imported audio files | ✅ | `AudioFiles/` + `"savedAudioFiles"` |
| Playlists, names, membership, order | ✅ | `"savedPlaylists"` |
| Albums (as playlists with `isAlbum`), album artist, manual-vs-derived cover | ✅ | `"savedPlaylists"` — no new key, no separate `albums` array |
| Hidden master playlist + its order | ✅ | `"savedPlaylists"` + `"masterPlaylistID"` |
| Per-file/per-playlist artwork | ✅ | `Artwork/*.jpg` + model fields |
| Renamed titles | ✅ | `AudioFile.title` in `"savedAudioFiles"` |
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
6. **If the value is a new field on `Playlist` or `AudioFile`, stop and read [14 · C1](14-known-issues.md#c1-master-playlist-recovery-destroys-every-user-playlist) and [C12](14-known-issues.md#c12-an-empty-library-index-makes-the-app-delete-every-file-it-can-see) first.** There is no migration path, and a decode failure is not a degraded mode — it is a destructive reset of everything the user made. `Playlist` has a hand-written `init(from:)` for exactly this reason: **use `decodeIfPresent(…) ?? default`, never a required key.**
