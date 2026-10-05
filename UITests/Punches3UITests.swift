import XCTest

/// Launch smoke tests.
///
/// ## Why there is exactly one of these
///
/// `Punches3UITests` existed as a target with **no source files at all**, so
/// `xcodebuild test` reported *"Punches3UITests couldn't be loaded"* on every
/// run and it had to be excluded with `-skip-testing:Punches3UITests`. An empty
/// test bundle is not a neutral no-op: it makes the whole suite fail for a
/// reason unrelated to whatever you were testing. That is recorded as
/// [A2](docs/14-known-issues.md#a2-both-test-targets-are-empty).
///
/// This file exists to make the target real, not to pretend the app has UI
/// coverage it does not have. Everything worth asserting about playback —
/// queue advance, the loop wrap, the previous-track threshold, the generation
/// guard — lives in `Tests/PlaybackContinuationTests.swift`, where it can run in
/// milliseconds without a Simulator.
///
/// ## What a launch smoke test is genuinely worth here
///
/// More than usual. `AppleAudioEngine.init()` used to `abort()` the process when
/// the audio hardware did not answer, three different ways, from inside
/// `AudioManager.init()`. That is not a crash a unit test can see as a failure —
/// it kills the *host*, and the report is *"the test runner crashed before
/// establishing connection"* attributed to every case at once. Those three
/// defects were found by making this bundle launch. Reverting any of the three
/// would break this file, so it is a regression guard on the launch path, not a
/// formality.
final class Punches3UITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app must survive its own launch.
    ///
    /// `wait(for: .runningForeground)` is the assertion. Everything after it is
    /// about the launch having *completed* rather than having crashed and been
    /// relaunched into the same state.
    func testAppLaunchesToForeground() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(
            app.state,
            .runningForeground,
            "The app did not reach the foreground. If this is the first failure "
                + "after a change to `AudioManager.init`, `AppleAudioEngine`, or "
                + "`AudioSessionService`, read the crash log in "
                + "~/Library/Logs/DiagnosticReports — an abort in AudioToolbox "
                + "during init is not reported as a test failure."
        )
    }

    /// The library's root view is on screen.
    ///
    /// This is the weakest assertion that still fails when the UI is not built:
    /// `XCUIApplication().windows.firstMatch` exists as soon as a window does,
    /// whatever is in it. `punches.root` is applied to the library's outermost
    /// container in `content_view.swift`, so its absence means the view tree did
    /// not get that far.
    func testLibraryRootIsOnScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let root = app.descendants(matching: .any)["punches.root"]
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "`punches.root` never appeared. The app launched but did not build "
                + "its library view — check for an early `return` or a thrown "
                + "error in `ContentView.init` / the launch `.task`."
        )
    }
}
