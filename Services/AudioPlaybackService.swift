import Foundation
import AVFoundation
import MediaPlayer
import QuartzCore
import os

/// Why the queue is being advanced.
///
/// Not cosmetic. The reason decides how the end of the queue is interpreted, and
/// having one type for it is what lets the in-app buttons, the lock screen and
/// the automatic end-of-track path all share a single implementation instead of
/// three that drift apart.
enum PlaybackAdvanceReason: Equatable {
    /// The current track played through to its end.
    case trackFinished
    /// The user pressed Next, or a remote `nextTrackCommand` arrived.
    case nextRequested
    /// The user pressed Previous, or a remote `previousTrackCommand` arrived.
    case previousRequested
}

/// Monotonic token identifying one run of scheduled buffers.
///
/// Extracted from `AppleAudioEngine` so the invalidation contract is testable
/// without an `AVAudioPlayerNode`. Every mutator of scheduling state — `load`,
/// `stop` and `seek` — calls `begin()`, which invalidates every token handed out
/// before it; a buffer completion carrying a stale token is discarded without
/// touching the scheduling counters.
struct PlaybackRun: Equatable {
    private(set) var id: UInt64 = 0

    /// Invalidates outstanding tokens and returns the new one. Called by every
    /// mutator of scheduling state — `load`, `stop`, `seek`.
    mutating func begin() -> UInt64 {
        id &+= 1
        return id
    }

    /// The current token, for scheduling more buffers into the run already in
    /// progress. Deliberately does not advance: `scheduleBuffersIfNeeded`
    /// recurses as buffers drain, and advancing here would invalidate the
    /// buffers the previous pass had just scheduled.
    var current: UInt64 { id }

    func isCurrent(_ token: UInt64) -> Bool {
        token == id
    }
}

/// What the queue should do next.
///
/// Carries a track `UUID` rather than an `AudioFile` on purpose: the planner
/// only ever decides *which* track, and `AudioFile` is not `Equatable`, so
/// holding them would make this type untestable and couple the decision to the
/// model. `advance` resolves the id back against the queue it passed in.
enum PlaybackQueueAction: Equatable {
    case playTrack(UUID)
    case restartCurrent
    case stop
}

/// The decision half of queue advance, with no engine, session or manager in
/// sight.
///
/// This is the part that is genuinely hard to get right — what "next" means at
/// either end of a queue, and what Previous means before and after the
/// three-second threshold — and it is exactly the part that was previously
/// duplicated across an engine callback, a timer comparison and three call
/// sites. Splitting it from the side effects is what makes it testable without a
/// running `AVAudioEngine`, and it is why `advance(_:)` reads as a match on a
/// returned action rather than a walk over indices.
enum PlaybackQueuePlanner {
    static func action(queue: [AudioFile],
                       currentID: UUID?,
                       reason: PlaybackAdvanceReason,
                       isLooping: Bool,
                       currentTime: TimeInterval,
                       previousRestartThreshold: TimeInterval) -> PlaybackQueueAction {
        guard !queue.isEmpty else { return .stop }

        if reason == .previousRequested {
            if currentTime > previousRestartThreshold {
                return .restartCurrent
            }

            // Nothing to step back to when the playing track is not in the
            // queue — it was deleted, or the queue was rebuilt underneath us.
            // Restarting is the least surprising answer; stopping is not.
            guard let index = queue.firstIndex(where: { $0.id == currentID }) else {
                return .restartCurrent
            }

            return index > 0 ? .playTrack(queue[index - 1].id) : .restartCurrent
        }

        guard let index = queue.firstIndex(where: { $0.id == currentID }) else {
            return .playTrack(queue[0].id)
        }

        let nextIndex = index + 1
        if nextIndex < queue.count {
            return .playTrack(queue[nextIndex].id)
        }

        // End of queue. `isLooping` is the whole of the loop feature — it means
        // repeat-the-queue, which is what the control's icon now says.
        return isLooping ? .playTrack(queue[0].id) : .stop
    }
}

final class AudioPlaybackService {
    unowned let manager: AudioManager

    private static let log = Logger(subsystem: "group.Cam.punches-ios", category: "playback")

    /// Progress tick interval. Also the granularity of the lock-screen elapsed
    /// time, so it is a compromise rather than a free choice.
    private static let tickInterval: TimeInterval = 0.2

    /// How long the progress tick stays muted after a seek. The seek is a hard
    /// stop-and-reschedule, so one tick is enough for the engine's clock to
    /// catch up with the requested position.
    private static let seekSuppressionInterval: TimeInterval = 0.25

    /// The "press Previous to restart the current track" threshold, in seconds.
    private static let previousRestartThreshold: TimeInterval = 3.0

    /// Session activation fails transiently — most often because the system is
    /// mid-transition while the device locks or an interruption is being torn
    /// down. Two deferred retries cover that window without blocking the main
    /// thread, and without leaving the player wedged the way a bare `return`
    /// did.
    private static let maxSessionRetries = 2
    private var sessionRetryCount = 0

    /// Guards against a second advance arriving while the first is still
    /// running. The generation guard in `AppleAudioEngine` stops stale
    /// *callbacks*; this stops two *live* ones.
    private var advanceInFlight = false

    /// Last second written to `MPNowPlayingInfoCenter`, so the now-playing
    /// update is per second rather than per tick. Reset by `startTimer` so the
    /// first tick after any resume always publishes.
    private var lastPublishedSecond: Int = -1

    init(manager: AudioManager) {
        self.manager = manager
    }

    // MARK: - Transport

    func play(audioFile: AudioFile, context: [AudioFile]?, fromSongsTab: Bool) {
        if let context = context {
            manager.playbackQueue = context
        } else if manager.playbackQueue.isEmpty || !manager.playbackQueue.contains(where: { $0.id == audioFile.id }) {
            manager.playbackQueue = manager.sortedAudioFiles
        }

        manager.playingFromSongsTab = fromSongsTab

        // Re-requesting the track that is already loaded is a resume, not a
        // restart. Tearing the node down here would drop the playhead on every
        // tap of the play button.
        if manager.currentlyPlayingID == audioFile.id {
            if manager.isPlaying {
                manager.sessionService.updateNowPlayingInfo()
            } else {
                resumePlayback()
            }
            return
        }

        // The category is configured once, at launch. Activating is the only
        // per-play session work, and it can legitimately fail while the system
        // is transitioning. The old code returned from here, which left the
        // progress timer stopped and the engine stopped with no track playing
        // and nothing on screen to say why — the "it just stopped when the
        // phone locked" symptom. Nothing is lost by waiting instead: the
        // current state stays intact and this retries.
        guard activateSession() else {
            scheduleSessionRetry { [weak self] in
                self?.play(audioFile: audioFile, context: context, fromSongsTab: fromSongsTab)
            }
            return
        }

        load(audioFile)

        manager.currentEngine?.play()
        manager.isPlaying = true
        startTimer()
        manager.sessionService.updateNowPlayingInfo()
    }

    /// Puts `audioFile` on the engine without starting it.
    ///
    /// Split out of `play(audioFile:context:fromSongsTab:)` because "make this
    /// the current track" and "start making noise" are separate decisions. The
    /// automatic queue advance, the in-app buttons and the deletion path all
    /// want the first without necessarily wanting the second — deleting the
    /// track you are on should hand you to its successor *at your current
    /// play/pause state*, not force a track on you.
    ///
    /// Assumes the session is already active; `play` activates it before
    /// getting here, and `seek` is the only other caller.
    private func load(_ audioFile: AudioFile) {
        guard let engine = manager.currentEngine else { return }

        manager.currentTime = 0

        engine.stop()
        engine.load(audioFile: audioFile)
        engine.onPlaybackFinished = { [weak self] in
            self?.advance(.trackFinished)
        }
        manager.attachAnalyzerSafely()
        engine.setTempo(manager.tempo)
        engine.setPitch(manager.pitch)

        manager.currentlyPlayingID = audioFile.id
        // `engine.duration` is not readable yet: `load` opens the file on the
        // engine's own queue. The first progress tick publishes it — see
        // `tick` — which also keeps one clock for both position and duration
        // instead of mixing the render clock with import-time metadata.
        manager.needsDurationSync = true
    }

    /// Moves the player onto `audioFile` in place, without changing whether
    /// anything is playing.
    ///
    /// Used when the track on the player disappears from underneath it. The
    /// engine still holds the deleted file's audio, so the only way to leave a
    /// consistent state is to load the replacement rather than to leave the
    /// identity pointing at bytes that are in the trash.
    func handover(to audioFile: AudioFile) {
        guard activateSession() else {
            scheduleSessionRetry { [weak self] in self?.handover(to: audioFile) }
            return
        }

        // Read before `load`, which is not supposed to change it but should not
        // be relied on not to.
        let wasPlaying = manager.isPlaying
        load(audioFile)

        if wasPlaying {
            manager.currentEngine?.play()
            startTimer()
        }
        manager.sessionService.updateNowPlayingInfo()
    }

    /// Begins or resumes the loaded track.
    ///
    /// Distinct from `togglePlayPause` on purpose: the system sends `play` to
    /// mean *start or resume*, never *invert*. After an interruption the two
    /// sources of truth for "playing" can disagree, and a toggle then pauses the
    /// track the user asked to hear.
    func resumePlayback() {
        guard let engine = manager.currentEngine, manager.currentlyPlayingID != nil else { return }

        if !engine.isPlaying {
            engine.play()
        }
        manager.isPlaying = true
        startTimer()
        manager.sessionService.updateNowPlayingInfo()
    }

    func pausePlayback() {
        manager.currentEngine?.pause()
        manager.isPlaying = false
        stopTimer()
        manager.sessionService.updateNowPlayingInfo()
    }

    func togglePlayPause() {
        // After the queue ends, `stop()` clears `currentlyPlayingID` but the
        // engine keeps the loaded file rewound to frame 0. A toggle would then
        // resume audio for a track nothing in the UI knows about, so start the
        // queue explicitly instead.
        guard manager.currentlyPlayingID != nil else {
            guard let first = manager.playbackQueue.first else { return }
            play(audioFile: first, context: manager.playbackQueue, fromSongsTab: manager.playingFromSongsTab)
            return
        }

        // The engine's flag is the authoritative one at this boundary — it is
        // what actually produced audio. Branching on the manager's copy is what
        // let a stale `isPlaying` pause a track the user had just asked to play.
        if manager.currentEngine?.isPlaying == true {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func stop() {
        manager.currentEngine?.stop()
        manager.isPlaying = false
        manager.currentTime = 0
        manager.duration = 0
        manager.needsDurationSync = false
        manager.currentlyPlayingID = nil
        stopTimer()
        manager.sessionService.clearNowPlayingInfo()

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.log.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func seek(to time: TimeInterval) {
        manager.seekSuppressedUntil = CACurrentMediaTime() + Self.seekSuppressionInterval
        manager.currentEngine?.seek(to: time)
        manager.currentTime = clampedPosition(time)
        manager.sessionService.updateNowPlayingInfo()
    }

    // MARK: - Queue advance

    /// Moves the queue on by one step, for any of the reasons above.
    ///
    /// One entry point on purpose. Auto-advance previously ran through two
    /// independent paths — the engine's end-of-track completion and a
    /// `currentTime >= duration` check on the progress timer — neither of which
    /// recorded that an advance was already under way, so whichever arrived
    /// second skipped the track the first had just started. The second of those
    /// is gone; what is left is here.
    ///
    /// Returns whether the queue actually moved, so remote commands can report
    /// `.commandFailed` instead of claiming success for a no-op.
    @discardableResult
    func advance(_ reason: PlaybackAdvanceReason) -> Bool {
        guard !advanceInFlight else { return false }
        advanceInFlight = true
        defer { advanceInFlight = false }

        let queue = manager.playbackQueue
        let action = PlaybackQueuePlanner.action(
            queue: queue,
            currentID: manager.currentlyPlayingID,
            reason: reason,
            isLooping: manager.isLooping,
            currentTime: manager.currentTime,
            previousRestartThreshold: Self.previousRestartThreshold
        )

        switch action {
        case .playTrack(let trackID):
            // The planner derived this id from the queue passed in, so it is
            // present. Resolving defensively rather than force-unwrapping: a
            // mismatch here would otherwise be a crash on a routine track
            // change.
            guard let audioFile = queue.first(where: { $0.id == trackID }) else {
                Self.log.error("Planner returned a track not in the queue: \(trackID.uuidString, privacy: .public)")
                stop()
                return false
            }
            play(audioFile, context: queue)
            return true
        case .restartCurrent:
            restartCurrentSong()
            return true
        case .stop:
            stop()
            return false
        }
    }

    private func play(_ audioFile: AudioFile, context: [AudioFile]) {
        play(audioFile: audioFile, context: context, fromSongsTab: manager.playingFromSongsTab)
    }

    func skipNextSong() {
        advance(.nextRequested)
    }

    func skipPreviousSong() {
        advance(.previousRequested)
    }

    /// Rewinds to the start of the loaded track without reloading it.
    ///
    /// A full `play` would reopen the file and drop the analyser attachment, and
    /// the audible gap makes it a poor answer to "I pressed Previous too
    /// early".
    private func restartCurrentSong() {
        manager.currentEngine?.seek(to: 0)
        manager.currentTime = 0
        manager.seekSuppressedUntil = CACurrentMediaTime() + Self.seekSuppressionInterval

        // Keeps the progress tick live so the position tracks the rewind while
        // the track plays. Restarting deliberately does not *start* playback —
        // pressing Previous on a paused track should leave it paused.
        if manager.isPlaying {
            startTimer()
        }

        manager.sessionService.updateNowPlayingInfo()
    }

    // MARK: - Progress tick

    /// Starts the progress tick.
    ///
    /// A `DispatchSourceTimer` rather than `Timer.scheduledTimer`. A run-loop
    /// `Timer` is added in `.default` mode, so it is suppressed for the whole
    /// duration of a scroll or a scrubber drag, and throttled once the app is
    /// backgrounded — which is exactly when `currentTime` and the lock-screen
    /// elapsed time most need to stay live. It was also the mechanism that
    /// decided when a track ended, so its gaps were gaps in auto-advance. A
    /// dispatch source is independent of run-loop mode and keeps the same
    /// cadence in all three states.
    func startTimer() {
        stopTimer()
        lastPublishedSecond = -1

        let source = DispatchSource.makeTimerSource(queue: .main)
        // `leeway` lets the system coalesce ticks when the main thread is busy,
        // which is the difference between a dropped UI frame and a dropped tick.
        source.schedule(deadline: .now() + Self.tickInterval,
                        repeating: Self.tickInterval,
                        leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            self?.tick()
        }

        manager.timer = source
        source.resume()
    }

    func stopTimer() {
        manager.timer?.cancel()
        manager.timer = nil
    }

    /// One progress tick. Publishes position only — it does not decide that a
    /// track has ended.
    private func tick() {
        guard let engine = manager.currentEngine else { return }

        // Muted for a short window after a seek so the tick does not fight the
        // engine's clock. Compared as a deadline rather than cleared by a
        // deferred block: a `Bool` cleared from `asyncAfter` could stay `true`
        // forever if the app was suspended in that window, and every later tick
        // would then return early — muting progress and the lock-screen
        // position for the rest of the session with no way to recover.
        guard CACurrentMediaTime() >= manager.seekSuppressedUntil else { return }

        // Single duration clock. `engine.duration` is derived from the frames
        // actually scheduled, which is the same clock `engine.currentTime` is
        // measured against. `AudioFile.audioDuration` is import-time metadata:
        // it is 0 for anything imported before metadata existed, and a drift
        // between the two cut tracks short. Reading it back here means the
        // slider has a valid range from the first tick onward.
        if manager.needsDurationSync {
            let engineDuration = engine.duration
            if engineDuration > 0 {
                manager.duration = engineDuration
                manager.needsDurationSync = false
            }
        }

        let position = clampedPosition(engine.currentTime)
        manager.currentTime = position

        let second = Int(position)
        if second != lastPublishedSecond {
            lastPublishedSecond = second
            manager.sessionService.updateNowPlayingInfo()
        }
    }

    /// Keeps the reported position inside `[0, duration]`.
    ///
    /// The slider's range is built from `manager.duration`, so an unclamped
    /// position during the window before the duration is first published would
    /// produce `0...max(bad, 0.01)`.
    private func clampedPosition(_ time: TimeInterval) -> TimeInterval {
        let lower = max(0, time)
        return manager.duration > 0 ? min(lower, manager.duration) : lower
    }

    // MARK: - Session

    /// Activates the session, having configured it once at launch.
    @discardableResult
    private func activateSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionRetryCount = 0
            return true
        } catch {
            // `Logger`, not `print`: this is the failure the user experiences as
            // "the music just stopped", and `print` is not in a release build's
            // device log without a sysdiagnose capture.
            Self.log.error("Could not activate audio session: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Retries a failed activation, a bounded number of times.
    private func scheduleSessionRetry(_ work: @escaping () -> Void) {
        guard sessionRetryCount < Self.maxSessionRetries else {
            Self.log.error("Giving up on audio session activation after \(self.sessionRetryCount, privacy: .public) retries")
            return
        }

        sessionRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            work()
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