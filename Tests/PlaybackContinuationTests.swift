import XCTest

@testable import Punches3

/// Tests for the queue-advance decision and the buffer-generation guard.
///
/// Both are pure, which is the point: every defect these cover was a race or a
/// duplicated decision, and neither can be observed reliably by running the app.
/// The side effects `advance(_:)` performs — opening files, touching the audio
/// session — are exactly the parts that were *not* where the bugs were.
///
/// Run with `xcodebuild test -scheme Punches3 -destination 'platform=iOS
/// Simulator,name=iPhone 16'`.
final class PlaybackContinuationTests: XCTestCase {

    // MARK: - Fixtures

    private func makeQueue(_ count: Int) -> [AudioFile] {
        (0..<count).map { index in
            // The three-argument import-path initialiser. These tests only ever
            // compare `id`, so the derived title is irrelevant.
            AudioFile(fileName: "track\(index).mp3", audioDuration: 180)
        }
    }

    private let threshold: TimeInterval = 3.0

    private func plan(queue: [AudioFile],
                      currentID: UUID?,
                      reason: PlaybackAdvanceReason,
                      isLooping: Bool = false,
                      currentTime: TimeInterval = 0) -> PlaybackQueueAction {
        PlaybackQueuePlanner.action(
            queue: queue,
            currentID: currentID,
            reason: reason,
            isLooping: isLooping,
            currentTime: currentTime,
            previousRestartThreshold: threshold
        )
    }

    // MARK: - Forward advance

    func testNextFromMiddleOfQueueAdvancesOneStep() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[0].id, reason: .nextRequested),
            .playTrack(queue[1].id)
        )
    }

    /// The end-of-track path must behave identically to the button. These used to
    /// be two independent code paths — one in the engine's completion handler,
    /// one in a `currentTime >= duration` check on the progress timer — which is
    /// how the queue advanced twice at the end of a track.
    func testTrackFinishedAdvancesTheSameStepAsNextRequested() {
        let queue = makeQueue(3)

        for currentID in [queue[0].id, queue[1].id] {
            let finished = plan(queue: queue, currentID: currentID, reason: .trackFinished)
            let pressed = plan(queue: queue, currentID: currentID, reason: .nextRequested)
            XCTAssertEqual(finished, pressed, "end-of-track and Next diverged at \(currentID)")
        }
    }

    func testEndOfQueueStopsWhenNotLooping() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[2].id, reason: .trackFinished),
            .stop
        )
    }

    func testEndOfQueueWrapsToFirstTrackWhenLooping() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[2].id, reason: .trackFinished, isLooping: true),
            .playTrack(queue[0].id)
        )
    }

    /// A one-item queue with repeat on must spin that item, not stop — the
    /// behaviour the original single-flag implementation had and it must keep.
    func testSingleItemQueueLoopsOntoItself() {
        let queue = makeQueue(1)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[0].id, reason: .trackFinished, isLooping: true),
            .playTrack(queue[0].id)
        )
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[0].id, reason: .trackFinished, isLooping: false),
            .stop
        )
    }

    func testEmptyQueueStops() {
        XCTAssertEqual(plan(queue: [], currentID: nil, reason: .trackFinished), .stop)
        XCTAssertEqual(plan(queue: [], currentID: UUID(), reason: .nextRequested), .stop)
        XCTAssertEqual(plan(queue: [], currentID: UUID(), reason: .previousRequested, isLooping: true), .stop)
    }

    /// The playing track can vanish from the queue — deleted, or the queue
    /// rebuilt underneath playback. Starting at the top is the defined answer,
    /// and silently stopping was the old one.
    func testCurrentTrackMissingFromQueueStartsAtTheTop() {
        let queue = makeQueue(3)
        let stranger = UUID()
        XCTAssertEqual(
            plan(queue: queue, currentID: stranger, reason: .trackFinished),
            .playTrack(queue[0].id)
        )
    }

    func testNothingPlayingAdvancesToTheFirstTrack() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: nil, reason: .nextRequested),
            .playTrack(queue[0].id)
        )
    }

    // MARK: - Backward advance

    /// The three-second rule is the most user-visible rule in playback, and it
    /// has to hold for the button and the remote command alike.
    func testPreviousWithinThreeSecondsStepsBack() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[2].id, reason: .previousRequested, currentTime: 2.9),
            .playTrack(queue[1].id)
        )
    }

    func testPreviousAfterThreeSecondsRestartsTheCurrentTrack() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[2].id, reason: .previousRequested, currentTime: 3.1),
            .restartCurrent
        )
    }

    /// The threshold is exclusive: exactly 3.0 s has not yet passed it. Pins the
    /// boundary so a future `>=` cannot silently change when the rule flips.
    func testPreviousAtExactlyThreeSecondsStepsBack() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[2].id, reason: .previousRequested, currentTime: 3.0),
            .playTrack(queue[1].id)
        )
    }

    func testPreviousOnFirstTrackRestartsIt() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[0].id, reason: .previousRequested, currentTime: 0),
            .restartCurrent
        )
    }

    /// Regression: `skipPreviousSong` used to invalidate the progress timer and
    /// then return early when the playing track was not in the queue, leaving the
    /// track playing with a permanently frozen position.
    func testPreviousWithCurrentTrackMissingRestartsRatherThanDoingNothing() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: UUID(), reason: .previousRequested, currentTime: 0),
            .restartCurrent
        )
    }

    func testPreviousWithNothingPlayingRestarts() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: nil, reason: .previousRequested, currentTime: 0),
            .restartCurrent
        )
    }

    /// Loop is a whole-queue concept and must not make Previous wrap backwards
    /// off the front of the queue.
    func testLoopingDoesNotChangePreviousBehaviour() {
        let queue = makeQueue(3)
        XCTAssertEqual(
            plan(queue: queue, currentID: queue[0].id, reason: .previousRequested, isLooping: true, currentTime: 0),
            .restartCurrent
        )
    }

    // MARK: - Buffer generation guard

    /// Every buffer carries the token of the run that scheduled it, and
    /// `begin()` invalidates everything handed out before it. A buffer flushed
    /// by `stop()` or `seek()` still gets its handler called; dropping it here is
    /// what stops it decrementing the *next* run's scheduling counter.
    func testBeginInvalidatesOutstandingTokens() {
        var run = PlaybackRun()

        let first = run.begin()
        XCTAssertTrue(run.isCurrent(first))

        let second = run.begin()
        XCTAssertFalse(run.isCurrent(first), "a flushed buffer's token must not stay current")
        XCTAssertTrue(run.isCurrent(second))
    }

    /// Reading the current token must not advance it. `scheduleBuffersIfNeeded`
    /// recurses as buffers drain, so advancing here would invalidate the buffers
    /// the previous pass had just scheduled — silence after the first few.
    func testReadingCurrentTokenDoesNotAdvanceTheRun() {
        var run = PlaybackRun()
        let token = run.begin()

        XCTAssertEqual(run.current, token)
        XCTAssertEqual(run.current, token)
        XCTAssertTrue(run.isCurrent(token), "reading the token invalidated it")
    }

    func testStaleTokensStayRejectedAcrossManyRuns() {
        var run = PlaybackRun()

        var tokens: [UInt64] = []
        for _ in 0..<50 { tokens.append(run.begin()) }

        let current = run.current
        for token in tokens.dropLast() {
            XCTAssertFalse(run.isCurrent(token))
        }
        XCTAssertTrue(run.isCurrent(current))
    }

    // MARK: - Deliberately not covered here

    // Seek suppression self-healing is *by construction* rather than by test: the
    // tick compares `CACurrentMediaTime()` against a deadline, so there is no
    // deferred block whose suspension could leave the tick muted. A test would
    // only be able to re-assert that an elapsed deadline has passed, which cannot
    // fail and would prove nothing.
    //
    // The same applies to `DispatchSourceTimer` cadence and to
    // `AppleAudioEngine`'s `isUserStopped` flag: both need a live audio device.
}