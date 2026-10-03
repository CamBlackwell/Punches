import Foundation
import AVFoundation
import os

/// One-time, non-destructive adoption of the pre-store layout.
///
/// ## Why this is a migration and not a load
///
/// Three separate things could be true at any moment, and the old code
/// conflated all of them into one array:
///
/// - the index said a file existed, and it did;
/// - the index said a file existed, and it had been deleted or lost;
/// - **a file existed that the index did not mention** — because an import had
///   copied the bytes and then failed before its index write.
///
///That third case is the reported bug: a subset of songs imported cleanly and
///were then unlinked, so on the next launch there was no record of them at all
///and `cleanupOrphanedFiles` removed the bytes. Any migration that trusts the
///index therefore destroys exactly the files it is supposed to recover.
///
/// So the index is used only to *enrich* what is on disk, never to decide what
/// should be. Every audio file found anywhere is adopted; index entries with no
///file become `.missing` rows rather than being dropped. Nothing is deleted, in
///either direction.
struct LibraryMigration {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "migration"
    )

    struct Summary {
        var adoptedFromDisk = 0
        var recoveredFromIndex = 0
        var markedMissing = 0
        var playlistsRebuilt = 0
        var unreadableIndexRecords = 0
        var skippedBecauseAlreadyDone = false
    }

    let environment: LibraryEnvironment
    let store: LibraryStore
    let defaults: UserDefaults

    private static let doneKey = "legacy_layout_migrated_v2"

    /// Legacy `UserDefaults` keys. Left in place afterwards — they are evidence,
    /// and nothing reads them once the store is authoritative.
    private enum LegacyKey {
        static let tracks = "savedAudioFiles"
        static let playlists = "savedPlaylists"
        static let masterPlaylist = "masterPlaylistID"
    }

    // MARK: - Entry point

    /// Runs the migration if it has not already run for this layout.
    func runIfNeeded() async -> Summary {
        var summary = Summary()

        guard !isComplete else {
            summary.skippedBecauseAlreadyDone = true
            return summary
        }

        // Only run against an empty store. If tracks already exist, a previous
        // run succeeded and re-running would re-adopt files it already moved.
        let existing = (try? store.loadTracks()) ?? []
        let pendingOnDisk = environment.legacyAudioFiles()

        guard !existing.isEmpty || !pendingOnDisk.isEmpty else {
            markComplete()
            return summary
        }

        if !existing.isEmpty {
            Self.logger.notice(
                "Store already has \(existing.count) track(s); skipping layout migration"
            )
            markComplete()
            return summary
        }

        Self.logger.notice("Adopting legacy layout from \(environment.root.path, privacy: .public)")

        adoptArtwork()
        let index = loadLegacyIndex()
        summary.unreadableIndexRecords = index.unreadable

        summary.adoptedFromDisk = await adoptUnindexedFiles(
            index: index.byName,
            onDisk: pendingOnDisk
        )
        summary.recoveredFromIndex = await recoverIndexedFiles(index.records)
        summary.playlistsRebuilt = rebuildPlaylists(index.playlists, masterID: index.masterID)
        summary.markedMissing = index.records.count - summary.recoveredFromIndex

        markComplete()
        Self.logger.notice(
            """
            Legacy migration: \(summary.adoptedFromDisk) adopted from disk, \
            \(summary.recoveredFromIndex) recovered from the old index, \
            \(summary.markedMissing) marked missing, \
            \(summary.playlistsRebuilt) playlists rebuilt, \
            \(summary.unreadableIndexRecords) index record(s) unreadable
            """
        )
        return summary
    }

    private var isComplete: Bool {
        guard let value = defaults.string(forKey: Self.doneKey) else { return false }
        return value == environment.root.path
    }

    private func markComplete() {
        defaults.set(environment.root.path, forKey: Self.doneKey)
    }

    // MARK: - The old index, read without the all-or-nothing failure

    private struct LegacyIndex {
        /// fileName → record, for enriching bytes found on disk.
        var byName: [String: AudioFile] = [:]
        var records: [AudioFile] = []
        var playlists: [Playlist] = []
        var masterID: UUID?
        var unreadable = 0
    }

    private func loadLegacyIndex() -> LegacyIndex {
        var index = LegacyIndex()

        if let data = defaults.data(forKey: LegacyKey.tracks) {
            let decoded = Self.lossyDecode(AudioFile.self, from: data)
            index.records = decoded.values
            index.unreadable += decoded.failures
            for record in decoded.values {
                index.byName[record.fileName] = record
            }
        }

        if let data = defaults.data(forKey: LegacyKey.playlists) {
            let decoded = Self.lossyDecode(Playlist.self, from: data)
            index.playlists = decoded.values
            index.unreadable += decoded.failures
        }

        if let data = defaults.data(forKey: LegacyKey.masterPlaylist),
           let id = try? JSONDecoder().decode(UUID.self, from: data) {
            index.masterID = id
        }

        return index
    }

    /// Decodes an array **one element at a time**, so one malformed record costs
    /// only itself.
    ///
    /// `decode([T].self)` throws on the first bad element and yields nothing.
    /// That is not a theoretical concern: it is the whole of C12. Going through
    /// `JSONSerialization` gives each element its own decode, and guarantees the
    /// unkeyed container advances even when an element throws — the naive
    /// `do { try container.decode(T.self) } catch {}` loop spins forever.
    static func lossyDecode<T: Decodable>(_ type: T.Type, from data: Data) -> (values: [T], failures: Int) {
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            if let single = try? JSONDecoder().decode(T.self, from: data) {
                return ([single], 0)
            }
            return ([], 1)
        }

        var values: [T] = []
        var failures = 0
        values.reserveCapacity(elements.count)

        for element in elements {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let value = try? JSONDecoder().decode(T.self, from: elementData)
            else {
                failures += 1
                continue
            }
            values.append(value)
        }

        return (values, failures)
    }

    // MARK: - Adoption

    /// Audio files on disk that the old index never mentioned.
    ///
    /// These are the songs that "disappeared": their bytes were copied, then
    /// unlinked as untracked before any index write landed. Adopting them by
    /// filename-derived title is strictly better than leaving the user to find
    /// them by hand.
    private func adoptUnindexedFiles(
        index byName: [String: AudioFile],
        onDisk: [URL]
    ) async -> Int {
        var adopted = 0

        for source in onDisk {
            let name = source.lastPathComponent
            let known = byName[name]

            // Probed before the record is built: an `await` is not permitted
            // inside the `??` autoclosure, and probing unconditionally would
            // cost an asset read per file even when the index already knew.
            let duration: Float
            if let known {
                duration = known.audioDuration
            } else {
                duration = await Self.probeDuration(of: source) ?? 0
            }

            let record = TrackRecord(
                id: UUID(),
                fileName: "",
                sourceName: name,
                displayTitle: known?.title ?? (name as NSString).deletingPathExtension,
                ext: source.pathExtension,
                byteSize: Self.byteSize(of: source),
                duration: duration,
                dateAdded: known?.dateAdded ?? Self.dateAdded(of: source),
                artworkName: known?.artworkImageName,
                originBookmark: nil,
                state: .committed,
                rejectReason: nil,
                importedVia: .legacyMigration
            )

            if let destination = install(source, preferredID: record.id) {
                var installed = record
                installed.fileName = destination.lastPathComponent
                try? store.commitImport(
                    jobID: UUID(),
                    record: installed,
                    addToPlaylist: nil,
                    position: nil
                )
                adopted += 1
            }
        }

        return adopted
    }

    /// Files the old index knew about. Moves them into the library directory,
    /// or records them as `.missing` if the bytes are genuinely gone.
    private func recoverIndexedFiles(_ records: [AudioFile]) async -> Int {
        var recovered = 0

        for record in records {
            if FileManager.default.fileExists(
                atPath: environment.tracks.appendingPathComponent(record.fileName).path
            ) {
                continue  // already in place
            }

            guard let source = locateLegacy(record.fileName) else {
                try? store.setTrackState(record.id, .missing)
                continue
            }

            var installed = TrackRecord(
                id: record.id,
                fileName: "",
                sourceName: record.fileName,
                displayTitle: record.title,
                ext: source.pathExtension,
                byteSize: Self.byteSize(of: source),
                duration: record.audioDuration,
                dateAdded: record.dateAdded,
                artworkName: record.artworkImageName,
                originBookmark: nil,
                state: .committed,
                rejectReason: nil,
                importedVia: .legacyMigration
            )

            if let destination = install(source, preferredID: record.id) {
                installed.fileName = destination.lastPathComponent
                try? store.commitImport(
                    jobID: UUID(),
                    record: installed,
                    addToPlaylist: nil,
                    position: nil
                )
                recovered += 1
            }
        }

        return recovered
    }

    /// Moves legacy artwork into the new artwork directory.
    private func adoptArtwork() {
        var candidates: [URL] = []
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        candidates.append(documents.appendingPathComponent("Artwork", isDirectory: true))
        candidates.append(documents.appendingPathComponent("AudioFiles/Artwork", isDirectory: true))
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) {
            candidates.append(group.appendingPathComponent("AudioFiles/Artwork", isDirectory: true))
        }

        for directory in candidates {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let destination = environment.artwork.appendingPathComponent(entry.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                do {
                    try FileManager.default.moveItem(at: entry, to: destination)
                } catch {
                    Self.logger.error(
                        "Could not adopt artwork \(entry.lastPathComponent, privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Playlists

    private func rebuildPlaylists(_ playlists: [Playlist], masterID: UUID?) -> Int {
        let tracks = (try? store.loadTracks()) ?? []
        let knownIDs = Set(tracks.map(\.id))

        var records: [PlaylistRecord] = []
        var master: UUID?

        for playlist in playlists {
            // Drop memberships that point at nothing, rather than persisting ids
            // the UI will silently fail to resolve.
            let members = playlist.audioFileIDs.filter { knownIDs.contains($0) }
            let isMaster = playlist.id == masterID
            records.append(
                PlaylistRecord(
                    id: playlist.id,
                    name: playlist.name,
                    isAlbum: playlist.isAlbum,
                    coverName: playlist.artworkImageName,
                    coverIsManual: playlist.coverIsManual,
                    artist: playlist.artist,
                    dateAdded: playlist.dateAdded,
                    isMaster: isMaster,
                    memberIDs: members
                )
            )
            if isMaster { master = playlist.id }
        }

        // One persist for the whole set. `persist` prunes any playlist not in
        // the snapshot, so writing them one at a time would delete every playlist
        // except the last — the same "empty projection means delete everything"
        // trap, in a new location.
        guard !records.isEmpty else { return 0 }

        try? store.persist(
            LibrarySnapshot(
                tracks: tracks.map(\.audioFile),
                playlists: records.map(\.playlist),
                masterPlaylistID: master
            )
        )
        return records.count
    }

    // MARK: - Helpers

    /// Moves `source` into `Tracks/` under a fresh name, never overwriting.
    private func install(_ source: URL, preferredID: UUID) -> URL? {
        let ext = source.pathExtension
        let name = ext.isEmpty ? preferredID.uuidString : "\(preferredID.uuidString).\(ext)"
        let destination = environment.tracks.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(
                at: environment.tracks,
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            Self.logger.error(
                "Could not install \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func locateLegacy(_ fileName: String) -> URL? {
        for directory in environment.legacyAudioLocations {
            let candidate = directory.appendingPathComponent(fileName)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func byteSize(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func dateAdded(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func probeDuration(of url: URL) async -> Float? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = Float(CMTimeGetSeconds(duration))
        return (seconds > 0 && seconds.isFinite) ? seconds : nil
    }
}
