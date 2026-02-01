import Foundation
import UIKit

final class ArtworkService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func saveArtwork(from image: UIImage) -> String? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = "artwork_\(UUID().uuidString).jpg"
        let fileURL = manager.artworkDirectory.appendingPathComponent(filename)

        do {
            if !FileManager.default.fileExists(atPath: manager.artworkDirectory.path) {
                try FileManager.default.createDirectory(at: manager.artworkDirectory, withIntermediateDirectories: true)
            }
            try imageData.write(to: fileURL)
            return filename
        } catch {
            print("Failed to save artwork: \(error)")
            return nil
        }
    }

    func loadArtworkImage(_ imageName: String) -> UIImage? {
        let imageURL = manager.artworkDirectory.appendingPathComponent(imageName)
        if let data = try? Data(contentsOf: imageURL) {
            return UIImage(data: data)
        }
        return nil
    }

    func setArtwork(_ image: UIImage, for audioFile: AudioFile) {
        guard let index = manager.audioFiles.firstIndex(where: { $0.id == audioFile.id }) else { return }

        let oldArtwork = manager.audioFiles[index].artworkImageName
        guard let newFilename = saveArtwork(from: image) else { return }

        let updatedFile = AudioFile(
            id: audioFile.id,
            fileName: audioFile.fileName,
            dateAdded: audioFile.dateAdded,
            audioDuration: audioFile.audioDuration,
            artworkImageName: newFilename,
            title: audioFile.title
        )

        manager.audioFiles[index] = updatedFile
        manager.displayedSongs = manager.sortedAudioFiles
        manager.libraryService.saveAudioFiles()
        deleteArtworkIfUnused(oldArtwork)
    }

    func setArtwork(_ image: UIImage, for playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        let oldArtwork = manager.playlists[index].artworkImageName

        guard let newFilename = saveArtwork(from: image) else { return }

        manager.playlists[index].artworkImageName = newFilename
        manager.playlistService.savePlaylists()

        deleteArtworkIfUnused(oldArtwork)
    }

    func removeArtwork(from audioFile: AudioFile) {
        guard let index = manager.audioFiles.firstIndex(where: { $0.id == audioFile.id }) else { return }

        let oldArtwork = manager.audioFiles[index].artworkImageName

        let updatedFile = AudioFile(
            id: audioFile.id,
            fileName: audioFile.fileName,
            dateAdded: audioFile.dateAdded,
            audioDuration: audioFile.audioDuration,
            artworkImageName: nil,
            title: audioFile.title
        )

        manager.audioFiles[index] = updatedFile
        manager.libraryService.saveAudioFiles()
        deleteArtworkIfUnused(oldArtwork)
    }

    func removeArtwork(from playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        let oldArtwork = manager.playlists[index].artworkImageName

        manager.playlists[index].artworkImageName = nil
        manager.playlistService.savePlaylists()

        deleteArtworkIfUnused(oldArtwork)
    }

    func deleteArtworkIfUnused(_ imageName: String?) {
        guard let imageName = imageName else { return }

        let audioFileUsage = manager.audioFiles.filter { $0.artworkImageName == imageName }.count
        let playlistUsage = manager.playlists.filter { $0.artworkImageName == imageName }.count

        if audioFileUsage == 0 && playlistUsage == 0 {
            let fileURL = manager.artworkDirectory.appendingPathComponent(imageName)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
