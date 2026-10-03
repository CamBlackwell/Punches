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

    /// The name a newly saved cover is stored under.
    ///
    /// Static so there is exactly one definition. `LibraryTagSweep` saves art
    /// without an `AudioManager` to reach — it runs independently of the UI — and
    /// a second copy of this string is how "embedded covers and hand-picked
    /// covers are stored differently" would happen.
    static func artworkFileName() -> String {
        "artwork_\(UUID().uuidString).jpg"
    }

    /// Saves cover art that arrived as encoded bytes.
    ///
    /// The case is embedded art — an `APIC` frame lifted straight out of a file —
    /// which arrives already compressed and already in whatever format the tagger
    /// chose. Decoding and re-encoding through `saveArtwork(from:)` is the point:
    /// embedded art ends up identical in kind to art a user picked by hand, so
    /// there is one representation to cache, display and eventually resize.
    ///
    /// Returns `nil` for bytes that are not an image, or that fail to write. A
    /// missing cover is a cosmetic gap and must never fail an import.
    @discardableResult
    func saveArtwork(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let image = UIImage(data: data) else {
            print("Embedded artwork is not decodable")
            return nil
        }
        return saveArtwork(from: image)
    }

    func saveArtwork(from image: UIImage) -> String? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = Self.artworkFileName()
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

        // Mutated in place rather than by rebuilding an `AudioFile`. Rebuilding
        // means restating every field, and any field added later is silently
        // dropped — which is exactly how the tag columns would have been lost
        // every time a user picked a cover.
        manager.audioFiles[index].artworkImageName = newFilename

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

        // In place, for the reason given in `setArtwork(_:for:)`.
        manager.audioFiles[index].artworkImageName = nil

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
