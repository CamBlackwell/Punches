import Foundation

/// Captures point-in-time snapshots of the audio library's persisted state,
/// diffs each one against the previous snapshot, and writes a running log
/// that survives app relaunches.
///
/// The log lives in the app's own sandboxed Documents directory — deliberately
/// NOT the App Group container — so the diagnostics themselves stay reliable
/// even if the App Group container is part of what's misbehaving.
///
/// Every snapshot is read directly from disk (not from `manager.audioFiles`
/// etc.), so this catches bugs even if the in-memory state itself is already
/// wrong by the time you'd think to check it.
final class DiagnosticsService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Storage

    private var logDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var logFileURL: URL {
        logDirectory.appendingPathComponent("diagnostics.log")
    }

    private var lastSnapshotURL: URL {
        logDirectory.appendingPathComponent("last_snapshot.json")
    }

    // MARK: - Snapshot model

    struct Snapshot: Codable {
        let timestamp: Date
        let label: String

        // Read fresh from disk each time — independent of in-memory state.
        let jsonAudioFileIDs: [String]
        let jsonAudioFileNames: [String]
        let jsonPlaylistCount: Int
        let jsonMasterPlaylistID: String?
        let jsonMasterPlaylistAudioIDs: [String]

        // What's physically sitting in the audio directory right now.
        let diskAudioFileNames: [String]

        // What the app actually has in memory at the moment of capture.
        let memoryAudioFileCount: Int
        let memoryMasterPlaylistAudioIDCount: Int

        // Environment, to catch storage-location flakiness.
        let appGroupContainerReachable: Bool
        let recordedStorageMode: String?
        let fileDirectoryPath: String
    }

    // MARK: - Capture

    @discardableResult
    func captureSnapshot(label: String) -> Snapshot {
        let snapshot = buildSnapshot(label: label)
        persist(snapshot)
        return snapshot
    }

    private func buildSnapshot(label: String) -> Snapshot {
        let fileDir = AudioManager.fileDirectory

        // audioFiles.json, read fresh — bypasses manager.audioFiles entirely.
        var jsonAudioFileIDs: [String] = []
        var jsonAudioFileNames: [String] = []
        let audioFilesURL = fileDir.appendingPathComponent("audioFiles.json")
        if let data = try? Data(contentsOf: audioFilesURL),
           let decoded = try? JSONDecoder().decode([AudioFile].self, from: data) {
            jsonAudioFileIDs = decoded.map { $0.id.uuidString }
            jsonAudioFileNames = decoded.map { $0.fileName }
        }

        // playlists.json, read fresh.
        var jsonPlaylistCount = 0
        var jsonMasterAudioIDs: [String] = []
        let playlistsURL = fileDir.appendingPathComponent("playlists.json")
        var decodedPlaylists: [Playlist] = []
        if let data = try? Data(contentsOf: playlistsURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            decodedPlaylists = decoded
            jsonPlaylistCount = decoded.count
        }

        // masterPlaylistID.json, read fresh.
        var jsonMasterID: String? = nil
        let masterIDURL = fileDir.appendingPathComponent("masterPlaylistID.json")
        if let data = try? Data(contentsOf: masterIDURL),
           let decoded = try? JSONDecoder().decode(UUID.self, from: data) {
            jsonMasterID = decoded.uuidString
            if let masterPlaylist = decodedPlaylists.first(where: { $0.id == decoded }) {
                jsonMasterAudioIDs = masterPlaylist.audioFileIDs.map { $0.uuidString }
            }
        }

        // What's physically on disk right now.
        var diskNames: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: fileDir, includingPropertiesForKeys: nil) {
            diskNames = files.map { $0.lastPathComponent }.filter { $0 != "Artwork" }
        }

        let groupReachable = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier) != nil
        let recordedMode = UserDefaults.standard.string(forKey: AudioManager.storageModeKey)

        return Snapshot(
            timestamp: Date(),
            label: label,
            jsonAudioFileIDs: jsonAudioFileIDs,
            jsonAudioFileNames: jsonAudioFileNames,
            jsonPlaylistCount: jsonPlaylistCount,
            jsonMasterPlaylistID: jsonMasterID,
            jsonMasterPlaylistAudioIDs: jsonMasterAudioIDs,
            diskAudioFileNames: diskNames,
            memoryAudioFileCount: manager.audioFiles.count,
            memoryMasterPlaylistAudioIDCount: manager.playlists.first(where: { $0.id == manager.masterPlaylistID })?.audioFileIDs.count ?? -1,
            appGroupContainerReachable: groupReachable,
            recordedStorageMode: recordedMode,
            fileDirectoryPath: fileDir.path
        )
    }

    // MARK: - Persistence + diffing

    private func persist(_ snapshot: Snapshot) {
        let previous = loadLastSnapshot()

        var entry = "\n========== [\(iso(snapshot.timestamp))] \(snapshot.label) ==========\n"
        entry += describe(snapshot)
        if let previous {
            entry += "\n--- Changes since previous snapshot (\"\(previous.label)\" at \(iso(previous.timestamp))) ---\n"
            entry += diff(previous, snapshot)
        } else {
            entry += "\n(no previous snapshot to diff against — this is the first one)\n"
        }
        entry += "==========================================================\n"
        append(entry)

        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: lastSnapshotURL, options: .atomic)
        }
    }

    private func loadLastSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: lastSnapshotURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func describe(_ s: Snapshot) -> String {
        """
        Storage mode recorded: \(s.recordedStorageMode ?? "none") | App Group reachable: \(s.appGroupContainerReachable)
        fileDirectory: \(s.fileDirectoryPath)
        audioFiles.json: \(s.jsonAudioFileIDs.count) entries -> \(s.jsonAudioFileNames)
        playlists.json: \(s.jsonPlaylistCount) playlist(s) | master ID: \(s.jsonMasterPlaylistID ?? "nil") | master audioFileIDs: \(s.jsonMasterPlaylistAudioIDs.count)
        Files on disk in fileDirectory: \(s.diskAudioFileNames.count) -> \(s.diskAudioFileNames)
        In-memory manager.audioFiles: \(s.memoryAudioFileCount) | in-memory master audioFileIDs: \(s.memoryMasterPlaylistAudioIDCount)
        """
    }

    private func diff(_ old: Snapshot, _ new: Snapshot) -> String {
        var lines: [String] = []

        let oldIDs = Set(old.jsonAudioFileIDs)
        let newIDs = Set(new.jsonAudioFileIDs)
        let lostFromJSON = oldIDs.subtracting(newIDs)
        let gainedInJSON = newIDs.subtracting(oldIDs)

        if !lostFromJSON.isEmpty {
            let names = old.jsonAudioFileNames.enumerated()
                .filter { lostFromJSON.contains(old.jsonAudioFileIDs[$0.offset]) }
                .map { $0.element }
            lines.append("⚠️ LOST from audioFiles.json (\(lostFromJSON.count)): \(names)")
        }
        if !gainedInJSON.isEmpty {
            lines.append("+ Added to audioFiles.json: \(gainedInJSON.count) file(s)")
        }

        let oldMaster = Set(old.jsonMasterPlaylistAudioIDs)
        let newMaster = Set(new.jsonMasterPlaylistAudioIDs)
        let lostFromMaster = oldMaster.subtracting(newMaster)
        if !lostFromMaster.isEmpty {
            lines.append("⚠️ LOST from master playlist audioFileIDs (\(lostFromMaster.count)): \(Array(lostFromMaster))")
        }

        let oldDisk = Set(old.diskAudioFileNames)
        let newDisk = Set(new.diskAudioFileNames)
        let lostFromDisk = oldDisk.subtracting(newDisk)
        if !lostFromDisk.isEmpty {
            lines.append("⚠️ DELETED from disk (\(lostFromDisk.count)): \(Array(lostFromDisk))")
        }

        if old.recordedStorageMode != new.recordedStorageMode {
            lines.append("⚠️ STORAGE MODE CHANGED: \(old.recordedStorageMode ?? "nil") -> \(new.recordedStorageMode ?? "nil")")
        }
        if old.fileDirectoryPath != new.fileDirectoryPath {
            lines.append("⚠️ fileDirectory PATH CHANGED:\n   was: \(old.fileDirectoryPath)\n   now: \(new.fileDirectoryPath)")
        }
        if old.appGroupContainerReachable != new.appGroupContainerReachable {
            lines.append("⚠️ App Group reachability changed: \(old.appGroupContainerReachable) -> \(new.appGroupContainerReachable)")
        }

        if lines.isEmpty {
            lines.append("No changes detected — state is consistent since last snapshot.")
        }

        return lines.joined(separator: "\n")
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
        #if DEBUG
        print(text)
        #endif
    }

    // MARK: - Retrieval (for a debug view / share sheet)

    func readFullLog() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? "No diagnostics log yet."
    }

    func logFileURLForSharing() -> URL {
        logFileURL
    }

    func clearLog() {
        try? FileManager.default.removeItem(at: logFileURL)
        try? FileManager.default.removeItem(at: lastSnapshotURL)
    }
}
