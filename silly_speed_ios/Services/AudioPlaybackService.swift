import Foundation
import AVFoundation
import MediaPlayer

final class AudioPlaybackService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func play(audioFile: AudioFile, context: [AudioFile]?, fromSongsTab: Bool) {
        let isSameSong = manager.currentlyPlayingID == audioFile.id

        if let context = context {
            manager.playbackQueue = context
        } else if manager.playbackQueue.isEmpty || !manager.playbackQueue.contains(where: { $0.id == audioFile.id }) {
            manager.playbackQueue = manager.sortedAudioFiles
        }

        manager.playingFromSongsTab = fromSongsTab

        if isSameSong {
            manager.sessionService.updateNowPlayingInfo()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Could not activate session: \(error)")
            return
        }

        guard let engine = manager.currentEngine else { return }

        stopTimer()
        manager.currentTime = 0

        if manager.currentlyPlayingID != audioFile.id {
            engine.stop()
        }

        engine.load(audioFile: audioFile)
        engine.setTempo(manager.tempo)
        engine.setPitch(manager.pitch)

        engine.play()

        manager.isPlaying = true
        manager.currentlyPlayingID = audioFile.id
        manager.duration = TimeInterval(audioFile.audioDuration)
        startTimer()
        manager.sessionService.updateNowPlayingInfo()
    }

    func stop() {
        manager.currentEngine?.stop()
        manager.isPlaying = false
        manager.currentTime = 0
        manager.currentlyPlayingID = nil
        stopTimer()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Deactivation failed: \(error)")
        }
    }

    func togglePlayPause() {
        guard let engine = manager.currentEngine else { return }

        if engine.isPlaying {
            engine.pause()
            manager.isPlaying = false
            stopTimer()
            manager.sessionService.updateNowPlayingInfo()
        } else {
            engine.play()
            manager.isPlaying = true
            startTimer()
            manager.sessionService.updateNowPlayingInfo()
        }
    }

    func seek(to time: TimeInterval) {
        manager.isSeeking = true
        manager.currentEngine?.seek(to: time)
        manager.currentTime = time

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak manager] in
            manager?.isSeeking = false
        }
    }

    func setVolume(_ volume: Float) {
        manager.currentEngine?.setVolume(volume)
    }

    func setTempo(_ newTempo: Float) {
        manager.tempo = max(0.1, min(4.0, newTempo))
        manager.currentEngine?.setTempo(manager.tempo)
    }

    func setPitch(_ newPitch: Float) {
        manager.pitch = max(-2400, min(2400, newPitch))
        manager.currentEngine?.setPitch(manager.pitch)
    }

    func startTimer() {
        var lastSecond = -1
        manager.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let engine = self.manager.currentEngine else { return }

            if self.manager.isSeeking { return }

            let engineTime = engine.currentTime
            let currentSecond = Int(engineTime)

            self.manager.currentTime = engineTime

            if currentSecond != lastSecond {
                lastSecond = currentSecond
                self.manager.sessionService.updateNowPlayingInfo()
            }

            if self.manager.currentTime >= self.manager.duration && self.manager.duration > 0 {
                self.manager.skipNextSong()
            }
        }
    }

    func stopTimer() {
        manager.timer?.invalidate()
        manager.timer = nil
    }

    func skipPreviousSong() {
        if manager.currentTime > 3.0 {
            restartCurrentSong()
            return
        }
        stopTimer()
        guard let currentIndex = manager.playbackQueue.firstIndex(where: { $0.id == manager.currentlyPlayingID }) else {
            return
        }

        let previousIndex = currentIndex - 1
        if previousIndex >= 0 {
            manager.play(audioFile: manager.playbackQueue[previousIndex], context: manager.playbackQueue, fromSongsTab: manager.playingFromSongsTab)
        } else {
            restartCurrentSong()
        }
    }

    private func restartCurrentSong() {
        seek(to: 0)

        if !manager.isPlaying {
            manager.currentEngine?.play()
            manager.isPlaying = true
        }

        if manager.timer == nil {
            startTimer()
        }
        manager.currentTime = 0
        manager.sessionService.updateNowPlayingInfo()
    }

    func skipNextSong() {
        stopTimer()
        guard !manager.playbackQueue.isEmpty else {
            stop()
            return
        }

        if let currentIndex = manager.playbackQueue.firstIndex(where: { $0.id == manager.currentlyPlayingID }) {
            let nextIndex = currentIndex + 1
            if nextIndex < manager.playbackQueue.count {
                manager.play(audioFile: manager.playbackQueue[nextIndex], context: manager.playbackQueue, fromSongsTab: manager.playingFromSongsTab)
            } else {
                if manager.isLooping {
                    if let firstFile = manager.playbackQueue.first {
                        manager.play(audioFile: firstFile, context: manager.playbackQueue, fromSongsTab: manager.playingFromSongsTab)
                    }
                } else {
                    stop()
                }
            }
        } else {
            if let firstFile = manager.playbackQueue.first {
                manager.play(audioFile: firstFile, context: manager.playbackQueue, fromSongsTab: manager.playingFromSongsTab)
            }
        }
    }

    func reorderSelectedSongs(selectedIDs: [UUID], to destination: Int, in currentSongs: [AudioFile], playlist: Playlist? = nil) {
        let selectedIndices = currentSongs.enumerated()
            .filter { selectedIDs.contains($0.element.id) }
            .map { $0.offset }
            .sorted()

        let selectedSongs = selectedIndices.map { currentSongs[$0] }
        var songs = currentSongs

        for index in selectedIndices.reversed() {
            songs.remove(at: index)
        }

        let adjustedDestination = destination - selectedIndices.filter { $0 < destination }.count

        songs.insert(contentsOf: selectedSongs, at: adjustedDestination)

        if let playlist = playlist {
            guard let playlistIndex = manager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

            let reorderedIDs = songs.map { $0.id }
            manager.playlists[playlistIndex].audioFileIDs = reorderedIDs
            manager.playlistService.savePlaylists()

            if !manager.playingFromSongsTab {
                manager.playbackQueue = songs
            }
        } else {
            manager.displayedSongs = songs

            guard let masterID = manager.masterPlaylistID,
                  let index = manager.playlists.firstIndex(where: { $0.id == masterID }) else { return }

            let reorderedIDs = songs.map { $0.id }
            manager.playlists[index].audioFileIDs = reorderedIDs
            manager.playlistService.savePlaylists()

            if manager.playingFromSongsTab {
                manager.playbackQueue = manager.displayedSongs
            }
        }
    }
}
