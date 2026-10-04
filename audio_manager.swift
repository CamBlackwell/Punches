import Foundation
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import os

class AudioManager: NSObject, ObservableObject {
    @Published var audioFiles: [AudioFile] = []
    @Published var playlists: [Playlist] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentlyPlayingID: UUID?
    @Published var tempo: Float = 1.0
    @Published var pitch: Float = 0.0
    @Published var selectedAlgorithm: PitchAlgorithm = .apple
    @Published var audioAnalyzer = UnifiedAudioAnalyser()
    @Published var isLooping: Bool = false
    @Published var visualisationMode: VisualisationMode = .Goniometer
    @Published var playingFromSongsTab: Bool = false
    @Published var displayedSongs: [AudioFile] = []
    /// Retained for API compatibility. Prefer `importProgress`, which counts
    /// rather than latching — the old flag was cleared by the *first* of N
    /// concurrent imports to finish.
    @Published var isImporting: Bool = false
    /// Retained for API compatibility; derived from `lastImportReport`. No view
    /// in the project ever read this, which is why import failures were
    /// indistinguishable from files that were never added.
    @Published var importError: String?
    /// Live import activity. Authoritative replacement for `isImporting`.
    @Published var importProgress = ImportProgress()
    /// The outcome of the most recent batch, successes and per-file failures.
    @Published var lastImportReport: ImportReport?
    /// Set once, when a batch finishes with failures, to drive the report sheet.
    ///
    /// Separate from `lastImportReport` because that one is appended to on every
    /// file; presenting directly off it would make the sheet appear and
    /// disappear as the count crossed zero.
    @Published var importReportToPresent: ImportReport?

    var currentEngine: AudioEngineProtocol?
    var timer: Timer?
    let artworkDirectory: URL
    let audioFilesKey = "savedAudioFiles"
    let playlistsKey = "savedPlaylists"
    let algorithmKey = "selectedAlgorithm"
    let visualisationModeKey = "visualisationMode"
    var isSeeking = false
    let masterPlaylistKey = "masterPlaylistID"
    var masterPlaylistID: UUID?

    /// Key under which the storage location in use (App Group vs. the Documents
    /// fallback) is recorded for `DiagnosticsService` to read back. See the note
    /// in `DiagnosticsService.buildSnapshot`: nothing currently writes this, so
    /// `recordedStorageMode` is expected to be `nil` until that is wired up.
    static let storageModeKey = "storageMode"

    var playbackQueue: [AudioFile] = []
    var observerTokens: [Any] = []

    lazy var engineService = AudioEngineService(manager: self)
    lazy var sessionService = AudioSessionService(manager: self)
    lazy var libraryService = AudioLibraryService(manager: self)
    lazy var playlistService = PlaylistService(manager: self)
    lazy var artworkService = ArtworkService(manager: self)
    lazy var importService = AudioImportService(manager: self)
    lazy var playbackService = AudioPlaybackService(manager: self)
    lazy var diagnosticsService = DiagnosticsService(manager: self)

    /// The resolved on-disk layout. Group container when the entitlement is
    /// present, `Documents/Punches` otherwise.
    let libraryEnvironment = LibraryEnvironment.shared
    /// The durable library index. `nil` only if the database could not be
    /// opened, which the UI surfaces as "no library available" rather than
    /// silently operating on an empty library.
    var libraryStore: LibraryStore? { libraryEnvironment.store }
    /// Move-only reconciliation. Never deletes on its own.
    var libraryReconciler: LibraryReconciler? { libraryEnvironment.reconciler }
    /// The journalled import pipeline. All imports funnel through this.
    lazy var importPipeline = LibraryImportPipeline(manager: self, environment: libraryEnvironment)

    /// The canonical library directory.
    ///
    /// Was a `static let` that created `<group>/AudioFiles` if the entitlement
    /// existed and otherwise the *Documents root*. That fallback put audio
    /// beside the app's own documents, which `cleanupOrphanedFiles` then walked
    /// and deleted from — the app could destroy user files. The root is now
    /// always a directory this app owns.
    static let fileDirectory: URL = LibraryEnvironment.shared.tracks

    var sortedAudioFiles: [AudioFile] {
        playlistService.sortedAudioFiles
    }

    var sortedPlaylists: [Playlist] {
        playlistService.sortedPlaylists
    }

    var sortedAlbums: [Playlist] {
        playlistService.sortedAlbums
    }

    override init() {
        self.artworkDirectory = libraryEnvironment.artwork
        super.init()

        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)

        // Synchronous load, as before, so the first frame is not empty. The
        // startup work below may re-load if it recovers anything.
        libraryService.loadAudioFiles()
        playlistService.loadPlaylists()
        playlistService.loadOrCreateMasterPlaylist()

        self.displayedSongs = self.sortedAudioFiles
        self.playbackQueue = self.sortedAudioFiles

        Task { [weak self] in
            await self?.prepareLibrary()
        }

        engineService.loadSelectedAlgorithm()
        libraryService.loadVisualisationMode()
        sessionService.setupAudioSession()
        engineService.initialiseEngine()
        sessionService.setupConfigurationChangeObserver()
        sessionService.setupInterruptionObserver()
        sessionService.setupRouteChangeObserver()
        sessionService.setupLifecycleObservers()
    }

    /// Startup work that cannot block the first frame.
    ///
    /// Ordering is load-bearing: recover before reconcile. The reconciler
    /// classifies anything it does not recognise as reclaimable, so reconciling
    /// first would move exactly the files the migration was meant to rescue into
    /// Trash. The grace period would have saved most of them, but "most" is not a
    /// recovery strategy.
    private func prepareLibrary() async {
        guard let store = libraryStore else {
            LibraryEnvironment.log.fault("No library store; running without persistence")
            return
        }

        let summary = await LibraryMigration(
            environment: libraryEnvironment,
            store: store,
            defaults: .standard
        ).runIfNeeded()

        if summary.adoptedFromDisk > 0 || summary.recoveredFromIndex > 0 {
            await MainActor.run {
                self.libraryService.loadAudioFiles()
                self.playlistService.loadPlaylists()
                self.playlistService.loadOrCreateMasterPlaylist()
            }
        }

        let report = await importPipeline.resumeInterruptedWork()
        if !report.succeeded.isEmpty || !report.failed.isEmpty {
            await MainActor.run { self.lastImportReport = report }
        }

        // The reconciler repairs membership and reclaims untracked bytes, and the
        // result used to be discarded — so the one launch that quietly deleted a
        // file, or dropped a track out of a playlist, left no trace at all. It is
        // not user-visible, but it should not be invisible either.
        if let summary = libraryReconciler?.reconcile(), !summary.isQuiet {
            LibraryEnvironment.log.notice(
                """
                Reconciled library: \(summary.restoredMembership) membership row(s) restored, \
                \(summary.markedMissing.count) track(s) marked missing, \
                \(summary.movedToTrash.count) untracked file(s) reclaimed, \
                \(summary.leftAlone.count) left alone
                """
            )
        }

        await MainActor.run {
            self.displayedSongs = self.sortedAudioFiles
            self.playbackQueue = self.sortedAudioFiles
            self.isImporting = self.importProgress.isRunning
        }

        // Tags last, after the main-actor block above.
        //
        // A track imported before metadata existed has columns full of NULL, and
        // the user should not have to re-add their library to fix that. This runs
        // after `reconcile()` so it never races the reconciler over a file that is
        // missing, and after the UI has its rows so the first paint is not waiting
        // on file I/O. Its reads are awaited, so it yields rather than blocking,
        // and it is bounded per launch, so a large library costs a little
        // background work instead of a stalled start — see `LibraryTagSweep` for
        // why this is not a migration step.
        let updated = await LibraryTagSweep(
            environment: libraryEnvironment,
            store: store,
            artworkDirectory: artworkDirectory
        ).run()

        if updated > 0 {
            LibraryEnvironment.log.notice("Read tags for \(updated) existing track(s)")
            await MainActor.run {
                self.libraryService.loadAudioFiles()
                self.displayedSongs = self.sortedAudioFiles
            }
        }
    }

    deinit {
        timer?.invalidate()
        timer = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        currentEngine?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func saveVisualisationMode() {
        libraryService.saveVisualisationMode()
    }

    func changeAlgorithm(to algorithm: PitchAlgorithm) {
        engineService.changeAlgorithm(to: algorithm)
    }

    /// Starts a fresh import batch, if one is not already running.
    ///
    /// The document picker calls `importAudioFile` once per selected URL in a
    /// tight loop, so this arrives repeatedly for what is really one batch.
    /// Resetting unconditionally would therefore wipe the progress count and the
    /// results of the files already queued. The pipeline increments `active`
    /// *synchronously* on the first call, so the guard is accurate from the very
    /// first URL and the rest of the loop is correctly recognised as continuing
    /// the same batch.
    func beginImport() {
        importError = nil
        guard importProgress.active == 0 else { return }
        lastImportReport = nil
        importReportToPresent = nil
        importProgress = ImportProgress()
    }

    /// Called as each import finishes. Resets progress and offers the report
    /// once the last one lands.
    ///
    /// Imports are serialised by the pipeline's tail, so `active` reaching zero
    /// genuinely means the batch is over rather than two files finishing at once.
    func finishOneImport() {
        importProgress.active = max(0, importProgress.active - 1)
        isImporting = importProgress.isRunning

        guard importProgress.active == 0 else { return }

        if let report = lastImportReport, report.hasFailures {
            importReportToPresent = report
        }

        importProgress = ImportProgress()
        isImporting = false
    }

    func importAudioFile(from url: URL) {
        importService.importAudioFile(from: url)
    }

    func processPendingImports(shouldAutoPlay: Bool = false) async {
        await importService.processPendingImports(shouldAutoPlay: shouldAutoPlay)
    }

    func deleteAudioFile(_ audioFile: AudioFile) {
        libraryService.deleteAudioFile(audioFile)
    }

    func renameAudioFile(_ audioFile: AudioFile, to newTitle: String) {
        libraryService.renameAudioFile(audioFile, to: newTitle)
    }

    func urlForSharing(_ audioFile: AudioFile) -> URL? {
        libraryService.urlForSharing(audioFile)
    }

    func createPlaylist(name: String) {
        DispatchQueue.main.async { [weak self] in
            self?.playlistService.createPlaylist(name: name)
        }
    }

    func createAlbum(name: String, artist: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.playlistService.createPlaylist(name: name, isAlbum: true, artist: artist)
        }
    }

    func coverName(for album: Playlist, songs: [AudioFile]) -> String? {
        playlistService.coverName(for: album, songs: songs)
    }

    func songsByPlaylistID(for playlists: [Playlist]) -> [UUID: [AudioFile]] {
        playlistService.songsByPlaylistID(for: playlists)
    }

    func setArtist(_ artist: String?, for playlist: Playlist) {
        playlistService.setArtist(artist, for: playlist)
    }

    func deletePlaylist(_ playlist: Playlist) {
        playlistService.deletePlaylist(playlist)
    }

    func renamePlaylist(_ playlist: Playlist, to newName: String) {
        playlistService.renamePlaylist(playlist, to: newName)
    }

    func addAudioFile(_ audioFile: AudioFile, to playlist: Playlist) {
        playlistService.addAudioFile(audioFile, to: playlist)
    }

    func removeAudioFile(_ audioFile: AudioFile, from playlist: Playlist) {
        playlistService.removeAudioFile(audioFile, from: playlist)
    }

    func getAudioFiles(for playlist: Playlist) -> [AudioFile] {
        playlistService.getAudioFiles(for: playlist)
    }

    func reorderSongs(from source: IndexSet, to destination: Int) {
        playlistService.reorderSongs(from: source, to: destination)
    }

    func reorderPlaylistSongs(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        playlistService.reorderPlaylistSongs(in: playlist, from: source, to: destination)
    }

    func updatePlaylistOrder(_ playlist: Playlist, with ids: [UUID]) {
        playlistService.updatePlaylistOrder(playlist, with: ids)
    }

    func savePlaylists() {
        playlistService.savePlaylists()
    }

    func setArtwork(_ image: UIImage, for audioFile: AudioFile) {
        artworkService.setArtwork(image, for: audioFile)
    }

    func setArtwork(_ image: UIImage, for playlist: Playlist) {
        artworkService.setArtwork(image, for: playlist)
    }

    func removeArtwork(from audioFile: AudioFile) {
        artworkService.removeArtwork(from: audioFile)
    }

    func removeArtwork(from playlist: Playlist) {
        artworkService.removeArtwork(from: playlist)
    }

    func play(audioFile: AudioFile, context: [AudioFile]? = nil, fromSongsTab: Bool = false) {
        playbackService.play(audioFile: audioFile, context: context, fromSongsTab: fromSongsTab)
    }

    func stop() {
        playbackService.stop()
    }

    func togglePlayPause() {
        playbackService.togglePlayPause()
    }

    func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    func setVolume(_ volume: Float) {
        playbackService.setVolume(volume)
    }

    func setTempo(_ newTempo: Float) {
        playbackService.setTempo(newTempo)
    }

    func setPitch(_ newPitch: Float) {
        playbackService.setPitch(newPitch)
    }

    func skipPreviousSong() {
        playbackService.skipPreviousSong()
    }

    func skipNextSong() {
        playbackService.skipNextSong()
    }

    func reorderSelectedSongs(selectedIDs: [UUID], to destination: Int, in currentSongs: [AudioFile], playlist: Playlist? = nil) {
        playbackService.reorderSelectedSongs(selectedIDs: selectedIDs, to: destination, in: currentSongs, playlist: playlist)
    }
    
    @MainActor
    func attachAnalyzerSafely() {
        guard let engine = currentEngine?.getAudioEngine() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.audioAnalyzer.attach(to: engine)
        }
    }
}

extension AudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingID = nil
        currentTime = 0
        timer?.invalidate()
        timer = nil
    }
}
