import Foundation
import AVFoundation

final class AudioLibraryService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func loadAudioFiles() {
        guard let data = UserDefaults.standard.data(forKey: manager.audioFilesKey) else { return }

        do {
            let loadedFiles = try JSONDecoder().decode([AudioFile].self, from: data)
            manager.audioFiles = loadedFiles.filter { file in
                let url = file.fileURL
                let exists = FileManager.default.fileExists(atPath: url.path())
                if !exists {
                    print("File missing: \(file.fileName) at \(url.path())")
                }
                return exists
            }
            print("Loaded \(manager.audioFiles.count) audio files")
        } catch {
            print("failed to load Audio Files \(error.localizedDescription)")
        }
    }

    func saveAudioFiles() {
        do {
            let data = try JSONEncoder().encode(manager.audioFiles)
            UserDefaults.standard.set(data, forKey: manager.audioFilesKey)
        } catch {
            print("failed to save audio files \(error.localizedDescription)")
        }
    }

    func deleteAudioFile(_ audioFile: AudioFile) {
        if manager.currentlyPlayingID == audioFile.id {
            manager.stop()
        }

        let url = audioFile.fileURL
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("failed to delete file \(error.localizedDescription)")
        }

        manager.audioFiles.removeAll { $0.id == audioFile.id }
        manager.artworkService.deleteArtworkIfUnused(audioFile.artworkImageName)
        saveAudioFiles()
        manager.displayedSongs = manager.sortedAudioFiles

        for i in 0..<manager.playlists.count {
            manager.playlists[i].audioFileIDs.removeAll { $0 == audioFile.id }
        }
        manager.playlistService.savePlaylists()

        if manager.playbackQueue.contains(where: { $0.id == audioFile.id }) {
            manager.playbackQueue.removeAll { $0.id == audioFile.id }
        }
    }

    func generateUniqueFileName(for originalName: String) -> String {
        let baseURL = AudioManager.fileDirectory.appendingPathComponent(originalName)

        if !FileManager.default.fileExists(atPath: baseURL.path()) {
            return originalName
        }

        let nameWithoutExtension = (originalName as NSString).deletingPathExtension
        let fileExtension = (originalName as NSString).pathExtension

        var counter = 2
        while true {
            let newName = fileExtension.isEmpty
            ? "\(nameWithoutExtension) \(counter)"
            : "\(nameWithoutExtension) \(counter).\(fileExtension)"

            let newURL = AudioManager.fileDirectory.appendingPathComponent(newName)

            if !FileManager.default.fileExists(atPath: newURL.path()) {
                return newName
            }

            counter += 1
        }
    }

    func cleanupOrphanedFiles() {
        let trackedFileNames = Set(manager.audioFiles.map { $0.fileName })

        guard let files = try? FileManager.default.contentsOfDirectory(at: AudioManager.fileDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in files {
            let fileName = fileURL.lastPathComponent
            if fileName != "Artwork" && !trackedFileNames.contains(fileName) {
                print("Deleting orphaned file: \(fileName)")
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func renameAudioFile(_ audioFile: AudioFile, to newTitle: String) {
        guard let index = manager.audioFiles.firstIndex(where: { $0.id == audioFile.id }) else { return }

        let updatedFile = AudioFile(
            id: audioFile.id,
            fileName: audioFile.fileName,
            dateAdded: audioFile.dateAdded,
            audioDuration: audioFile.audioDuration,
            artworkImageName: audioFile.artworkImageName,
            title: newTitle
        )

        manager.audioFiles[index] = updatedFile
        saveAudioFiles()
        manager.displayedSongs = manager.sortedAudioFiles
    }

    func urlForSharing(_ audioFile: AudioFile) -> URL? {
        audioFile.fileURL
    }

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
