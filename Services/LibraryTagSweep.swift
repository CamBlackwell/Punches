import Foundation
import UIKit
import os

/// Reads the tags of tracks that were imported before tags existed, and writes
/// them back.
///
/// ## Why a sweep rather than a migration step
///
/// The tags live in the audio file, not in the database, so filling in the new
/// columns means opening files. That is slow and it can fail, neither of which
/// belongs inside a schema migration: a migration that opened every file in the
/// library would be a launch that hangs proportional to library size, and one
/// failure would roll back the version stamp and leave the database claiming a
/// version it had not reached. So the schema changes shape, and this reads the
/// values.
///
/// ## Why it runs at launch
///
/// Existing users have to see their metadata without doing anything, so this is
/// not left to a button. It is nonetheless bounded on both axes:
///
/// - **Selection.** Only rows with `tags_read = 0` are touched, so the work
///   happens once per file across the lifetime of the install rather than every
///   launch. A file with no tags at all is stamped too, so it is not re-opened
///   forever.
/// - **Cooperation.** Each file is read and written one at a time with a yield
///   between them, so the sweep interleaves with whatever the user is doing
///   instead of monopolising a launch that looks hung.
///
/// The reads are `await`ed, so the file I/O happens off the main actor even
/// though this type is main-actor isolated like every other `LibraryStore`
/// caller; the writes are single-row statements, which is what the store does
/// everywhere else. Each row is committed as it is read, so being killed
/// part-way through costs only the files not yet reached — which is what makes
/// the ordering oldest-first the useful one.
struct LibraryTagSweep {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "tags"
    )

    /// Files read per pass. Bounds how long the sweep can hold up the rows behind
    /// it before yielding.
    static let batchSize = 8

    private let environment: LibraryEnvironment
    private let store: LibraryStore
    private let artworkDirectory: URL

    init(environment: LibraryEnvironment, store: LibraryStore, artworkDirectory: URL) {
        self.environment = environment
        self.store = store
        self.artworkDirectory = artworkDirectory
    }

    /// Sweeps until there is nothing left, or until `budget` files have been read.
    ///
    /// - Returns: How many rows were updated. Zero means the library is already
    ///   current, which is the common case after the first launch.
    @discardableResult
    func run(budget: Int = 200) async -> Int {
        var pending: [TrackRecord]
        do {
            pending = try store.loadTracksNeedingTags()
        } catch {
            Self.logger.error("Could not list tracks needing tags: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        guard !pending.isEmpty else { return 0 }

        let limit = min(pending.count, budget)
        Self.logger.notice("Reading tags for \(limit) of \(pending.count) track(s)")

        var updated = 0
        for record in pending[0..<limit] {
            await apply(to: record)
            updated += 1

            // Yield between files so a large library cannot monopolise the
            // cooperative pool behind a launch that appears to have hung.
            await Task.yield()
        }
        return updated
    }

    /// Re-reads one track, ignoring `tags_read`.
    ///
    /// The manual counterpart of the sweep — what "refresh tags" should call.
    @discardableResult
    func refresh(_ trackID: UUID) async -> Bool {
        do {
            guard let record = try store.loadTrack(id: trackID) else { return false }
            await apply(to: record)
            return true
        } catch {
            Self.logger.error("Could not load track \(trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Per-track

    private func apply(to record: TrackRecord) async {
        let url = environment.tracks.appendingPathComponent(record.fileName)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // The row's file is gone. The reconciler owns that diagnosis — it is
            // the component that decides a missing file becomes `.missing` — so
            // this stamps the row read and steps aside rather than racing it.
            Self.logger.notice("No file for \(record.fileName, privacy: .public); skipping")
            try? store.applyTags(to: record.id, from: AudioMetadata(), displayTitle: record.displayTitle, artworkName: nil)
            return
        }

        var metadata = await AudioMetadataReader.read(from: url)
        // Duration and properties come from the same open the validation step
        // would do, but the sweep has no `Probe`. Reuse what is already known
        // rather than inventing zeros that would overwrite real values.
        if metadata.sampleRate == nil { metadata.sampleRate = record.sampleRate }
        if metadata.channelCount == nil { metadata.channelCount = record.channelCount }

        let artworkName = saveArtwork(metadata.artworkData)
        let title = LibraryTagSweep.displayTitle(tagged: metadata.title, fallback: record.displayTitle)

        do {
            try store.applyTags(
                to: record.id,
                from: metadata,
                displayTitle: title,
                artworkName: artworkName
            )
        } catch {
            Self.logger.error("Could not write tags for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The filename-derived title is a placeholder, so a first real tag read
    /// replaces it — but only when the file actually has a title. A sweep must
    /// not be able to blank a title the user set by hand, so a file with no tag
    /// keeps whatever it had.
    private static func displayTitle(tagged: String?, fallback: String) -> String {
        if let tagged, !tagged.isEmpty { return tagged }
        return fallback
    }

    /// Written straight to `Artwork/` rather than through `ArtworkService`.
    ///
    /// `ArtworkService` is reachable only from `AudioManager`, and the sweep runs
    /// before and independently of the UI. It still uses
    /// `ArtworkService.artworkFileName()` for the name, and the same JPEG
    /// quality, so embedded covers and hand-picked covers stay one format in one
    /// directory.
    private func saveArtwork(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let image = UIImage(data: data) else {
            Self.logger.notice("Embedded artwork is not decodable; leaving the row without a cover")
            return nil
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }

        let name = ArtworkService.artworkFileName()
        let destination = artworkDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: artworkDirectory,
                withIntermediateDirectories: true
            )
            try jpeg.write(to: destination)
            return name
        } catch {
            Self.logger.error("Could not write artwork: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
