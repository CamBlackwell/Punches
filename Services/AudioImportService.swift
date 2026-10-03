import Foundation
import AVFoundation

/// The import call sites' entry point.
///
/// This used to hold the entire import implementation. That code had a
/// double-`resume` of a `CheckedContinuation` (a hard trap), a
/// check-then-act race on the destination filename, and a `removeItem` of the
/// whole `PendingImports/` directory. All of it now lives in
/// `LibraryImportPipeline`; this type stays so `audioManager.importService`
/// and the document picker's `for url in urls` loop are unchanged.
final class AudioImportService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    /// Queues one file. Returns immediately; progress and failures arrive via
    /// `manager.importProgress` and `manager.lastImportReport`.
    func importAudioFile(from url: URL) {
        manager.beginImport()
        manager.importPipeline.importAudioFile(from: url)
    }

    /// Drains whatever the share extension queued, and resumes imports that were
    /// interrupted by termination.
    func processPendingImports(shouldAutoPlay: Bool = false) async {
        let report = await manager.importPipeline.drainInboundQueue()
        await manager.importPipeline.resumeInterruptedWork()

        await MainActor.run {
            self.manager.displayedSongs = self.manager.sortedAudioFiles
            self.manager.playbackQueue = self.manager.sortedAudioFiles
        }

        guard shouldAutoPlay, let first = report.succeeded.first else { return }
        manager.play(
            audioFile: first,
            context: manager.sortedAudioFiles,
            fromSongsTab: true
        )
    }
}
