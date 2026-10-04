import Foundation
import SwiftUI
import os

final class PlaylistService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    var sortedAudioFiles: [AudioFile] {
        guard let masterID = manager.masterPlaylistID,
              let masterPlaylist = manager.playlists.first(where: { $0.id == masterID }) else {
            return manager.audioFiles.sorted { $0.dateAdded > $1.dateAdded }
        }

        return masterPlaylist.audioFileIDs
            .compactMap { id in manager.audioFiles.first { $0.id == id } }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    var sortedPlaylists: [Playlist] {
        sortedCollections.filter { !$0.isAlbum }
    }

    var sortedAlbums: [Playlist] {
        sortedCollections.filter { $0.isAlbum }
    }

    /// Every user collection except the master playlist, newest first. Both
    /// pages filter this so `__MASTER_SONGS__` can never be rendered, and so
    /// albums never leak into the Playlists tab.
    private var sortedCollections: [Playlist] {
        manager.playlists
            .filter { $0.id != manager.masterPlaylistID }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// `audioFiles` keyed by id, so resolving a collection's members costs one
    /// pass over the library instead of a full scan per member.
    private var audioFilesByID: [UUID: AudioFile] {
        Dictionary(
            manager.audioFiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func songsByPlaylistID(for playlists: [Playlist]) -> [UUID: [AudioFile]] {
        let index = audioFilesByID
        var result: [UUID: [AudioFile]] = [:]
        result.reserveCapacity(playlists.count)
        for playlist in playlists {
            result[playlist.id] = playlist.audioFileIDs.compactMap { index[$0] }
        }
        return result
    }

    /// The artwork to show for an album. A cover the user picked by hand always
    /// wins; otherwise it is the artwork of the first member song that has some.
    /// `nil` means the caller should draw the empty placeholder.
    func coverName(for album: Playlist, songs: [AudioFile]) -> String? {
        if album.coverIsManual, let manual = album.artworkImageName {
            return manual
        }
        return songs.first { $0.artworkImageName != nil }?.artworkImageName
            ?? album.artworkImageName
    }

    // MARK: - Persistence

    /// Persists playlists and their membership in one transaction.
    ///
    /// Previously this and `saveAudioFiles()` were two independent
    /// `UserDefaults` writes from two call sites, so a track row and the
    /// membership that makes it visible could disagree. `sortedAudioFiles` reads
    /// the master playlist, so a lost membership write is an invisible file —
    /// indistinguishable from a lost file.
    func savePlaylists() {
        guard let store = manager.libraryStore else { return }

        let snapshot = LibrarySnapshot(
            tracks: manager.audioFiles,
            playlists: manager.playlists,
            masterPlaylistID: manager.masterPlaylistID
        )

        do {
            try store.persist(snapshot)
        } catch {
            LibraryEnvironment.log.fault("Failed to persist playlists: \(error.localizedDescription)")
        }
    }

    func loadPlaylists() {
        if let store = manager.libraryStore {
            manager.playlists = ((try? store.loadPlaylists()) ?? []).map(\.playlist)
            manager.masterPlaylistID = try? store.loadMasterPlaylistID()
            if manager.masterPlaylistID == nil,
               let legacy = try? loadLegacyMasterID() {
                manager.masterPlaylistID = legacy
            }
            return
        }

        guard let data = UserDefaults.standard.data(forKey: manager.playlistsKey) else { return }
        let decoded = LibraryMigration.lossyDecode(Playlist.self, from: data)
        manager.playlists = decoded.values
    }

    private func loadLegacyMasterID() throws -> UUID? {
        guard let data = UserDefaults.standard.data(forKey: manager.masterPlaylistKey) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: data)
    }

    /// Ensures a master playlist exists and contains every track.
    ///
    /// ## Why this no longer clears anything
    ///
    /// The old version called `clearZombiePlaylists()`, which emptied
    /// `manager.playlists` and removed the master id from `UserDefaults`. That
    /// ran whenever the stored master id failed to resolve — including on a
    /// decode failure, which `savePlaylists()` could trigger for reasons
    /// unrelated to the master at all. The user's playlists were then rebuilt as
    /// empty shells and the next `savePlaylists()` overwrote the old blob,
    /// permanently.
    ///
    /// A missing master is a one-row problem, so it is now repaired as one: a
    /// fresh master id, the existing playlists untouched, and full membership
    /// re-derived from the track table.
    ///
    /// ## Why a new master is always written back
    ///
    /// The membership repair below only saved when it changed something, which
    /// meant the master row reached the database by accident or not at all. On an
    /// empty library a freshly created master has no members and there are no
    /// tracks, so `present == expected`, the guard returned early, and the row was
    /// never written. `manager.masterPlaylistID` then named a playlist that
    /// existed only in memory, and the *first import on a brand-new install*
    /// failed to add a membership row for it.
    ///
    /// Membership repair is still conditional — it has nothing to do when the two
    /// sets already agree — so the save is driven off whether a master was
    /// actually created, and the repair piggybacks on it.
    func loadOrCreateMasterPlaylist() {
        var masterID = manager.masterPlaylistID
        var createdMaster = false

        if masterID == nil || !manager.playlists.contains(where: { $0.id == masterID }) {
            let fresh = Playlist(name: "__MASTER_SONGS__")
            masterID = fresh.id
            manager.playlists.append(fresh)
            createdMaster = true
        }
        manager.masterPlaylistID = masterID

        // Self-heal membership: a track with no master row is invisible to
        // `sortedAudioFiles`, which is the single largest cause of "the file is
        // on disk but not in the app".
        guard let masterID,
              let index = manager.playlists.firstIndex(where: { $0.id == masterID }) else { return }

        let expected = Set(manager.audioFiles.map(\.id))
        let present = Set(manager.playlists[index].audioFileIDs)
        guard present != expected else {
            // Nothing to repair, but a master created a moment ago still has to
            // exist on disk before anything can reference it.
            if createdMaster { savePlaylists() }
            return
        }

        var repaired = manager.playlists[index].audioFileIDs.filter(expected.contains)
        let additions = manager.audioFiles.filter { !present.contains($0.id) }
        repaired.append(contentsOf: additions.map(\.id))
        manager.playlists[index].audioFileIDs = repaired

        savePlaylists()
    }

    func reorderSongs(from source: IndexSet, to destination: Int) {
        manager.displayedSongs.move(fromOffsets: source, toOffset: destination)

        guard let masterID = manager.masterPlaylistID,
              let index = manager.playlists.firstIndex(where: { $0.id == masterID }) else { return }

        let reorderedIDs = manager.displayedSongs.map { $0.id }
        manager.playlists[index].audioFileIDs = reorderedIDs
        savePlaylists()

        if manager.playingFromSongsTab {
            manager.playbackQueue = manager.displayedSongs
        }
    }

    func reorderPlaylistSongs(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        var updatedPlaylist = manager.playlists[index]
        updatedPlaylist.audioFileIDs.move(fromOffsets: source, toOffset: destination)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.manager.playlists[index] = updatedPlaylist
            self.savePlaylists()
        }
    }

    func updatePlaylistOrder(_ playlist: Playlist, with ids: [UUID]) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        manager.playlists[index].audioFileIDs = ids
        savePlaylists()

        if !manager.playingFromSongsTab {
            let reorderedSongs = ids.compactMap { id in manager.audioFiles.first { $0.id == id } }
            manager.playbackQueue = reorderedSongs
        }
    }

    func createPlaylist(name: String, isAlbum: Bool = false, artist: String? = nil) {
        let newPlaylist = Playlist(name: name, isAlbum: isAlbum, artist: artist)
        manager.playlists.append(newPlaylist)
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        guard playlist.id != manager.masterPlaylistID else { return }
        manager.playlists.removeAll { $0.id == playlist.id }
        manager.artworkService.deleteArtworkIfUnused(playlist.artworkImageName)
        savePlaylists()
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        manager.playlists[index].name = newName
        savePlaylists()
    }

    func setArtist(_ artist: String?, for playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let trimmed = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        manager.playlists[index].artist = (trimmed?.isEmpty ?? true) ? nil : trimmed
        savePlaylists()
    }

    /// Adds songs to a collection and persists **once**.
    ///
    /// The single-song method used to be the only way in, so every batch
    /// affordance — the add-songs sheet, the multi-select menus — was a loop
    /// around it, and it saved on every iteration. A save is not a small write:
    /// `savePlaylists()` reaches `LibraryStore.persist`, which mirrors the *whole*
    /// library — every track is upserted and anything absent is pruned. Adding
    /// 100 songs to an album therefore rewrote the entire library 100 times, on
    /// the main actor, while the sheet was still up. See
    /// [14 · C19](14-known-issues.md).
    ///
    /// Duplicates are skipped rather than rejected, matching the single-song
    /// behaviour: membership is an ordered set the caller appends to, and the
    /// add-songs sheet's candidate list is already filtered to exclude members.
    /// Order is preserved — songs land in the order they were handed over, which
    /// is what lets a caller pass a selection in the order the user saw it.
    func addAudioFiles(_ audioFiles: [AudioFile], to playlist: Playlist) {
        guard !audioFiles.isEmpty,
              let index = manager.playlists.firstIndex(where: { $0.id == playlist.id })
        else { return }

        var members = manager.playlists[index].audioFileIDs
        // What is already there, so appending N songs to an album of M is
        // O(N + M) rather than O(N × M).
        var present = Set(members)
        var added = false

        for audioFile in audioFiles where present.insert(audioFile.id).inserted {
            members.append(audioFile.id)
            added = true
        }

        guard added else { return }
        manager.playlists[index].audioFileIDs = members
        savePlaylists()
    }

    func addAudioFile(_ audioFile: AudioFile, to playlist: Playlist) {
        addAudioFiles([audioFile], to: playlist)
    }

    /// Removes songs from a collection and persists **once**, for the same reason
    /// as `addAudioFiles`.
    ///
    /// `removeAll { … }` rather than `removeAll(where:)` because the collection is
    /// an array of ids and membership is a set: the same song must go even if it
    /// somehow appears twice.
    func removeAudioFiles(_ audioFiles: [AudioFile], from playlist: Playlist) {
        guard !audioFiles.isEmpty,
              let index = manager.playlists.firstIndex(where: { $0.id == playlist.id })
        else { return }

        var members = manager.playlists[index].audioFileIDs
        let doomed = Set(audioFiles.map(\.id))
        let before = members.count
        members.removeAll { doomed.contains($0) }
        guard members.count != before else { return }

        manager.playlists[index].audioFileIDs = members
        savePlaylists()
    }

    func removeAudioFile(_ audioFile: AudioFile, from playlist: Playlist) {
        removeAudioFiles([audioFile], from: playlist)
    }

    func getAudioFiles(for playlist: Playlist) -> [AudioFile] {
        let index = audioFilesByID
        return playlist.audioFileIDs.compactMap { index[$0] }
    }
}
