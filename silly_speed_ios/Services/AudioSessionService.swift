import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI

final class AudioSessionService {
    unowned let manager: AudioManager

    init(manager: AudioManager) {
        self.manager = manager
    }

    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            setupRemoteTransportControls()
        } catch {
            print("failed to set up audio \(error.localizedDescription)")
        }
    }

    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.manager.audioFiles.first(where: { $0.id == self.manager.currentlyPlayingID }) != nil {
                self.manager.togglePlayPause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.manager.skipPreviousSong()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.manager.skipNextSong()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.manager.togglePlayPause()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
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
                self.manager.timer?.invalidate()
                self.manager.timer = nil
                self.manager.currentEngine?.pause()
            } else if type == .ended {
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        do {
                            try AVAudioSession.sharedInstance().setActive(true)
                            self.manager.currentEngine?.play()
                            self.manager.isPlaying = true
                            self.manager.playbackService.startTimer()
                        } catch {
                            print("Resume error: \(error)")
                        }
                    }
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
                DispatchQueue.main.async {
                    self.manager.togglePlayPause()
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

            if self.manager.currentlyPlayingID != nil {
                try? AVAudioSession.sharedInstance().setActive(true)
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

        if let artworkName = currentFile.artworkImageName,
           let artworkImage = manager.artworkService.loadArtworkImage(artworkName) {
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in
                artworkImage
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
