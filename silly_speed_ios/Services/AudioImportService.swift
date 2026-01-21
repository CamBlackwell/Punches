import Foundation
import AVFoundation

final class AudioImportService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func importAudioFile(from url: URL) {
        manager.isImporting = true
        manager.importError = nil

        Task {
            do {
                print("Importing from: \(url)")

                guard url.startAccessingSecurityScopedResource() else {
                    throw NSError(domain: "AudioImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "No permission to access this file"])
                }

                defer {
                    url.stopAccessingSecurityScopedResource()
                    print("Released security scope")
                }

                let originalFileName = url.lastPathComponent
                let uniqueFileName = manager.libraryService.generateUniqueFileName(for: originalFileName)
                let destinationURL = AudioManager.fileDirectory.appendingPathComponent(uniqueFileName)

                print("Copying to: \(destinationURL)")

                let fileCoordinator = NSFileCoordinator()

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var coordinationError: NSError?

                    fileCoordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
                        do {
                            try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
                            continuation.resume(returning: ())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    if let error = coordinationError {
                        continuation.resume(throwing: error)
                    }
                }

                print("File copied successfully")

                let asset = AVURLAsset(url: destinationURL, options: nil)
                let duration = try await asset.load(.duration)
                let durationInSeconds = Float(CMTimeGetSeconds(duration))

                guard durationInSeconds > 0 && !durationInSeconds.isNaN && !durationInSeconds.isInfinite else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    throw NSError(domain: "AudioImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or corrupted audio file"])
                }

                let audioFile = AudioFile(fileName: uniqueFileName, audioDuration: durationInSeconds)

                await MainActor.run {
                    self.manager.audioFiles.append(audioFile)
                    self.manager.libraryService.saveAudioFiles()

                    if let masterID = self.manager.masterPlaylistID,
                       let index = self.manager.playlists.firstIndex(where: { $0.id == masterID }) {
                        self.manager.playlists[index].audioFileIDs.append(audioFile.id)
                        self.manager.displayedSongs = self.manager.sortedAudioFiles
                        self.manager.playlistService.savePlaylists()
                    }

                    if self.manager.playbackQueue.count == self.manager.audioFiles.count - 1 {
                        self.manager.playbackQueue = self.manager.sortedAudioFiles
                    }

                    print("Import complete: \(uniqueFileName)")
                    self.manager.isImporting = false
                }

            } catch {
                await MainActor.run {
                    self.manager.isImporting = false

                    print("Import error: \(error)")

                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain {
                        switch nsError.code {
                        case NSFileReadNoPermissionError:
                            self.manager.importError = "No permission to read this file"
                        case NSFileReadNoSuchFileError:
                            self.manager.importError = "File not found or still downloading"
                        case NSFileReadUnknownError:
                            self.manager.importError = "Cannot read this file type"
                        default:
                            self.manager.importError = "Failed to import: \(error.localizedDescription)"
                        }
                    } else {
                        self.manager.importError = error.localizedDescription
                    }
                }
            }
        }
    }

    func processPendingImports(shouldAutoPlay: Bool = false) async {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier),
              let groupDefaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier),
              let pendingFiles = groupDefaults.stringArray(forKey: SharedConstants.pendingFilesKey),
              !pendingFiles.isEmpty else {
            return
        }

        let pendingDirectory = groupURL.appendingPathComponent("PendingImports", isDirectory: true)
        var importedFiles: [AudioFile] = []

        for fileName in pendingFiles {
            let sourceURL = pendingDirectory.appendingPathComponent(fileName)

            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let uniqueFileName = manager.libraryService.generateUniqueFileName(for: fileName)
            let destinationURL = AudioManager.fileDirectory.appendingPathComponent(uniqueFileName)

            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

                let asset = AVURLAsset(url: destinationURL)
                let duration = try await asset.load(.duration)

                let durationInSeconds = Float(CMTimeGetSeconds(duration))

                guard durationInSeconds > 0 && !durationInSeconds.isNaN && !durationInSeconds.isInfinite else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    continue
                }
                let audioFile = AudioFile(fileName: uniqueFileName, audioDuration: durationInSeconds)
                manager.audioFiles.append(audioFile)
                importedFiles.append(audioFile)

                if let masterID = manager.masterPlaylistID,
                   let index = manager.playlists.firstIndex(where: { $0.id == masterID }) {
                    manager.playlists[index].audioFileIDs.append(audioFile.id)
                }

                print("Imported from share: \(uniqueFileName)")
            } catch {
                print("Error importing \(fileName): \(error)")
            }
        }

        if !importedFiles.isEmpty {
            manager.libraryService.saveAudioFiles()
            manager.playlistService.savePlaylists()
            manager.displayedSongs = manager.sortedAudioFiles
            manager.playbackQueue = manager.sortedAudioFiles

            if shouldAutoPlay, let firstFile = importedFiles.first {
                manager.play(audioFile: firstFile, context: manager.sortedAudioFiles, fromSongsTab: true)
            }
        }

        groupDefaults.removeObject(forKey: SharedConstants.pendingFilesKey)
        groupDefaults.synchronize()

        try? FileManager.default.removeItem(at: pendingDirectory)
    }
}
