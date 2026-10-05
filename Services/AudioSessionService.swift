import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import os

final class AudioSessionService {
    unowned let manager: AudioManager

    private static let log = Logger(subsystem: "group.Cam.punches-ios", category: "session")

    init(manager: AudioManager) {
        self.manager = manager
    }
    
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkID: UUID?
    private var isRemoteControlConfigured = false

    /// Indirected so it is created after `super` and stays a single instance —
    /// `MPRemoteCommandCenter.shared()` is cheap but not free.
    private var commandCenter: MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    /// Configures the session once, then registers remote control
    /// unconditionally.
    ///
    /// These used to share one `do` block with the two throwing calls, so a
    /// failed `setActive` — routine at launch, when no track is loaded — meant
    /// no command target was ever added and the lock screen, Control Center and
    /// headphone buttons were inert for the rest of the process, with nothing
    /// but a `print` to show for it. Registration must not depend on the session
    /// being activatable right now.
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // `longFormAudio` is the hint that this is music rather than a
            // podcast or a sound effect. It is what gets correct Now Playing
            // behaviour and AirPlay 2 queueing; `mode: .default` alone does not
            // declare intent.
            try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try audioSession.setActive(true)
        } catch {
            Self.log.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
        setupRemoteTransportControls()
    }

    private func setupRemoteTransportControls() {
        guard !isRemoteControlConfigured else { return }
        isRemoteControlConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // `play` and `pause` are distinct commands, not one toggle. The system
        // sends `play` to mean *begin or resume*; answering it with a toggle
        // pauses the track whenever the two sources of truth for "playing"
        // disagree — which is exactly the state an interruption leaves behind.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.manager.currentlyPlayingID != nil else { return .commandFailed }
            self.manager.resumePlayback()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.manager.currentlyPlayingID != nil else { return .commandFailed }
            self.manager.pausePlayback()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.manager.togglePlayPause()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            // Report honestly. Returning `.success` unconditionally told the
            // system a skip had happened when the queue had nowhere to go.
            return self.manager.playbackService.advance(.previousRequested) ? .success : .commandFailed
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            return self.manager.playbackService.advance(.nextRequested) ? .success : .commandFailed
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            // Scrubbing with nothing loaded used to move the reported position
            // with no audio behind it.
            guard self.manager.currentlyPlayingID != nil else { return .commandFailed }
            self.manager.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    func setupConfigurationChangeObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.manager.isPlaying else { return }

            if let engine = self.manager.currentEngine?.getAudioEngine() {
                do {
                    engine.prepare()
                    try engine.start()
                } catch {
                    print("Failed to restart engine after config change: \(error)")
                }
            }
        }
        manager.observerTokens.append(token)
    }

    func setupInterruptionObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .began {
                self.manager.isPlaying = false
                self.manager.playbackService.stopTimer()
                self.manager.currentEngine?.pause()

                // Push the pause to the system, which nothing else will do.
                //
                // Setting `isPlaying` is only the app's own copy of the state; the
                // Control Center / lock screen read
                // `MPNowPlayingInfoPropertyPlaybackRate`, and that key is only ever
                // rewritten from `updateNowPlayingInfo()`. Without this call the
                // rate stays at whatever it was — `1.0` — so an interrupted app
                // keeps showing a *playing* track with a scrubber that will never
                // move, because the timer that would have advanced it is the one
                // just invalidated.
                //
                // Deliberately updates the info rather than clearing
                // `nowPlayingInfo`. Clearing drops the entry from Control Center
                // entirely, so an interrupted track would vanish instead of showing
                // as paused.
                self.updateNowPlayingInfo()
            } else if type == .ended {
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

                // Re-activate either way. Without `.shouldResume` — the normal
                // outcome of a phone call — the old branch did nothing at all, so
                // the session was left deactivated and the player frozen: timer
                // dead, no automatic path to restart it, and the in-app controls
                // the only recovery.
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    Self.log.error("Reactivation after interruption failed: \(error.localizedDescription, privacy: .public)")
                }

                // `.shouldResume` means the system considers resuming our
                // decision rather than an instruction, hence the `isPlaying`
                // check: an interruption that arrived while already paused must
                // not start audio on its own.
                if options.contains(.shouldResume) && self.manager.isPlaying {
                    self.manager.resumePlayback()
                } else {
                    // Leave a clean, resumable paused state — keep the track so
                    // the mini-player still shows what the user was listening to,
                    // and restart the tick so the position is live rather than
                    // frozen at whatever it last was.
                    self.manager.playbackService.startTimer()
                    self.updateNowPlayingInfo()
                }
            }
        }
        manager.observerTokens.append(token)
    }

    func setupRouteChangeObserver() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

            if reason == .oldDeviceUnavailable {
                if self.manager.isPlaying {
                    self.manager.currentEngine?.pause()
                    self.manager.isPlaying = false
                    self.manager.playbackService.stopTimer()
                    self.manager.sessionService.updateNowPlayingInfo()
                }
            }
        }
        manager.observerTokens.append(token)
    }

    func setupLifecycleObservers() {
        let bgToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            if !self.manager.isPlaying {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            self.updateNowPlayingInfo()
        }
        manager.observerTokens.append(bgToken)

        let fgToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            guard self.manager.currentlyPlayingID != nil else { return }

            // The session is deactivated on background when nothing is playing,
            // and an interruption may have left it deactivated while a track was
            // still loaded. Activating here — rather than only when the user
            // next taps play — is what makes returning to the app recover
            // instead of waiting for a tap.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Self.log.error("Reactivation on foreground failed: \(error.localizedDescription, privacy: .public)")
            }

            if let engine = self.manager.currentEngine?.getAudioEngine(), !engine.isRunning {
                do {
                    engine.prepare()
                    try engine.start()
                } catch {
                    Self.log.error("Engine restart on foreground failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if self.manager.isPlaying {
                self.manager.resumePlayback()
            } else {
                self.manager.playbackService.startTimer()
                self.updateNowPlayingInfo()
            }
        }
        manager.observerTokens.append(fgToken)
    }

    func updateNowPlayingInfo() {
        guard let currentFile = manager.audioFiles.first(where: { $0.id == manager.currentlyPlayingID }) else {
            return
        }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentFile.title
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = manager.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = manager.currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = manager.isPlaying ? 1.0 : 0.0
        // The rate the track *would* play at. The system needs it to interpolate
        // the lock-screen scrubber between our per-second updates; without it the
        // position jumps a second at a time.
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Only offer the transport the current state can actually perform, so
        // the buttons grey out instead of silently doing nothing.
        let queue = manager.playbackQueue
        if let index = queue.firstIndex(where: { $0.id == manager.currentlyPlayingID }) {
            commandCenter.nextTrackCommand.isEnabled = index + 1 < queue.count || manager.isLooping
            commandCenter.previousTrackCommand.isEnabled = !queue.isEmpty
        } else {
            commandCenter.nextTrackCommand.isEnabled = !queue.isEmpty
            commandCenter.previousTrackCommand.isEnabled = false
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        if cachedArtworkID != currentFile.id {
            cachedArtworkID = currentFile.id
            if let artworkName = currentFile.artworkImageName,
               let artworkImage = manager.artworkService.loadArtworkImage(artworkName) {
                cachedArtwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
            } else {
                cachedArtwork = nil
            }
        }
        if let cachedArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Drops the entry entirely, which is what `stop()` needs.
    ///
    /// `updateNowPlayingInfo()` cannot express this: it returns early when
    /// nothing is loaded, and publishing a stale track with a rate of `0.0`
    /// leaves Control Center showing a song the app is no longer playing.
    func clearNowPlayingInfo() {
        cachedArtwork = nil
        cachedArtworkID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
}
