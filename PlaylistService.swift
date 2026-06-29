import Foundation
import SwiftUI

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
        manager.playlists
            .filter { $0.id != manager.masterPlaylistID }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    func savePlaylists() {
        do {
            let data = try JSONEncoder().encode(manager.playlists)
            UserDefaults.standard.set(data, forKey: manager.playlistsKey)
        } catch {
            print("failed to save playlists \(error.localizedDescription)")
        }
    }

    func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: manager.playlistsKey) else { return }
        do {
            manager.playlists = try JSONDecoder().decode([Playlist].self, from: data)
        } catch {
            print("failed to load playlists \(error.localizedDescription)")
        }
    }

    private func clearZombiePlaylists() {
        manager.playlists = []
        savePlaylists()
        UserDefaults.standard.removeObject(forKey: manager.masterPlaylistKey)
    }

    func loadOrCreateMasterPlaylist() {
        if let data = UserDefaults.standard.data(forKey: manager.masterPlaylistKey),
           let id = try? JSONDecoder().decode(UUID.self, from: data),
           manager.playlists.contains(where: { $0.id == id }) {
            manager.masterPlaylistID = id
        } else {
            clearZombiePlaylists()
            let masterPlaylist = Playlist(name: "__MASTER_SONGS__")
            manager.masterPlaylistID = masterPlaylist.id
            manager.playlists.append(masterPlaylist)

            for audioFile in manager.audioFiles {
                if let index = manager.playlists.firstIndex(where: { $0.id == manager.masterPlaylistID }) {
                    manager.playlists[index].audioFileIDs.append(audioFile.id)
                }
            }

            savePlaylists()
            if let data = try? JSONEncoder().encode(manager.masterPlaylistID) {
                UserDefaults.standard.set(data, forKey: manager.masterPlaylistKey)
            }
        }
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

    func createPlaylist(name: String) {
        let newPlaylist = Playlist(name: name)
        manager.playlists.append(newPlaylist)
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        manager.playlists.removeAll { $0.id == playlist.id }
        manager.artworkService.deleteArtworkIfUnused(playlist.artworkImageName)
        savePlaylists()
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        manager.playlists[index].name = newName
        savePlaylists()
    }

    func addAudioFile(_ audioFile: AudioFile, to playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if !manager.playlists[index].audioFileIDs.contains(audioFile.id) {
            manager.playlists[index].audioFileIDs.append(audioFile.id)
            savePlaylists()
        }
    }

    func removeAudioFile(_ audioFile: AudioFile, from playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        manager.playlists[index].audioFileIDs.removeAll { $0 == audioFile.id }
        savePlaylists()
    }

    func getAudioFiles(for playlist: Playlist) -> [AudioFile] {
        playlist.audioFileIDs
            .compactMap { id in manager.audioFiles.first { $0.id == id } }
    }
}
