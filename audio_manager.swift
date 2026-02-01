import Foundation
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

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
    @Published var visualisationMode: VisualisationMode = .both
    @Published var playingFromSongsTab: Bool = false
    @Published var displayedSongs: [AudioFile] = []
    @Published var isImporting: Bool = false
    @Published var importError: String?

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

    var playbackQueue: [AudioFile] = []
    var observerTokens: [Any] = []

    lazy var engineService = AudioEngineService(manager: self)
    lazy var sessionService = AudioSessionService(manager: self)
    lazy var libraryService = AudioLibraryService(manager: self)
    lazy var playlistService = PlaylistService(manager: self)
    lazy var artworkService = ArtworkService(manager: self)
    lazy var importService = AudioImportService(manager: self)
    lazy var playbackService = AudioPlaybackService(manager: self)

    static let fileDirectory: URL = {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier) {
            let dir = groupURL.appendingPathComponent("AudioFiles", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
    }()

    var sortedAudioFiles: [AudioFile] {
        playlistService.sortedAudioFiles
    }

    var sortedPlaylists: [Playlist] {
        playlistService.sortedPlaylists
    }

    override init() {
        self.artworkDirectory = AudioManager.fileDirectory.appendingPathComponent("Artwork", isDirectory: true)
        super.init()

        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)

        
        libraryService.loadAudioFiles()
        playlistService.loadPlaylists()
        playlistService.loadOrCreateMasterPlaylist()

        Task { [weak self] in
            guard let self else { return }
            await self.importService.processPendingImports()
            self.libraryService.cleanupOrphanedFiles()
        }

        self.displayedSongs = self.sortedAudioFiles
        self.playbackQueue = self.sortedAudioFiles

        engineService.loadSelectedAlgorithm()
        libraryService.loadVisualisationMode()
        sessionService.setupAudioSession()
        engineService.initialiseEngine()
        sessionService.setupConfigurationChangeObserver()
        sessionService.setupInterruptionObserver()
        sessionService.setupRouteChangeObserver()
        sessionService.setupLifecycleObservers()
        
        

        print(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) ?? "Failed to access AppGroup")
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
        playlistService.createPlaylist(name: name)
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
