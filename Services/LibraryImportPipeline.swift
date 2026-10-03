import Foundation
import AVFoundation
import os

/// The import pipeline: every file the user adds passes through here.
///
/// ## What this replaces, and the three ways it lost files
///
/// The previous `AudioImportService.importAudioFile` had three independent ways
/// to lose a file while appearing to work, all of them silent because
/// `AudioManager.importError` was written but never read by any view:
///
/// 1. **A `CheckedContinuation` resumed twice.** `NSFileCoordinator`'s accessor
///    and its `coordinationError` out-parameter were both wired to `resume`, and
///    the coordinator can run both when a coordinated file changes mid-read.
///    A double resume *traps*, so the process aborted mid-batch: the files
///    already committed survived, everything after them did not, and the copies
///    already on disk were then deleted as untracked at the next launch. This is
///    the mechanism behind "a subset imported fine and then vanished".
/// 2. **A check-then-act race on the destination name.**
///    `generateUniqueFileName` deduplicated by testing whether the destination
///    *file* existed, from N concurrent tasks. Two tracks with the same basename
///    both got the same name, and the loser's `copyItem` threw — silently.
/// 3. **Membership written outside the track's own write.** The master-playlist
///    append sat inside an `if let`, and `sortedAudioFiles` is driven entirely by
///    that playlist, so an import whose membership write was skipped left a file
///    on disk and in the index that the Songs tab could never display.
///
/// The structure below removes each one by construction: a single-resume
/// helper, UUID content-addressed paths with an atomic rename, and a single
/// transaction covering the track row, its membership, and the journal.
final class LibraryImportPipeline {

    private static let logger = Logger(
        subsystem: "com.punches.library",
        category: "import"
    )

    /// All coordinated filesystem work is funnelled through one serial queue.
    ///
    /// It is a `DispatchQueue` rather than the cooperative pool because
    /// `NSFileCoordinator` blocks, and it is serial rather than concurrent
    /// because serialising the copies removes the destination-name race at the
    /// source instead of papering over it with uniquing.
    private static let ioQueue = DispatchQueue(
        label: "com.punches.library.io",
        qos: .userInitiated
    )

    unowned let manager: AudioManager

    private let environment: LibraryEnvironment
    private let store: LibraryStore?

    /// Serialises whole imports so a 50-file selection cannot interleave its
    /// commits. `submit` chains onto the previous job's completion.
    private let tailLock = NSLock()
    private var pipelineTail: Task<Void, Never>?

    init(manager: AudioManager, environment: LibraryEnvironment) {
        self.manager = manager
        self.environment = environment
        self.store = environment.store
    }

    // MARK: - Public entry points

    /// Queues one file for import. Matches the old signature so existing call
    /// sites — including the document picker's `for url in urls` loop — are
    /// unchanged.
    func importAudioFile(from url: URL) {
        guard store != nil else {
            publish(
                ImportReport(
                    failed: [FailedImport(
                        name: url.lastPathComponent,
                        failure: .noPermission,
                        underlying: "No library store"
                    )]
                )
            )
            return
        }

        let sourceName = url.lastPathComponent

        // Counted synchronously, not inside the queued task: the document picker
        // submits the whole selection in one loop, and `beginImport` decides
        // whether a call starts a new batch by looking at `active`. If the
        // increment were deferred to the task, every URL in the selection would
        // believe it was starting a batch and reset the ones before it.
        manager.importProgress.total += 1
        manager.importProgress.active += 1
        manager.isImporting = true

        submit { [weak self] in
            await self?.runDocumentPickerImport(from: url, sourceName: sourceName)
        }
    }

    /// Resumes any import that was interrupted by termination, and drains
    /// anything the share extension handed over.
    ///
    /// - Returns: A report of what was recovered.
    @discardableResult
    func resumeInterruptedWork() async -> ImportReport {
        var report = ImportReport()
        guard let store else { return report }

        await drainInboundQueue()

        let resumable = (try? store.loadResumableImportJobs()) ?? []
        let pending = resumable.filter { !$0.isInbound }

        guard !pending.isEmpty else { return report }

        Self.logger.notice("Resuming \(pending.count) interrupted import(s)")

        for job in pending {
            report.merge(await resume(job))
        }

        return report
    }

    /// Claims and commits whatever the share extension left in `Inbound/`.
    ///
    /// ## The directory is the queue
    ///
    /// The old protocol was a `[String]` of filenames in a shared
    /// `UserDefaults` array plus a `PendingImports/` directory. That is two
    /// sources of truth that can disagree, written without a transaction, and
    /// cleaned up with `removeItem(at: pendingDirectory)` — which deleted every
    /// file in the batch, including the ones the loop had not reached yet when it
    /// was interrupted.
    ///
    /// Now a file's presence *is* the intent, and its name carries everything
    /// needed to import it: `<uuid>--<original file name>`. The extension never
    /// opens the database, so there is no cross-process write to race, and each
    /// file is consumed individually — after its own row is committed.
    @discardableResult
    func drainInboundQueue() async -> ImportReport {
        var report = ImportReport()
        guard store != nil, environment.shareExtensionAvailable else { return report }

        let inbound = Self.inboundFiles(in: environment.inbound)
        guard !inbound.isEmpty else { return report }

        Self.logger.notice("Draining \(inbound.count) inbound file(s)")

        for file in inbound {
            report.merge(await commitInbound(file))
        }

        return report
    }

    /// A file the share extension handed over.
    private struct InboundFile {
        var id: UUID
        var originalName: String
        var url: URL
    }

    /// Parses `<uuid>--<original file name>` entries in the inbound directory.
    ///
    /// Unparseable names are reported rather than skipped silently: a file the
    /// app cannot interpret is still a file the user shared.
    private static func inboundFiles(in directory: URL) -> [InboundFile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [InboundFile] = []
        for url in entries {
            let name = url.lastPathComponent
            guard let separator = name.range(of: "--"),
                  let id = UUID(uuidString: String(name[name.startIndex..<separator.lowerBound]))
            else {
                Self.logger.fault("Unrecognised inbound file: \(name, privacy: .public)")
                continue
            }

            let original = String(name[separator.upperBound...])
            guard !original.isEmpty else {
                Self.logger.fault("Inbound file with no original name: \(name, privacy: .public)")
                continue
            }

            files.append(InboundFile(id: id, originalName: original, url: url))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - Job execution

    private func runDocumentPickerImport(from url: URL, sourceName: String) async {
        guard let store else { return }

        var jobID: UUID?
        var stagedURL: URL?

        do {
            // 1. Journal first. From this line on, the app can always answer
            //    "what was in flight?", which is what makes an interrupted
            //    import resumable instead of a partial loss. The source URL is
            //    captured as a security-scoped bookmark so the original file
            //    stays reachable after the scope is released — the old code threw
            //    that handle away at its `defer`.
            let bookmark = Self.makeBookmark(for: url)
            jobID = try store.createImportJob(
                sourceName: sourceName,
                sourceExt: url.pathExtension,
                sourceURL: bookmark,
                origin: .documentPicker
            )

            // 2. Security scope, held for the whole job.
            guard url.startAccessingSecurityScopedResource() else {
                throw ImportFailure.noPermission
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // 3. Re-issue the bookmark while access is live, so the persisted
            //    one is not the stale version the picker handed us.
            let refreshed = Self.makeBookmark(for: url)
            try store.updateImportJob(
                jobID!,
                state: .scoped,
                bookmark: refreshed ?? bookmark
            )

            // 4. Make the bytes local. A FileProvider file that has not been
            //    downloaded fails the copy on iOS; this is what used to surface
            //    as "File not found or still downloading" with no explanation.
            try await materialise(url)
            try store.updateImportJob(jobID!, state: .materialised)

            // 5. Stage under a UUID name via an atomic rename, so a partial
            //    copy is never visible under its final name and two files with
            //    the same basename cannot collide.
            let staged = try await stage(from: url, jobID: jobID!)
            stagedURL = staged
            try store.updateImportJob(jobID!, state: .staged, stagedName: staged.lastPathComponent)

            // 6. Validate.
            let duration = try await validate(staged)
            try store.updateImportJob(jobID!, state: .validated)

            // 7. Promote to the library directory, *then* commit the row.
            //    Bytes before row: a failure between the two leaves untracked
            //    bytes, which the reconciler moves to Trash. Row before bytes
            //    would leave a committed row pointing at nothing, which reads to
            //    the user as a lost file.
            let trackURL = try promote(staged: staged, jobID: jobID!)

            let record = TrackRecord(
                id: UUID(),
                fileName: trackURL.lastPathComponent,
                sourceName: sourceName,
                displayTitle: (sourceName as NSString).deletingPathExtension,
                ext: url.pathExtension,
                byteSize: Self.byteSize(of: trackURL),
                duration: duration,
                dateAdded: Date(),
                artworkName: nil,
                originBookmark: refreshed ?? bookmark,
                state: .committed,
                rejectReason: nil,
                importedVia: .documentPicker
            )

            let masterID = manager.masterPlaylistID
            try store.commitImport(
                jobID: jobID!,
                record: record,
                addToPlaylist: masterID,
                position: nil
            )
            stagedURL = nil

            await projectOntoUI(record, masterPlaylistID: masterID)
            Self.logger.notice("Imported \(sourceName, privacy: .public)")

        } catch {
            let failure = ImportFailure.classify(error)
            let reason = error.localizedDescription

            if let jobID {
                try? store.rejectImport(jobID: jobID, sourceName: sourceName, reason: reason)
            }

            // The user's original file is never touched. Our staged copy, if
            // any, goes to Trash rather than being unlinked — the old code
            // deleted it outright on validation failure.
            if let stagedURL, FileManager.default.fileExists(atPath: stagedURL.path) {
                try? environment.reconciler?.moveToTrash(stagedURL, reason: "rejected")
            }

            Self.logger.error(
                "Import of \(sourceName, privacy: .public) failed [\(failure.rawValue, privacy: .public)]: \(reason, privacy: .public)"
            )

            await MainActor.run {
                // Read-modify-write; see `projectOntoUI`.
                var report = self.manager.lastImportReport ?? ImportReport()
                report.failed.append(
                    FailedImport(name: sourceName, failure: failure, underlying: reason)
                )
                self.manager.lastImportReport = report
                self.manager.finishOneImport()
            }
        }
    }

    private func resume(_ job: ImportJob) async -> ImportReport {
        guard let url = Self.resolveBookmark(job.sourceURL) else {
            return ImportReport(failed: [
                FailedImport(
                    name: job.sourceName,
                    failure: .sourceVanished,
                    underlying: job.lastError
                )
            ])
        }
        await runDocumentPickerImport(from: url, sourceName: job.sourceName)
        return ImportReport()
    }

    private func commitInbound(_ inbound: InboundFile) async -> ImportReport {
        guard let store else { return ImportReport() }

        let ext = (inbound.originalName as NSString).pathExtension
        let stagedName = ext.isEmpty ? inbound.id.uuidString : "\(inbound.id.uuidString).\(ext)"
        let staged = environment.staging.appendingPathComponent(stagedName)

        // Journal under the id already encoded in the filename, so a drain that
        // is killed halfway resumes this exact job instead of orphaning a row
        // that would be retried forever. The insert is idempotent, so re-draining
        // an interrupted handoff is safe.
        do {
            try store.createImportJob(
                id: inbound.id,
                sourceName: inbound.originalName,
                sourceExt: ext,
                sourceURL: nil,
                origin: .shareExtension
            )
        } catch {
            Self.logger.error(
                "Could not journal inbound \(inbound.originalName, privacy: .public)"
            )
            return ImportReport(failed: [
                FailedImport(name: inbound.originalName, failure: .classify(error))
            ])
        }

        do {
            try store.updateImportJob(inbound.id, state: .staged, stagedName: stagedName)

            // Move, don't copy: the bytes are already inside our container.
            if FileManager.default.fileExists(atPath: staged.path) {
                try? environment.reconciler?.moveToTrash(staged, reason: "reclaimed-inbound")
            }
            try FileManager.default.moveItem(at: inbound.url, to: staged)

            let duration = try await validate(staged)
            let trackURL = try promote(staged: staged, jobID: inbound.id)

            let record = TrackRecord(
                id: UUID(),
                fileName: trackURL.lastPathComponent,
                sourceName: inbound.originalName,
                displayTitle: ((inbound.originalName as NSString).deletingPathExtension),
                ext: ext,
                byteSize: Self.byteSize(of: trackURL),
                duration: duration,
                dateAdded: Date(),
                artworkName: nil,
                originBookmark: nil,
                state: .committed,
                rejectReason: nil,
                importedVia: .shareExtension
            )

            let masterID = manager.masterPlaylistID
            try store.commitImport(
                jobID: inbound.id,
                record: record,
                addToPlaylist: masterID,
                position: nil
            )

            await projectOntoUI(record, masterPlaylistID: masterID, countsTowardBatch: false)
            return ImportReport(succeeded: [record.audioFile])

        } catch {
            let failure = ImportFailure.classify(error)
            try? store.rejectImport(
                jobID: inbound.id,
                sourceName: inbound.originalName,
                reason: error.localizedDescription
            )

            if FileManager.default.fileExists(atPath: staged.path) {
                try? environment.reconciler?.moveToTrash(staged, reason: "rejected")
            }

            Self.logger.error("Inbound import failed [\(failure.rawValue, privacy: .public)]")
            return ImportReport(failed: [
                FailedImport(
                    name: inbound.originalName,
                    failure: failure,
                    underlying: error.localizedDescription
                )
            ])
        }
    }

    // MARK: - Stages

    /// Ensures a FileProvider (iCloud Drive) file is actually local.
    ///
    /// On iOS there is no `startDownloadingUbiquitousItem`; the provider
    /// materialises on first read. So: detect the not-downloaded state, nudge it
    /// with a tiny coordinated read, then wait for the status to settle. A file
    /// that never settles is reported as `.cloudNotDownloaded` instead of
    /// failing later with an opaque read error.
    private func materialise(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
        let status = try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus

        guard status == .notDownloaded else { return }

        _ = try? await coordinatedNudge(url)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let current = try? url.resourceValues(forKeys: keys).ubiquitousItemDownloadingStatus
            guard current == .notDownloaded else { return }
        }

        throw ImportFailure.cloudNotDownloaded
    }

    private func coordinatedNudge(_ url: URL) async throws -> Int {
        try await performBlocking {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return (try handle.read(upToCount: 4096) ?? Data()).count
        }
    }

    /// Copies into `Staging/` under a UUID name, then renames into place.
    ///
    /// The name is derived from the job id, never from the user's filename, so
    /// two `Intro.mp3`s in one selection cannot collide — which is what made the
    /// old `generateUniqueFileName` race fail.
    private func stage(from url: URL, jobID: UUID) async throws -> URL {
        let ext = url.pathExtension
        let name = ext.isEmpty ? jobID.uuidString : "\(jobID.uuidString).\(ext)"
        let partial = environment.staging.appendingPathComponent("\(name).partial")
        let final = environment.staging.appendingPathComponent(name)

        // A `.partial` is an incomplete write from a prior attempt at this same
        // job. It has no value and is not a user file, so unlinking it is the one
        // place an unlink is correct.
        try? FileManager.default.removeItem(at: partial)
        if FileManager.default.fileExists(atPath: final.path) {
            try? environment.reconciler?.moveToTrash(final, reason: "restaged")
        }

        try await performBlocking {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?

            // `coordinate(readingItemAt:options:error:byAccessor:)` is
            // synchronous, so its result is captured directly. The old code
            // bridged it through a continuation and then resumed a second time
            // for `coordinationError`, which traps.
            coordinator.coordinate(
                readingItemAt: url,
                options: [.withoutChanges],
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try FileManager.default.copyItem(at: coordinatedURL, to: partial)
                } catch {
                    copyError = error
                }
            }

            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }

            // Atomic within the volume: a truncated copy is never visible under
            // the final name.
            try FileManager.default.moveItem(at: partial, to: final)
        }

        return final
    }

    /// Renames a staged file into the library directory.
    ///
    /// Destination names are job-scoped UUIDs, so a file already sitting there
    /// means an earlier attempt at this same job got as far as promoting and then
    /// failed before committing. It is moved to Trash rather than unlinked.
    private func promote(staged: URL, jobID: UUID) throws -> URL {
        let destination = environment.tracks.appendingPathComponent(staged.lastPathComponent)

        if FileManager.default.fileExists(atPath: destination.path) {
            try? environment.reconciler?.moveToTrash(destination, reason: "repromoted")
        }

        try FileManager.default.moveItem(at: staged, to: destination)
        Self.logger.debug("Promoted \(jobID.uuidString, privacy: .public)")
        return destination
    }

    private func validate(_ url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw ImportFailure.unsupportedCodec
        }

        let seconds = Float(CMTimeGetSeconds(duration))
        guard seconds > 0, seconds.isFinite else {
            throw ImportFailure.invalidDuration
        }

        let playable = (try? await asset.load(.isPlayable)) ?? true
        guard playable else { throw ImportFailure.notPlayable }

        return seconds
    }

    // MARK: - Projection

    /// Adds a freshly committed row to the in-memory model the views read.
    ///
    /// The store already holds this row; this keeps `audioFiles` and the master
    /// playlist in step with it so the Songs tab shows the track immediately.
    ///
    /// - Parameter countsTowardBatch: `false` for inbound handoffs, which were
    ///   never counted in `importProgress` — decrementing there would consume
    ///   another import's slot in the progress counter.
    @MainActor
    private func projectOntoUI(
        _ record: TrackRecord,
        masterPlaylistID: UUID?,
        countsTowardBatch: Bool = true
    ) async {
        let audioFile = record.audioFile

        if !manager.audioFiles.contains(where: { $0.id == audioFile.id }) {
            manager.audioFiles.append(audioFile)
        }

        if let masterPlaylistID,
           let index = manager.playlists.firstIndex(where: { $0.id == masterPlaylistID }),
           !manager.playlists[index].audioFileIDs.contains(audioFile.id) {
            manager.playlists[index].audioFileIDs.append(audioFile.id)
            manager.playlistService.savePlaylists()
        }

        manager.displayedSongs = manager.sortedAudioFiles

        // Read, mutate the local copy, then write back. `report?.succeeded.append`
        // would mutate the struct in place and never reach the `@Published`
        // setter, so the view would silently not update — the same class of
        // "the write happened but nobody can see it" bug as the missing
        // membership write.
        var report = manager.lastImportReport ?? ImportReport()
        report.succeeded.append(audioFile)
        manager.lastImportReport = report

        if countsTowardBatch {
            manager.finishOneImport()
        }

        if manager.playbackQueue.count == manager.audioFiles.count - 1 {
            manager.playbackQueue = manager.sortedAudioFiles
        }
    }

    private func publish(_ report: ImportReport) {
        Task { @MainActor in
            manager.lastImportReport = report
        }
    }

    // MARK: - Plumbing

    /// Chains an import onto the one before it, so a batch cannot interleave.
    ///
    /// A plain `Task` rather than `Task.detached`, deliberately: it inherits the
    /// caller's isolation, so the body runs where `importAudioFile` was called
    /// and every `manager` mutation is already on the main actor. The genuinely
    /// blocking work is pushed to `ioQueue` by `performBlocking`, so nothing slow
    /// executes here.
    private func submit(_ work: @escaping () async -> Void) {
        tailLock.lock()
        let previous = pipelineTail
        pipelineTail = Task {
            _ = await previous?.value
            await work()
        }
        tailLock.unlock()
    }

    /// Runs a blocking filesystem operation off the main thread.
    ///
    /// Exactly one `resume`, from exactly one place — the structural fix for the
    /// double-resume trap that could abort the process mid-import.
    private func performBlocking<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            Self.logger.notice("Bookmark was stale; re-issuing")
            _ = makeBookmark(for: url)
        }
        return url
    }

    private static func byteSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
