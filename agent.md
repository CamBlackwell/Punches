//
//  AudioManager.swift
//  AudioAgent
//
//  Created by OpenAI GPT-4 on 2026-06-29.
//

import Foundation
import SwiftUI
import AVFoundation
import Combine

/// Central coordinator for audio playback, session management, library, playlists, artwork, imports, and analysis.
/// This class is the single source of truth for playback state and orchestrates all services.
///
/// Usage:
/// - Use the shared `AudioManager` instance in views and services.
/// - Call `play(audioFile:context:fromSongsTab:)` to start playback.
/// - Observe published properties for UI updates.
final class AudioManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// List of audio files in the library.
    @Published private(set) var audioFiles: [AudioFile] = []
    
    /// List of playlists including the master playlist.
    @Published private(set) var playlists: [Playlist] = []
    
    /// The ID of the master playlist, always present.
    @Published private(set) var masterPlaylistID: UUID?
    
    /// Current playback state.
    @Published private(set) var isPlaying: Bool = false
    
    /// Current playback time in seconds.
    @Published private(set) var currentTime: TimeInterval = 0
    
    /// Duration of the currently playing track.
    @Published private(set) var currentDuration: TimeInterval = 0
    
    /// ID of the currently playing audio file.
    @Published private(set) var currentlyPlayingID: UUID?
    
    /// Tempo and pitch adjustment algorithm selection.
    @Published var algorithm: AudioAlgorithm = .appleTimePitch {
        didSet {
            changeAlgorithm(to: algorithm)
        }
    }
    
    /// Visualization mode selection.
    @Published var visualisationMode: VisualisationMode = .standard
    
    // MARK: - Constants and Keys
    
    private let audioFilesKey = "audioFilesKey"
    private let playlistsKey = "playlistsKey"
    private let algorithmKey = "algorithmKey"
    private let visualisationModeKey = "visualisationModeKey"
    private let masterPlaylistKey = "masterPlaylistKey"
    
    // MARK: - File Directories
    
    /// Directory where audio files are saved.
    let fileDirectory: URL
    
    /// Directory for artwork images.
    let artworkDirectory: URL
    
    // MARK: - Services (Lazy Init)
    
    lazy var audioEngineService = AudioEngineService(manager: self)
    lazy var audioSessionService = AudioSessionService(manager: self)
    lazy var audioLibraryService = AudioLibraryService(manager: self)
    lazy var playlistService = PlaylistService(manager: self)
    lazy var artworkService = ArtworkService(manager: self)
    lazy var audioImportService = AudioImportService(manager: self)
    lazy var audioPlaybackService = AudioPlaybackService(manager: self)
    lazy var analyzer: UnifiedAudioAnalyser = UnifiedAudioAnalyser()
    
    // MARK: - Engine
    
    /// Underlying audio engine protocol instance.
    var audioEngine: AudioEngineProtocol {
        audioEngineService.audioEngine
    }
    
    // MARK: - Timers and Queues
    
    private var playbackTimer: Timer?
    
    // MARK: - Initialization
    
    init(fileDirectory: URL? = nil) {
        if let dir = fileDirectory {
            self.fileDirectory = dir
        } else {
            // Default to Application Support directory or App Group directory if available.
            self.fileDirectory = AudioManager.defaultFileDirectory()
        }
        self.artworkDirectory = fileDirectory.appendingPathComponent("Artwork", isDirectory: true)
        
        loadPersistedData()
        setupSessionNotifications()
        audioEngineService.initialiseEngine(algorithm: algorithm)
        
        // Ensure master playlist exists.
        if masterPlaylistID == nil {
            let master = Playlist.masterPlaylist(with: audioFiles)
            playlists.append(master)
            masterPlaylistID = master.id
            savePlaylists()
        }
    }
    
    // MARK: - Playback Control
    
    /// Start playback of the specified audio file.
    /// - Parameters:
    ///   - audioFile: The audio file to play.
    ///   - context: Optional context for playback.
    ///   - fromSongsTab: Indicates if playback was initiated from the Songs tab.
    func play(audioFile: AudioFile, context: PlaybackContext? = nil, fromSongsTab: Bool = false) {
        audioPlaybackService.play(audioFile: audioFile, context: context, fromSongsTab: fromSongsTab)
        currentlyPlayingID = audioFile.id
        currentDuration = audioFile.audioDuration
        isPlaying = true
        attachAnalyzerSafely()
        startPlaybackTimer()
    }
    
    func pause() {
        audioPlaybackService.pause()
        isPlaying = false
        stopPlaybackTimer()
    }
    
    func stop() {
        audioPlaybackService.stop()
        isPlaying = false
        currentTime = 0
        currentlyPlayingID = nil
        stopPlaybackTimer()
        detachAnalyzer()
    }
    
    /// Seek to a specific time in the currently playing track.
    /// - Parameter time: Time in seconds.
    func seek(to time: TimeInterval) {
        audioPlaybackService.seek(to: time)
        currentTime = time
    }
    
    // MARK: - Analyzer Tap Management
    
    /// Attaches the audio analyzer tap if safe.
    func attachAnalyzerSafely() {
        analyzer.installTapSafely(on: audioEngine.mainMixerNode)
    }
    
    /// Detaches the audio analyzer tap.
    func detachAnalyzer() {
        analyzer.removeTap(from: audioEngine.mainMixerNode)
    }
    
    // MARK: - Playback Timer
    
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updatePlaybackTime()
        }
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    private func updatePlaybackTime() {
        guard isPlaying else { return }
        currentTime = audioPlaybackService.currentTime
        if currentTime >= currentDuration {
            // Handle end-of-track
            audioPlaybackService.handleTrackEnd()
            stopPlaybackTimer()
        }
    }
    
    // MARK: - Algorithm Change
    
    /// Changes the audio processing algorithm.
    /// - Parameter algorithm: The new algorithm to use.
    private func changeAlgorithm(to algorithm: AudioAlgorithm) {
        audioEngineService.changeAlgorithm(to: algorithm)
        saveAlgorithm()
    }
    
    // MARK: - Persistence
    
    /// Loads persisted audio files, playlists, and settings.
    private func loadPersistedData() {
        audioFiles = audioLibraryService.loadAudioFiles()
        playlists = playlistService.loadPlaylists()
        masterPlaylistID = UserDefaults.standard.uuid(forKey: masterPlaylistKey)
        algorithm = UserDefaults.standard.audioAlgorithm(forKey: algorithmKey) ?? .appleTimePitch
        visualisationMode = UserDefaults.standard.visualisationMode(forKey: visualisationModeKey) ?? .standard
    }
    
    /// Saves audio files to persistent storage.
    func saveAudioFiles() {
        audioLibraryService.saveAudioFiles(audioFiles)
    }
    
    /// Saves playlists to persistent storage.
    func savePlaylists() {
        playlistService.savePlaylists(playlists)
        if let masterID = masterPlaylistID {
            UserDefaults.standard.set(masterID, forKey: masterPlaylistKey)
        }
    }
    
    /// Saves the current algorithm selection.
    private func saveAlgorithm() {
        UserDefaults.standard.set(algorithm.rawValue, forKey: algorithmKey)
    }
    
    /// Saves the current visualization mode.
    private func saveVisualisationMode() {
        UserDefaults.standard.set(visualisationMode.rawValue, forKey: visualisationModeKey)
    }
    
    // MARK: - Session Notifications
    
    private func setupSessionNotifications() {
        audioSessionService.setupNotifications()
    }
    
    // MARK: - Static Helpers
    
    /// Returns the default file directory, preferring the app group container if available.
    private static func defaultFileDirectory() -> URL {
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.audioagent") {
            return appGroupURL.appendingPathComponent("AudioFiles", isDirectory: true)
        } else {
            let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            let appSupportURL = urls[0]
            let directory = appSupportURL.appendingPathComponent("AudioAgent", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            return directory
        }
    }
}

// MARK: - Supporting Types

enum AudioAlgorithm: String, Codable {
    case appleTimePitch = "AppleTimePitch"
    // Add other algorithms here.
}

enum VisualisationMode: String, Codable {
    case standard
    case q3Spectrum
    // Add other visualization modes here.
}

enum PlaybackContext {
    case playlist(UUID)
    case search(String)
    case none
}

// MARK: - UserDefaults Helpers

private extension UserDefaults {
    func uuid(forKey key: String) -> UUID? {
        guard let string = string(forKey: key) else { return nil }
        return UUID(uuidString: string)
    }
    
    func audioAlgorithm(forKey key: String) -> AudioAlgorithm? {
        guard let raw = string(forKey: key) else { return nil }
        return AudioAlgorithm(rawValue: raw)
    }
    
    func visualisationMode(forKey key: String) -> VisualisationMode? {
        guard let raw = string(forKey: key) else { return nil }
        return VisualisationMode(rawValue: raw)
    }
    
    func set(_ uuid: UUID, forKey key: String) {
        set(uuid.uuidString, forKey: key)
    }
    
    func set(_ algorithmRawValue: String, forKey key: String) {
        set(algorithmRawValue, forKey: key)
    }
}

// MARK: - Playlist Extension

private extension Playlist {
    static func masterPlaylist(with audioFiles: [AudioFile]) -> Playlist {
        Playlist(id: UUID(), name: "__MASTER_SONGS__", audioFileIDs: audioFiles.map { $0.id }, dateAdded: Date(), artworkImageName: nil)
    }
}
