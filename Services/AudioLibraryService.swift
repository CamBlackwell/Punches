import Foundation
import AVFoundation
import os

/// Reads and writes the library index.
///
/// The persisted form is now the SQLite store. The `UserDefaults` JSON remains
/// only as a read fallback for the case where the database cannot be opened at
/// all, so a store failure degrades to a read-only view of the old index rather
/// than to an empty library.
final class AudioLibraryService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    private var store: LibraryStore? { manager.libraryStore }

    // MARK: - Loading

    func loadAudioFiles() {
        if let store {
            let records = (try? store.loadTracks()) ?? []
            manager.audioFiles = records.map(\.audioFile)
            return
        }

        // Store unavailable: fall back to the old index so the user still sees
        // their library. Never write back to UserDefaults in this state — two
        // writers to the same key is how the old all-or-nothing write lost data.
        guard let data = UserDefaults.standard.data(forKey: manager.audioFilesKey) else { return }
        let decoded = LibraryMigration.lossyDecode(AudioFile.self, from: data)
        manager.audioFiles = decoded.values.filter { file in
            let exists = FileManager.default.fileExists(atPath: file.fileURL.path)
            if !exists {
                LibraryEnvironment.log.warning("Missing file for indexed track \(file.fileName)")
            }
            return exists
        }
    }

    // MARK: - Saving

    /// Persists the whole snapshot in one transaction.
    ///
    /// Replaces `JSONEncoder().encode(manager.audioFiles)`, where a single
    /// non-`Codable` value threw and left `UserDefaults` holding the previous
    /// bytes — the entire library silently failing to update.
    func saveAudioFiles() {
        guard let store else { return }

        let snapshot = LibrarySnapshot(
            tracks: manager.audioFiles,
            playlists: manager.playlists,
            masterPlaylistID: manager.masterPlaylistID
        )

        do {
            try store.persist(snapshot)
        } catch {
            LibraryEnvironment.log.fault("Failed to persist library: \(error.localizedDescription)")
        }
    }

    // MARK: - Mutation

    /// Removes a track in response to an explicit user action.
    ///
    /// This is the only place in the app that unlinks bytes, and the bytes go to
    /// `Trash/` rather than disappearing. Row first, then file: if the move
    /// fails the reconciler picks the file up on the next pass, and if the row
    /// write fails the file is still recoverable from Trash.
    func deleteAudioFile(_ audioFile: AudioFile) {
        // The successor is captured *before* the removal, because afterwards the
        // deleted track is gone from the queue and there is no index to read it
        // from. `isLooping` is deliberately not consulted: loop decides what
        // happens when a track *ends*, and this one is being removed while the
        // user is looking at it. Wrapping to the top of the queue here would
        // jump the playhead somewhere unrelated.
        let successor: AudioFile? = {
            guard manager.currentlyPlayingID == audioFile.id else { return nil }
            let queue = manager.playbackQueue
            guard let index = queue.firstIndex(where: { $0.id == audioFile.id }),
                  index + 1 < queue.count else { return nil }
            return queue[index + 1]
        }()

        // The engine is still holding this file's audio, so stopping is not
        // optional even when there is a successor to hand over to.
        if manager.currentlyPlayingID == audioFile.id {
            manager.stop()
        }

        manager.audioFiles.removeAll { $0.id == audioFile.id }
        for index in manager.playlists.indices {
            manager.playlists[index].audioFileIDs.removeAll { $0 == audioFile.id }
        }
        manager.playbackQueue.removeAll { $0.id == audioFile.id }

        saveAudioFiles()

        // Explicit `_ =`: the bytes are already gone from the library's point of
        // view, so a failure here is not worth interrupting the user for — the
        // reconciler picks up anything left on the next pass.
        if let reconciler = manager.libraryReconciler {
            _ = try? reconciler.moveToTrash(audioFile.fileURL, reason: "deleted")
        } else {
            _ = try? FileManager.default.removeItem(at: audioFile.fileURL)
        }

        manager.artworkService.deleteArtworkIfUnused(audioFile.artworkImageName)
        manager.displayedSongs = manager.sortedAudioFiles

        // Hand the player to the track that took the deleted one's place, at
        // whichever play/pause state it was in. Without this the deletion left
        // no current track at all, and the next tap of Play started again from
        // the top of the queue — so deleting the fifth song of twelve rewound
        // the user to song one.
        //
        // Re-checked against the queue *after* removal: the successor can itself
        // have been removed from the queue by a duplicate id or by a
        // reconciler pass between the two statements.
        if let successor,
           manager.playbackQueue.contains(where: { $0.id == successor.id }) {
            manager.playbackService.handover(to: successor)
        }
    }

    /// Renames a track. The file itself is not touched — `fileName` is an opaque
    /// on-disk name and the title is display metadata only.
    func renameAudioFile(_ audioFile: AudioFile, to newTitle: String) {
        guard let index = manager.audioFiles.firstIndex(where: { $0.id == audioFile.id }) else { return }

        var updated = audioFile
        updated.title = newTitle
        manager.audioFiles[index] = updated

        saveAudioFiles()
        manager.displayedSongs = manager.sortedAudioFiles
    }

    func urlForSharing(_ audioFile: AudioFile) -> URL? {
        audioFile.fileURL
    }

    // MARK: - Settings

    func loadVisualisationMode() {
        if let saved = UserDefaults.standard.string(forKey: manager.visualisationModeKey),
           let mode = VisualisationMode(rawValue: saved) {
            manager.visualisationMode = mode
        }
    }

    func saveVisualisationMode() {
        UserDefaults.standard.set(manager.visualisationMode.rawValue, forKey: manager.visualisationModeKey)
    }
}
