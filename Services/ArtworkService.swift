import Foundation
import UIKit

final class ArtworkService {
    unowned let manager: AudioManager

    /// Decoded artwork, keyed by file name. `loadArtworkImage` is called from
    /// `body` by every row and grid cell, so without this each body evaluation
    /// re-reads and re-decodes every visible JPEG from disk.
    private let imageCache = NSCache<NSString, UIImage>()

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
        if let cached = imageCache.object(forKey: imageName as NSString) {
            return cached
        }

        let imageURL = manager.artworkDirectory.appendingPathComponent(imageName)
        guard let data = try? Data(contentsOf: imageURL),
              let image = UIImage(data: data) else {
            return nil
        }

        imageCache.setObject(image, forKey: imageName as NSString)
        return image
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
        manager.playlists[index].coverIsManual = true
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

    /// Clears a hand-picked cover. For an album this reverts the artwork to the
    /// derived one — the first member song that has any.
    func removeArtwork(from playlist: Playlist) {
        guard let index = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        let oldArtwork = manager.playlists[index].artworkImageName

        manager.playlists[index].artworkImageName = nil
        manager.playlists[index].coverIsManual = false
        manager.playlistService.savePlaylists()

        deleteArtworkIfUnused(oldArtwork)
    }

    func deleteArtworkIfUnused(_ imageName: String?) {
        guard let imageName = imageName else { return }

        let audioFileUsage = manager.audioFiles.filter { $0.artworkImageName == imageName }.count
        let playlistUsage = manager.playlists.filter { $0.artworkImageName == imageName }.count

        if audioFileUsage == 0 && playlistUsage == 0 {
            imageCache.removeObject(forKey: imageName as NSString)
            let fileURL = manager.artworkDirectory.appendingPathComponent(imageName)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
