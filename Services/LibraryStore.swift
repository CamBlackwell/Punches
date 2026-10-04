import Foundation
import SQLite3
import os

// MARK: - Value types

/// A row of the `track` table.
///
/// This is deliberately richer than `AudioFile`: the columns that the library
/// index must never lose (the original security-scoped bookmark, the import
/// state, why an import was refused) have nowhere to live in the view-facing
/// model, so they are persisted separately and projected into `AudioFile` only
/// when something asks for one.
struct TrackRecord {
    var id: UUID
    var fileName: String
    var sourceName: String?
    var displayTitle: String
    var ext: String
    var byteSize: Int64
    var duration: Float
    var dateAdded: Date
    var artworkName: String?
    var originBookmark: Data?
    var state: TrackState
    var rejectReason: String?
    var importedVia: ImportOrigin?

    // MARK: Metadata
    //
    // All defaulted to `nil`, so the call sites that legitimately have no tag
    // information — `LibraryMigration` adopting files off disk, the reconciler
    // rebuilding a row — keep compiling unchanged. That matters more than it
    // looks: those two paths must not be the ones forced to invent a value.

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
    var sampleRate: Double?
    var channelCount: Int?

    /// Whether this file's tags have been read yet.
    ///
    /// Exists so the backfill sweep can ask "what still needs reading?" without
    /// re-opening every file in the library on every launch, and so an
    /// interrupted sweep resumes where it stopped. A `NULL`-tagged row is not
    /// the same thing as an unread one: a file with no tags at all must not be
    /// re-opened forever.
    var tagsRead: Bool = false

    /// The view-facing projection. Every `AudioFile` the UI sees comes from here.
    var audioFile: AudioFile {
        AudioFile(
            id: id,
            fileName: fileName,
            dateAdded: dateAdded,
            audioDuration: duration,
            artworkImageName: artworkName,
            title: displayTitle,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            trackNumber: trackNumber,
            trackTotal: trackTotal,
            discNumber: discNumber,
            discTotal: discTotal,
            comment: comment
        )
    }
}

/// A row of the `playlist` table plus its ordered membership.
struct PlaylistRecord {
    var id: UUID
    var name: String
    var isAlbum: Bool
    var coverName: String?
    var coverIsManual: Bool
    var artist: String?
    var dateAdded: Date
    var isMaster: Bool
    var memberIDs: [UUID]

    /// The user's manual position on its page. `nil` when the page was never
    /// arranged.
    ///
    /// Nullable in the row as well as the model because "never arranged" and
    /// "arranged, currently first" are different states, and flattening the
    /// second onto the first would silently rearrange every untouched page the
    /// next time one is dragged.
    var sortOrder: Double?
    /// Set when the row is a projection of a group of file tags rather than a
    /// collection the user built. `nil` — the ordinary case — is what tells a
    /// projection it has no business rewriting this row.
    var tagKey: String?

    var playlist: Playlist {
        Playlist(
            id: id,
            name: name,
            audioFileIDs: memberIDs,
            dateAdded: dateAdded,
            artworkImageName: coverName,
            isAlbum: isAlbum,
            coverIsManual: coverIsManual,
            artist: artist,
            sortOrder: sortOrder,
            tagKey: tagKey
        )
    }
}

// Declared in an extension rather than in the struct body: any initialiser
// written in the body suppresses the synthesised memberwise initialiser, and
// `LibraryMigration` needs that one to build rows with filtered membership.
extension PlaylistRecord {
    /// Projects the view-facing model into a row.
    ///
    /// `isMaster` is passed separately because the store is the only place that
    /// knows which playlist is the master; the model has no such concept, and
    /// inventing one here would let a decode failure reassign it.
    init(_ playlist: Playlist, isMaster: Bool = false) {
        self.init(
            id: playlist.id,
            name: playlist.name,
            isAlbum: playlist.isAlbum,
            coverName: playlist.artworkImageName,
            coverIsManual: playlist.coverIsManual,
            artist: playlist.artist,
            dateAdded: playlist.dateAdded,
            isMaster: isMaster,
            memberIDs: playlist.audioFileIDs,
            sortOrder: playlist.sortOrder,
            tagKey: playlist.tagKey
        )
    }
}

/// A row of the `import_job` table — the journal that makes an interrupted
/// import resumable instead of a partial loss.
struct ImportJob {
    var id: UUID
    var sourceName: String
    var sourceExt: String
    var sourceURL: Data?
    var stagedName: String?
    var isInbound: Bool
    var state: ImportJobState
    var attempts: Int
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
}

/// The whole library, as the UI sees it. Persisted atomically so the track list
/// and the playlist memberships can never disagree.
struct LibrarySnapshot {
    var tracks: [AudioFile]
    var playlists: [Playlist]
    var masterPlaylistID: UUID?
}

enum LibraryStoreError: LocalizedError {
    case notInitialised
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notInitialised: return "The library store is not open."
        case .openFailed(let m): return "Could not open the library database: \(m)"
        case .prepareFailed(let m): return "Could not prepare a library query: \(m)"
        case .bindFailed(let m): return "Could not bind a value to a library query: \(m)"
        case .stepFailed(let m): return "A library query failed: \(m)"
        case .corrupt(let m): return "The library database is damaged: \(m)"
        }
    }
}

// MARK: - Store

/// Durable, row-granular storage for the library.
///
/// ## Concurrency
///
/// Deliberately **not** an `actor`. The SQLite C API is synchronous, and the
/// existing call sites (`saveAudioFiles()`, `savePlaylists()`, and everything
/// they reach) are synchronous `UIView`-facing methods. Forcing an `actor` here
/// would have meant an `async` boundary through the whole service graph — a much
/// larger change than the storage rework needs. A recursive lock around the
/// handle gives the same mutual exclusion the actor would, without changing a
/// single public signature.
///
/// `synchronous = FULL` is deliberate and is the crux of the import journal: a
/// job row must be on disk *before* any bytes are copied, or the guarantee that
/// an interrupted import is resumable does not hold.
final class LibraryStore: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "store"
    )

    /// `SQLITE_TRANSIENT` — tells SQLite to copy the bound buffer, which is
    /// required because the Swift string/data it points at does not outlive the
    /// `bind` call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?

    let url: URL

    init(url: URL) throws {
        self.url = url
        try open()
        try configure()
        try migrate()
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: Lifecycle

    private func open() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)

        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw LibraryStoreError.openFailed(message)
        }
        self.handle = handle
    }

    private func configure() throws {
        // WAL survives a hard kill mid-write; FULL means the import journal's
        // "row first, then bytes" ordering is actually durable.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = FULL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA busy_timeout = 5000;")
    }

    /// Steps the schema forward. Each step is a transaction, so an interrupted
    /// upgrade leaves the previous version intact rather than a half-built one.
    ///
    /// Written as an explicit ladder rather than a version switch, because the
    /// original shape here — `if current == 0 { ...stamp currentVersion }` — is
    /// wrong the moment a second version exists: a fresh install would create
    /// v1 and immediately *stamp itself as current*, skipping the v1 → v2 step
    /// entirely. That is the kind of bug that only appears on real upgrades,
    /// because a fresh install never takes the `else` branch. See
    /// [C16](14-known-issues.md#c16-a-file-with-no-extension-could-never-be-imported-and-every-failure-was-reported-as-unsupported-format)
    /// for the same pattern of a defect that a build cannot catch.
    private func migrate() throws {
        try withLock {
            var current = Int32(try scalarInt("PRAGMA user_version;"))
            guard current < LibrarySchema.currentVersion else { return }

            if current == 0 {
                try withTransaction {
                    for statement in LibrarySchema.version1 {
                        try exec(statement)
                    }
                    // The version this step *reached*, not `currentVersion`. A
                    // ladder that stamps the newest version skips every step
                    // between the one it ran and the newest, and the next
                    // person to add v3 would get a database stamped v3 that never
                    // ran the v2 → v3 ALTERs.
                    current += 1
                    try exec("PRAGMA user_version = \(current);")
                }
            }

            if current == 1 {
                try withTransaction {
                    let existing = try columnNames(of: "track")
                    for step in LibrarySchema.version2 where !existing.contains(step.column) {
                        try exec(step.sql)
                    }
                    current += 1
                    try exec("PRAGMA user_version = \(current);")
                }
            }

            if current == 2 {
                try withTransaction {
                    let existing = try columnNames(of: "playlist")
                    for step in LibrarySchema.version3 where !existing.contains(step.column) {
                        try exec(step.sql)
                    }
                    current += 1
                    try exec("PRAGMA user_version = \(current);")
                }
            }

            if current < LibrarySchema.currentVersion {
                Self.logger.notice("No migration path from schema v\(current)")
            }
        }
    }

    /// The column names of `table`, or `[]` if it does not exist.
    ///
    /// Used to make `ALTER TABLE ... ADD COLUMN` re-runnable; see
    /// `LibrarySchema.version2`.
    private func columnNames(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        try forEachRow("PRAGMA table_info(\(table));") { stmt in
            // `table_info` is (cid, name, type, notnull, dflt_value, pk).
            if let name = Self.text(stmt, 1) { names.insert(name) }
        }
        return names
    }

    // MARK: Reading

    /// Committed tracks whose tags have never been read, oldest first.
    ///
    /// Ordered oldest-first on purpose: the pre-metadata library is the files a
    /// user has had longest, and if the sweep is interrupted those are the ones
    /// that would otherwise never be reached.
    func loadTracksNeedingTags() throws -> [TrackRecord] {
        try withLock {
            var records: [TrackRecord] = []
            try forEachRow(
                """
                SELECT \(LibrarySchema.trackColumns.joined(separator: ", "))
                FROM track
                WHERE state = \(TrackState.committed.rawValue) AND tags_read = 0
                ORDER BY date_added ASC
                """
            ) { stmt in
                if let record = Self.decodeTrack(stmt) {
                    records.append(record)
                }
            }
            return records
        }
    }

    /// Writes the tag columns of an existing row, and stamps it as read.
    ///
    /// Deliberately narrower than `commitImport`. There is no import job here, no
    /// membership to write and no transaction spanning other rows, so this is a
    /// single statement. What it must *not* do is touch anything the tags do not
    /// describe: `file_name`, `state`, `origin_bookmark` and `imported_via` are
    /// absent from the statement, so a sweep can never move, un-commit or
    /// re-bookmark a file.
    ///
    /// `display_title` and `artwork_name` are included because a first tag read
    /// routinely improves both — the filename-derived title is a placeholder, and
    /// embedded cover art has nowhere else to come from.
    func applyTags(
        to trackID: UUID,
        from metadata: AudioMetadata,
        displayTitle: String,
        artworkName: String?
    ) throws {
        try withLock {
            try exec(
                """
                UPDATE track SET
                    display_title = ?,
                    artwork_name  = COALESCE(?, artwork_name),
                    artist        = ?, album = ?, album_artist = ?, genre = ?,
                    release_year  = ?, track_number = ?, track_total = ?,
                    disc_number   = ?, disc_total = ?, comment = ?,
                    sample_rate   = ?, channel_count = ?,
                    tags_read     = 1
                WHERE id = ?;
                """,
                bindings: [
                    .text(displayTitle),
                    artworkName.map { Binding.text($0) } ?? .null,
                    metadata.artist.map { Binding.text($0) } ?? .null,
                    metadata.album.map { Binding.text($0) } ?? .null,
                    metadata.albumArtist.map { Binding.text($0) } ?? .null,
                    metadata.genre.map { Binding.text($0) } ?? .null,
                    metadata.year.map { Binding.int(Int64($0)) } ?? .null,
                    metadata.trackNumber.map { Binding.int(Int64($0)) } ?? .null,
                    metadata.trackTotal.map { Binding.int(Int64($0)) } ?? .null,
                    metadata.discNumber.map { Binding.int(Int64($0)) } ?? .null,
                    metadata.discTotal.map { Binding.int(Int64($0)) } ?? .null,
                    metadata.comment.map { Binding.text($0) } ?? .null,
                    metadata.sampleRate.map { Binding.double($0) } ?? .null,
                    metadata.channelCount.map { Binding.int(Int64($0)) } ?? .null,
                    .text(trackID.uuidString),
                ]
            )
        }
    }

    /// One committed track, or `nil` if there is no such row.
    ///
    /// Backs the manual "refresh tags" path, which has a row id from the UI and
    /// no interest in loading the library to find it.
    func loadTrack(id: UUID) throws -> TrackRecord? {
        try withLock {
            var found: TrackRecord?
            try forEachRow(
                """
                SELECT \(LibrarySchema.trackColumns.joined(separator: ", "))
                FROM track
                WHERE id = ? AND state = \(TrackState.committed.rawValue)
                """,
                bindings: [.text(id.uuidString)]
            ) { stmt in
                found = Self.decodeTrack(stmt)
            }
            return found
        }
    }

    /// Committed tracks, newest first — the order the Songs tab uses.
    func loadTracks() throws -> [TrackRecord] {
        try withLock {
            var records: [TrackRecord] = []
            try forEachRow(
                """
                SELECT \(LibrarySchema.trackColumns.joined(separator: ", "))
                FROM track
                WHERE state = \(TrackState.committed.rawValue)
                ORDER BY date_added DESC
                """
            ) { stmt in
                if let record = Self.decodeTrack(stmt) {
                    records.append(record)
                }
            }
            return records
        }
    }

    /// Every track row regardless of state, for diagnostics and reconciliation.
    func loadAllTrackRecords() throws -> [TrackRecord] {
        try withLock {
            var records: [TrackRecord] = []
            try forEachRow(
                """
                SELECT \(LibrarySchema.trackColumns.joined(separator: ", "))
                FROM track
                ORDER BY date_added DESC
                """
            ) { stmt in
                if let record = Self.decodeTrack(stmt) { records.append(record) }
            }
            return records
        }
    }

    /// Playlists in persisted order, each with its ordered membership.
    func loadPlaylists() throws -> [PlaylistRecord] {
        try withLock {
            var membership: [UUID: [UUID]] = [:]
            try forEachRow(
                "SELECT playlist_id, track_id FROM playlist_member ORDER BY playlist_id, position"
            ) { stmt in
                guard let pid = Self.text(stmt, 0).flatMap(UUID.init(uuidString:)),
                      let tid = Self.text(stmt, 1).flatMap(UUID.init(uuidString:))
                else { return }
                membership[pid, default: []].append(tid)
            }

            var records: [PlaylistRecord] = []
            try forEachRow(
                """
                SELECT id, name, is_album, cover_name, cover_manual, artist,
                       date_added, is_master, sort_order, tag_key
                FROM playlist
                ORDER BY date_added DESC
                """
            ) { stmt in
                guard let idText = Self.text(stmt, 0),
                      let id = UUID(uuidString: idText)
                else { return }

                records.append(
                    PlaylistRecord(
                        id: id,
                        name: Self.text(stmt, 1) ?? "",
                        isAlbum: Self.int(stmt, 2) != 0,
                        coverName: Self.text(stmt, 3),
                        coverIsManual: Self.int(stmt, 4) != 0,
                        artist: Self.text(stmt, 5),
                        dateAdded: Date(timeIntervalSince1970: Self.double(stmt, 6)),
                        isMaster: Self.int(stmt, 7) != 0,
                        memberIDs: membership[id] ?? [],
                        sortOrder: Self.optionalDouble(stmt, 8),
                        tagKey: Self.text(stmt, 9)
                    )
                )
            }
            return records
        }
    }

    /// The master playlist id, or `nil` when there is no live master.
    ///
    /// Joins against `playlist` rather than reading `meta` alone. `meta` holds the
    /// pointer as text and cannot cascade when the row is deleted, so it can name
    /// a playlist that is gone. Handing that id back would push it into
    /// `commitImport`, where it cannot resolve — and the caller has no way to tell
    /// "no master configured" from "master configured but missing", so it would
    /// have no choice but to trust it. Returning `nil` instead lets the caller do
    /// what it already does for a missing master: create one.
    func loadMasterPlaylistID() throws -> UUID? {
        try withLock {
            try query(
                """
                SELECT m.value FROM meta AS m
                JOIN playlist AS p ON p.id = m.value
                WHERE m.key = 'master_playlist_id';
                """
            ) { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                guard let text = Self.text(stmt, 0) else { return nil }
                return UUID(uuidString: text)
            }
        }
    }

    // MARK: Writing

    /// Mirrors the whole projection in one transaction.
    ///
    /// This replaces two independent `UserDefaults` writes, which is what let an
    /// imported track exist in the file list while its id was in no playlist —
    /// present on disk, invisible in the UI, forever.
    ///
    /// This is a *mirror*, so it both creates and destroys rows: `prune` deletes
    /// anything the projection omits. That is why the master pointer is retracted
    /// when the row it names did not survive — see `clearMasterPlaylistID`.
    func persist(_ snapshot: LibrarySnapshot) throws {
        try withLock {
            try withTransaction {
                let trackIDs = snapshot.tracks.map { $0.id.uuidString }
                for track in snapshot.tracks {
                    try upsertTrack(track)
                }
                try prune(table: "track", keeping: trackIDs)

                let playlistIDs = snapshot.playlists.map { $0.id.uuidString }
                let knownTrackIDs = Set(trackIDs)
                for playlist in snapshot.playlists {
                    try upsertPlaylist(
                        playlist,
                        isMaster: playlist.id == snapshot.masterPlaylistID,
                        keepingTracks: knownTrackIDs
                    )
                }
                try prune(table: "playlist", keeping: playlistIDs)

                if let master = snapshot.masterPlaylistID,
                   try playlistExists(master) {
                    try writeMasterPlaylistID(master)
                } else {
                    try clearMasterPlaylistID()
                }
            }
        }
    }

    private func playlistExists(_ id: UUID) throws -> Bool {
        try scalarInt(
            "SELECT EXISTS (SELECT 1 FROM playlist WHERE id = ?);",
            bindings: [.text(id.uuidString)]
        ) == 1
    }

    private func writeMasterPlaylistID(_ id: UUID) throws {
        try exec(
            """
            INSERT INTO meta (key, value) VALUES ('master_playlist_id', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """,
            bindings: [.text(id.uuidString)]
        )
    }

    /// Retracts the master pointer.
    ///
    /// Deleting a `playlist` row does **not** cascade into `meta`, which stores
    /// the pointer as an opaque string in a key/value table rather than a
    /// foreign key. So `prune(table: "playlist")` could delete the master while
    /// the pointer survived, and every later launch would read back an id with no
    /// row behind it. `PlaylistService` would carry that dead id into
    /// `commitImport`, where the membership insert could not resolve it — see
    /// `addMembership`.
    ///
    /// The caller asks the database rather than trusting the snapshot, because
    /// "the projection omits the master" and "the row will not exist" are not the
    /// same claim: `prune` refuses to delete anything when handed an empty
    /// projection, so a row can outlive a snapshot that never mentioned it.
    private func clearMasterPlaylistID() throws {
        try exec("DELETE FROM meta WHERE key = 'master_playlist_id';")
    }

    /// Upserts a track row.
    ///
    /// Only the columns derivable from `AudioFile` are written. `state`,
    /// `source_name`, `origin_bookmark`, `reject_reason` and `imported_via` are
    /// left alone on conflict, because the view-facing model has no opinion
    /// about them and must not be able to erase them.
    ///
    /// The tag columns use `COALESCE(excluded.x, track.x)` rather than plain
    /// assignment. `AudioFile` is a *projection* of the row, so a caller that
    /// rebuilds one from a subset of its fields — `ArtworkService.setArtwork`
    /// does exactly this when the user picks a cover — would otherwise blank the
    /// artist and album of every track whose artwork they change. A nil tag means
    /// "this snapshot did not carry it", not "clear it".
    private func upsertTrack(_ track: AudioFile) throws {
        let ext = (track.fileName as NSString).pathExtension
        try exec(
            """
            INSERT INTO track (id, file_name, display_title, ext, duration, date_added,
                               artwork_name, artist, album, album_artist, genre,
                               release_year, track_number, track_total,
                               disc_number, disc_total, comment)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                file_name     = excluded.file_name,
                display_title = excluded.display_title,
                ext           = excluded.ext,
                duration      = excluded.duration,
                date_added    = excluded.date_added,
                artwork_name  = excluded.artwork_name,
                artist        = COALESCE(excluded.artist, track.artist),
                album         = COALESCE(excluded.album, track.album),
                album_artist  = COALESCE(excluded.album_artist, track.album_artist),
                genre         = COALESCE(excluded.genre, track.genre),
                release_year  = COALESCE(excluded.release_year, track.release_year),
                track_number  = COALESCE(excluded.track_number, track.track_number),
                track_total   = COALESCE(excluded.track_total, track.track_total),
                disc_number   = COALESCE(excluded.disc_number, track.disc_number),
                disc_total    = COALESCE(excluded.disc_total, track.disc_total),
                comment       = COALESCE(excluded.comment, track.comment);
            """,
            bindings: [
                .text(track.id.uuidString),
                .text(track.fileName),
                .text(track.title),
                .text(ext),
                .double(Double(track.audioDuration)),
                .double(track.dateAdded.timeIntervalSince1970),
                track.artworkImageName.map { .text($0) } ?? .null,
                track.artist.map { .text($0) } ?? .null,
                track.album.map { .text($0) } ?? .null,
                track.albumArtist.map { .text($0) } ?? .null,
                track.genre.map { .text($0) } ?? .null,
                track.year.map { .int(Int64($0)) } ?? .null,
                track.trackNumber.map { .int(Int64($0)) } ?? .null,
                track.trackTotal.map { .int(Int64($0)) } ?? .null,
                track.discNumber.map { .int(Int64($0)) } ?? .null,
                track.discTotal.map { .int(Int64($0)) } ?? .null,
                track.comment.map { .text($0) } ?? .null,
            ]
        )
    }

    /// - Parameter keepingTracks: The ids of every track row that exists after
    ///   this snapshot's track writes, as UUID strings. Membership is filtered
    ///   against it because `foreign_keys` is `ON` with `ON DELETE CASCADE`: a
    ///   single member id with no track row fails the insert and rolls back the
    ///   entire snapshot, silently disabling all persistence. Only the master
    ///   playlist's membership is repaired on load, so a stale id in any *user*
    ///   playlist would otherwise be enough to do that.
    private func upsertPlaylist(
        _ playlist: Playlist,
        isMaster: Bool,
        keepingTracks: Set<String>
    ) throws {
        try exec(
            """
            INSERT INTO playlist (id, name, is_album, cover_name, cover_manual, artist, date_added, is_master, sort_order, tag_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name         = excluded.name,
                is_album     = excluded.is_album,
                cover_name   = excluded.cover_name,
                cover_manual = excluded.cover_manual,
                artist       = excluded.artist,
                date_added   = excluded.date_added,
                is_master    = excluded.is_master,
                sort_order   = excluded.sort_order,
                tag_key      = excluded.tag_key;
            """,
            bindings: [
                .text(playlist.id.uuidString),
                .text(playlist.name),
                .int(playlist.isAlbum ? 1 : 0),
                playlist.artworkImageName.map { .text($0) } ?? .null,
                .int(playlist.coverIsManual ? 1 : 0),
                playlist.artist.map { .text($0) } ?? .null,
                .double(playlist.dateAdded.timeIntervalSince1970),
                .int(isMaster ? 1 : 0),
                playlist.sortOrder.map { .double($0) } ?? .null,
                playlist.tagKey.map { .text($0) } ?? .null,
            ]
        )

        // Membership is a full mirror of the projection's ordered id array, minus
        // ids that have no track row (see `keepingTracks`).
        let members = playlist.audioFileIDs.filter { keepingTracks.contains($0.uuidString) }
        if members.count != playlist.audioFileIDs.count {
            Self.logger.notice(
                """
                Dropped \(playlist.audioFileIDs.count - members.count) orphaned member(s) from \
                playlist \(playlist.name, privacy: .public); no matching track row.
                """
            )
        }

        try exec("DELETE FROM playlist_member WHERE playlist_id = ?;",
                 bindings: [.text(playlist.id.uuidString)])

        for (position, memberID) in members.enumerated() {
            try exec(
                "INSERT OR REPLACE INTO playlist_member (playlist_id, track_id, position) VALUES (?, ?, ?);",
                bindings: [
                    .text(playlist.id.uuidString),
                    .text(memberID.uuidString),
                    .int(Int64(position)),
                ]
            )
        }
    }

    /// Deletes rows whose id is not in `keeping`.
    ///
    /// ## The empty-set guard
    ///
    /// This is the single most important line of defence in the whole store. The
    /// old code deleted every file on disk that was not in the index, and the
    /// index went empty whenever a decode failed — so "I failed to read my own
    /// state" became "I deleted your music". A caller that hands over an empty
    /// projection is far more likely to be broken than to be telling the truth,
    /// so an empty set is never allowed to prune.
    private func prune(table: String, keeping ids: [String]) throws {
        guard !ids.isEmpty else {
            Self.logger.notice(
                "Refusing to prune \(table, privacy: .public): projection was empty."
            )
            return
        }
        // `table` is never caller-supplied — both call sites pass a literal.
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try exec(
            "DELETE FROM \(table) WHERE id NOT IN (\(placeholders));",
            bindings: ids.map { .text($0) }
        )
    }

    // MARK: Import journal

    /// Records an intent to import, and commits it, before any bytes are touched.
    ///
    /// - Parameter id: Caller-supplied so an id that is already encoded in a
    ///   filename — the share extension's `<uuid>--<name>` — becomes the journal
    ///   row's key. A generated id would orphan the job row, which would then be
    ///   rediscovered as resumable on every launch and retried forever.
    /// - Returns: The job id. Pass it to every subsequent state transition.
    @discardableResult
    func createImportJob(
        id: UUID = UUID(),
        sourceName: String,
        sourceExt: String,
        sourceURL: Data?,
        origin: ImportOrigin
    ) throws -> UUID {
        let now = Date()
        // Hoisted out of the `bindings:` literal: a chain of `Optional.map`
        // plus `??` alongside inferred integer literals is more than the type
        // checker resolves in reasonable time.
        let urlBinding: Binding = sourceURL.map { Binding.blob($0) } ?? .null
        let originBinding = Binding.int(origin == .shareExtension ? 1 : 0)
        try withLock {
            try exec(
                """
                INSERT INTO import_job (id, source_name, source_ext, source_url, inbound,
                                        state, attempts, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_name  = excluded.source_name,
                    source_ext   = excluded.source_ext,
                    source_url   = COALESCE(excluded.source_url, import_job.source_url),
                    inbound      = excluded.inbound,
                    updated_at   = excluded.updated_at;
                """,
                bindings: [
                    .text(id.uuidString),
                    .text(sourceName),
                    .text(sourceExt),
                    urlBinding,
                    originBinding,
                    .int(Int64(ImportJobState.queued.rawValue)),
                    .double(now.timeIntervalSince1970),
                    .double(now.timeIntervalSince1970),
                ]
            )
        }
        return id
    }

    func updateImportJob(
        _ id: UUID,
        state: ImportJobState,
        stagedName: String? = nil,
        error: String? = nil,
        bumpAttempts: Bool = false,
        bookmark: Data? = nil
    ) throws {
        let stagedBinding: Binding = stagedName.map { Binding.text($0) } ?? .null
        let bookmarkBinding: Binding = bookmark.map { Binding.blob($0) } ?? .null
        let errorBinding: Binding = error.map { Binding.text($0) } ?? .null
        let attemptsBinding = Binding.int(bumpAttempts ? 1 : 0)
        try withLock {
            try exec(
                """
                UPDATE import_job
                SET state       = ?,
                    staged_name = COALESCE(?, staged_name),
                    source_url  = COALESCE(?, source_url),
                    last_error  = COALESCE(?, last_error),
                    attempts    = attempts + ?,
                    updated_at  = ?
                WHERE id = ?;
                """,
                bindings: [
                    .int(Int64(state.rawValue)),
                    stagedBinding,
                    bookmarkBinding,
                    errorBinding,
                    attemptsBinding,
                    .double(Date().timeIntervalSince1970),
                    .text(id.uuidString),
                ]
            )
        }
    }

    /// Jobs the pipeline should pick up: anything not yet finished.
    func loadResumableImportJobs() throws -> [ImportJob] {
        try withLock {
            let finished: [ImportJobState] = [.committed, .rejected]
            let placeholders = Array(
                repeating: "?", count: finished.count
            ).joined(separator: ",")

            var jobs: [ImportJob] = []
            try forEachRow(
                """
                SELECT id, source_name, source_ext, source_url, staged_name, inbound,
                       state, attempts, last_error, created_at, updated_at
                FROM import_job
                WHERE state NOT IN (\(placeholders))
                ORDER BY created_at ASC
                """,
                bindings: finished.map { .int(Int64($0.rawValue)) }
            ) { stmt in
                guard let job = Self.decodeJob(stmt) else { return }
                jobs.append(job)
            }
            return jobs
        }
    }

    func importJob(id: UUID) throws -> ImportJob? {
        try withLock {
            try query(
                """
                SELECT id, source_name, source_ext, source_url, staged_name, inbound,
                       state, attempts, last_error, created_at, updated_at
                FROM import_job WHERE id = ?;
                """,
                bindings: [.text(id.uuidString)]
            ) { stmt in
                guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
                return Self.decodeJob(stmt)
            }
        }
    }

    /// The commit. Track row + membership + journal transition, atomically.
    ///
    /// After this returns, the track is in the library. Before it returns,
    /// nothing about the import is visible and any bytes already copied are
    /// still staged — so a failure anywhere in here leaves a recoverable job,
    /// never a half-imported library entry.
    func commitImport(
        jobID: UUID,
        record: TrackRecord,
        addToPlaylist playlistID: UUID?,
        position: Int?
    ) throws {
        let sourceNameBinding: Binding = record.sourceName.map { Binding.text($0) } ?? .null
        let artworkBinding: Binding = record.artworkName.map { Binding.text($0) } ?? .null
        let bookmarkBinding: Binding = record.originBookmark.map { Binding.blob($0) } ?? .null
        let importedViaBinding: Binding = record.importedVia.map { Binding.text($0.rawValue) } ?? .null
        try withLock {
            try withTransaction {
                try exec(
                    """
                    INSERT INTO track (id, file_name, source_name, display_title, ext,
                                       byte_size, duration, date_added, artwork_name,
                                       origin_bookmark, state, imported_via,
                                       artist, album, album_artist, genre,
                                       release_year, track_number, track_total,
                                       disc_number, disc_total, comment,
                                       sample_rate, channel_count, tags_read)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        file_name     = excluded.file_name,
                        source_name   = COALESCE(excluded.source_name, track.source_name),
                        display_title = excluded.display_title,
                        ext           = excluded.ext,
                        byte_size     = excluded.byte_size,
                        duration      = excluded.duration,
                        artwork_name  = excluded.artwork_name,
                        origin_bookmark = COALESCE(excluded.origin_bookmark, track.origin_bookmark),
                        state         = excluded.state,
                        artist        = excluded.artist,
                        album         = excluded.album,
                        album_artist  = excluded.album_artist,
                        genre         = excluded.genre,
                        release_year  = excluded.release_year,
                        track_number  = excluded.track_number,
                        track_total   = excluded.track_total,
                        disc_number   = excluded.disc_number,
                        disc_total    = excluded.disc_total,
                        comment       = excluded.comment,
                        sample_rate   = excluded.sample_rate,
                        channel_count = excluded.channel_count,
                        tags_read      = excluded.tags_read;
                    """,
                    bindings: [
                        .text(record.id.uuidString),
                        .text(record.fileName),
                        sourceNameBinding,
                        .text(record.displayTitle),
                        .text(record.ext),
                        .int(record.byteSize),
                        .double(Double(record.duration)),
                        .double(record.dateAdded.timeIntervalSince1970),
                        artworkBinding,
                        bookmarkBinding,
                        .int(Int64(record.state.rawValue)),
                        importedViaBinding,
                        record.artist.map { Binding.text($0) } ?? .null,
                        record.album.map { Binding.text($0) } ?? .null,
                        record.albumArtist.map { Binding.text($0) } ?? .null,
                        record.genre.map { Binding.text($0) } ?? .null,
                        record.year.map { Binding.int(Int64($0)) } ?? .null,
                        record.trackNumber.map { Binding.int(Int64($0)) } ?? .null,
                        record.trackTotal.map { Binding.int(Int64($0)) } ?? .null,
                        record.discNumber.map { Binding.int(Int64($0)) } ?? .null,
                        record.discTotal.map { Binding.int(Int64($0)) } ?? .null,
                        record.comment.map { Binding.text($0) } ?? .null,
                        record.sampleRate.map { Binding.double($0) } ?? .null,
                        record.channelCount.map { Binding.int(Int64($0)) } ?? .null,
                        // The pipeline always reads tags before committing, so a
                        // committed row never needs the backfill sweep.
                        .int(record.tagsRead ? 1 : 0),
                    ]
                )

                if let playlistID {
                    let next = try nextPosition(in: playlistID)
                    try addMembership(
                        playlistID: playlistID,
                        trackID: record.id,
                        position: position.map(Int64.init) ?? next
                    )
                }

                try exec(
                    """
                    UPDATE import_job
                    SET state = ?, staged_name = NULL, updated_at = ?
                    WHERE id = ?;
                    """,
                    bindings: [
                        .int(Int64(ImportJobState.committed.rawValue)),
                        .double(Date().timeIntervalSince1970),
                        .text(jobID.uuidString),
                    ]
                )
            }
        }
    }

    /// Marks a job refused and records a `rejected` track row, so the reason
    /// survives relaunch and can be shown to the user.
    func rejectImport(jobID: UUID, sourceName: String, reason: String) throws {
        try withLock {
            try withTransaction {
                try exec(
                    """
                    INSERT INTO track (id, file_name, source_name, display_title, ext,
                                       duration, date_added, state, reject_reason, imported_via)
                    VALUES (?, '', ?, ?, '', 0, ?, ?, ?, 'documentPicker')
                    ON CONFLICT(id) DO UPDATE SET
                        state        = excluded.state,
                        reject_reason = excluded.reject_reason;
                    """,
                    bindings: [
                        .text(jobID.uuidString),
                        .text(sourceName),
                        .text((sourceName as NSString).deletingPathExtension),
                        .double(Date().timeIntervalSince1970),
                        .int(Int64(TrackState.rejected.rawValue)),
                        .text(reason),
                    ]
                )

                try exec(
                    "UPDATE import_job SET state = ?, last_error = ?, updated_at = ? WHERE id = ?;",
                    bindings: [
                        .int(Int64(ImportJobState.rejected.rawValue)),
                        .text(reason),
                        .double(Date().timeIntervalSince1970),
                        .text(jobID.uuidString),
                    ]
                )
            }
        }
    }

    /// Adds membership for a committed track that has none.
    ///
    /// The self-heal for the "present on disk, invisible in the UI" failure: a
    /// track with no membership row is unreachable from `sortedAudioFiles`,
    /// which is driven entirely by the master playlist.
    ///
    /// - Returns: `true` when a row was inserted. `false` when the track already
    ///   had one, or when `playlistID` does not resolve — the caller's two cases
    ///   are not interchangeable, so this reports the insert's own result rather
    ///   than assuming it happened.
    @discardableResult
    func ensureMembership(trackID: UUID, in playlistID: UUID) throws -> Bool {
        try withLock {
            return try withTransaction {
                let existing = try scalarInt(
                    "SELECT COUNT(*) FROM playlist_member WHERE playlist_id = ? AND track_id = ?;",
                    bindings: [.text(playlistID.uuidString), .text(trackID.uuidString)]
                )
                guard existing == 0 else { return false }

                let next = try nextPosition(in: playlistID)
                return try addMembership(
                    playlistID: playlistID,
                    trackID: trackID,
                    position: next
                )
            }
        }
    }

    func setTrackState(_ id: UUID, _ state: TrackState) throws {
        try withLock {
            try exec(
                "UPDATE track SET state = ? WHERE id = ?;",
                bindings: [.int(Int64(state.rawValue)), .text(id.uuidString)]
            )
        }
    }

    /// Committed tracks with no membership in the master playlist.
    func loadOrphanedTrackIDs(masterID: UUID) throws -> [UUID] {
        try withLock {
            var ids: [UUID] = []
            try forEachRow(
                """
                SELECT t.id FROM track t
                LEFT JOIN playlist_member m
                       ON m.track_id = t.id AND m.playlist_id = ?
                WHERE t.state = ? AND m.track_id IS NULL;
                """,
                bindings: [
                    .text(masterID.uuidString),
                    .int(Int64(TrackState.committed.rawValue)),
                ]
            ) { stmt in
                guard let text = Self.text(stmt, 0), let id = UUID(uuidString: text) else { return }
                ids.append(id)
            }
            return ids
        }
    }

    /// Paths currently claimed by a committed track, for reconciliation.
    func loadCommittedFileNames() throws -> [String: UUID] {
        try withLock {
            var map: [String: UUID] = [:]
            try forEachRow(
                "SELECT id, file_name FROM track WHERE state = ?;",
                bindings: [.int(Int64(TrackState.committed.rawValue))]
            ) { stmt in
                guard let name = Self.text(stmt, 1),
                      let id = UUID(uuidString: Self.text(stmt, 0) ?? "")
                else { return }
                map[name] = id
            }
            return map
        }
    }

    // MARK: SQLite plumbing

    private enum Binding {
        case text(String)
        case blob(Data)
        case int(Int64)
        case double(Double)
        case null
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Runs a statement for its effect, discarding any rows.
    ///
    /// The statement is drained to completion. `sqlite3_prepare_v2` only *compiles*
    /// SQL — nothing is executed until the statement is stepped at least once — so
    /// finalising without stepping discards the statement entirely.
    private func exec(_ sql: String, bindings: [Binding] = []) throws {
        try withLock {
            try query(sql, bindings: bindings) { stmt in
                try drain(stmt)
            }
        }
    }

    /// Steps `stmt` until it is finished, invoking `body` once per row.
    ///
    /// Every read and write in this store goes through here. `SQLITE_ROW` is
    /// tolerated rather than treated as the end because statements such as
    /// `PRAGMA journal_mode = WAL` answer with a row before completing.
    private func drain(
        _ stmt: OpaquePointer,
        onRow body: (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        guard let handle else { throw LibraryStoreError.notInitialised }

        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try body(stmt)
            status = sqlite3_step(stmt)
        }

        guard status == SQLITE_DONE else {
            throw LibraryStoreError.stepFailed(errorMessage(handle))
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else { throw LibraryStoreError.notInitialised }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            throw LibraryStoreError.prepareFailed(errorMessage(handle))
        }
        defer { sqlite3_finalize(stmt) }

        let bindCode = Self.bind(bindings, to: stmt)
        guard bindCode == SQLITE_OK else {
            throw LibraryStoreError.bindFailed(errorMessage(handle))
        }

        return try body(stmt)
    }

    /// Runs `sql` and calls `body` once per row.
    private func forEachRow(
        _ sql: String,
        bindings: [Binding] = [],
        _ body: (OpaquePointer) throws -> Void
    ) throws {
        try query(sql, bindings: bindings) { stmt in
            try drain(stmt, onRow: body)
        }
    }

    private func scalarInt(_ sql: String, bindings: [Binding] = []) throws -> Int64 {
        try query(sql, bindings: bindings) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func nextPosition(in playlistID: UUID) throws -> Int64 {
        try scalarInt(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_member WHERE playlist_id = ?;",
            bindings: [.text(playlistID.uuidString)]
        )
    }

    /// Writes one `playlist_member` row, if that playlist exists.
    ///
    /// Membership is bookkeeping about a track that has already been committed;
    /// it is not what makes the import legal. So a playlist id that does not
    /// resolve must skip the row rather than abort the caller — the same rule
    /// C16 established for a file that cannot be decoded.
    ///
    /// The obvious spelling, `INSERT OR IGNORE`, does **not** work here. SQLite's
    /// `ON CONFLICT` clause resolves UNIQUE, NOT NULL and CHECK violations only:
    /// "The ON CONFLICT clause does not apply to FOREIGN KEY constraints." A
    /// dangling `playlist_id` therefore surfaced as `SQLITE_CONSTRAINT_FOREIGNKEY`
    /// from `sqlite3_step`, which rolled back the *track* row inserted earlier in
    /// the same transaction — a file staged, decoded and validated successfully and
    /// then discarded, reported as a database fault. That is the failure this
    /// helper exists to make unrepresentable.
    ///
    /// `SELECT … WHERE EXISTS` keeps the check and the insert in one statement, so
    /// there is no window between them, and `changes()` reports whether the row
    /// was actually written rather than the caller inferring it.
    ///
    /// - Returns: `true` when a row was inserted.
    @discardableResult
    private func addMembership(
        playlistID: UUID,
        trackID: UUID,
        position: Int64
    ) throws -> Bool {
        try exec(
            """
            INSERT OR IGNORE INTO playlist_member (playlist_id, track_id, position)
            SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM playlist WHERE id = ?);
            """,
            bindings: [
                .text(playlistID.uuidString),
                .text(trackID.uuidString),
                .int(position),
                .text(playlistID.uuidString),
            ]
        )
        return changes > 0
    }

    private func errorMessage(_ handle: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Rows changed by the most recent statement on this connection.
    private var changes: Int {
        Int(sqlite3_changes(handle))
    }

    // MARK: Binding / decoding

    /// Binds `bindings` to `stmt`, returning the first non-`SQLITE_OK` code.
    ///
    /// Every `sqlite3_bind_*` call reports failure, and every one of them used to
    /// have that report thrown away: a bind that failed left the parameter NULL,
    /// the statement still "succeeded", and the write landed with the wrong value
    /// in it. That is the same silent-no-op shape as C15, one layer earlier in the
    /// same write. The codes are cheap to check, so `query` checks them.
    ///
    /// - Returns: `SQLITE_OK` if every binding was written, otherwise the code
    ///   from the first binding that failed.
    private static func bind(_ bindings: [Binding], to stmt: OpaquePointer) -> Int32 {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch binding {
            case .text(let value):
                code = value.withCString {
                    sqlite3_bind_text(stmt, index, $0, -1, transient)
                }
            case .blob(let value):
                code = value.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), transient)
                }
            case .int(let value):
                code = sqlite3_bind_int64(stmt, index, value)
            case .double(let value):
                code = sqlite3_bind_double(stmt, index, value)
            case .null:
                code = sqlite3_bind_null(stmt, index)
            }
            if code != SQLITE_OK { return code }
        }
        return SQLITE_OK
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func data(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func int(_ stmt: OpaquePointer, _ index: Int32) -> Int32 {
        sqlite3_column_int(stmt, index)
    }

    private static func double(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    /// A nullable REAL, so `NULL` reads back as `nil` rather than as zero.
    ///
    /// `double` cannot tell those apart, and for a column whose whole meaning is
    /// "has this been set" that difference is the value. `sort_order` at `0` and
    /// `sort_order` unset are different answers.
    private static func optionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    /// `sqlite3_column_int` for a **nullable** column.
    ///
    /// `sqlite3_column_int` cannot distinguish NULL from 0, and every tag column
    /// added in schema v2 is nullable with NULL meaning "not tagged". Reading
    /// them through `int(_:_:)` would therefore give every untagged track a
    /// track number of 0 and a release year of 0 — values that would then be
    /// written back over the real tags on the next save. Checking the column type
    /// is the only way to keep "no tag" distinct from "tagged as zero".
    private static func optInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    /// `sqlite3_column_double` for a **nullable** column. See `optInt(_:_:)`.
    private static func optDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private static func decodeTrack(_ stmt: OpaquePointer) -> TrackRecord? {
        guard let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) else { return nil }

        return TrackRecord(
            id: id,
            fileName: text(stmt, 1) ?? "",
            sourceName: text(stmt, 2),
            displayTitle: text(stmt, 3) ?? "",
            ext: text(stmt, 4) ?? "",
            byteSize: sqlite3_column_int64(stmt, 5),
            duration: Float(double(stmt, 6)),
            dateAdded: Date(timeIntervalSince1970: double(stmt, 7)),
            artworkName: text(stmt, 8),
            originBookmark: data(stmt, 9),
            state: TrackState(rawValue: int(stmt, 10)) ?? .committed,
            rejectReason: text(stmt, 11),
            importedVia: text(stmt, 12).flatMap(ImportOrigin.init(rawValue:)),
            artist: text(stmt, 13),
            album: text(stmt, 14),
            albumArtist: text(stmt, 15),
            genre: text(stmt, 16),
            year: optInt(stmt, 17),
            trackNumber: optInt(stmt, 18),
            trackTotal: optInt(stmt, 19),
            discNumber: optInt(stmt, 20),
            discTotal: optInt(stmt, 21),
            comment: text(stmt, 22),
            sampleRate: optDouble(stmt, 23),
            channelCount: optInt(stmt, 24),
            tagsRead: int(stmt, 25) != 0
        )
    }

    private static func decodeJob(_ stmt: OpaquePointer) -> ImportJob? {
        guard let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) else { return nil }

        return ImportJob(
            id: id,
            sourceName: text(stmt, 1) ?? "",
            sourceExt: text(stmt, 2) ?? "",
            sourceURL: data(stmt, 3),
            stagedName: text(stmt, 4),
            isInbound: int(stmt, 5) != 0,
            state: ImportJobState(rawValue: int(stmt, 6)) ?? .queued,
            attempts: Int(sqlite3_column_int64(stmt, 7)),
            lastError: text(stmt, 8),
            createdAt: Date(timeIntervalSince1970: double(stmt, 9)),
            updatedAt: Date(timeIntervalSince1970: double(stmt, 10))
        )
    }
}
