import XCTest

/// End-to-end sample ride over the bundled demo data: `-demoRide` drops
/// straight into an active ride with mocked location and music, and
/// `-demoTimeScale` compresses the simulated ride time so the full flow —
/// controls, Now Playing sheet, arrival, summary, save, history — runs in
/// well under a minute of wall time.
final class SampleRideUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoRideControlsArrivalAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoRide", "-demoTimeScale", "30"]
        app.launch()

        // The ride screen is live: controls and the mocked music bar.
        let endButton = app.buttons["ride.end"]
        XCTAssertTrue(endButton.waitForExistence(timeout: 15), "Ride screen did not appear")

        // Pause freezes progress; Resume restarts it. Ride controls carry
        // `ride.control.*` identifiers — the music bar has its own "Pause".
        app.buttons["ride.control.pause"].tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5), "Paused chip missing")
        app.buttons["ride.control.resume"].tap()
        XCTAssertTrue(app.buttons["ride.control.pause"].waitForExistence(timeout: 5), "Resume did not restore Pause")

        // Turn-by-turn banner shows the next maneuver.
        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Turn right onto Market St"))
            .firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "Maneuver banner missing")

        // Expand the music compact bar into the Now Playing sheet.
        let expandMusic = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Now playing:")
        ).firstMatch
        XCTAssertTrue(expandMusic.waitForExistence(timeout: 5), "Music compact bar missing")
        expandMusic.tap()
        XCTAssertTrue(app.buttons["Next track"].waitForExistence(timeout: 5), "Now Playing sheet did not open")

        // Skip a track from the sheet, then dismiss it by dragging the
        // sheet's fixed header (above the scrolling tab content) downward.
        // A blind swipeDown can land in the lyrics/queue scroll view, and
        // the top margin hosts the Dynamic-Island turn banner at speed, so
        // both are unreliable dismissal targets.
        app.buttons["Next track"].tap()
        let sheetHeader = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        let belowSheet = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        sheetHeader.press(forDuration: 0.1, thenDragTo: belowSheet)
        if !expandMusic.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.01)).tap()
        }
        if !expandMusic.waitForExistence(timeout: 3) {
            app.swipeDown()
        }
        XCTAssertTrue(expandMusic.waitForExistence(timeout: 5), "Now Playing sheet did not dismiss")

        // Ride to arrival under compressed time (~17 min at 30x ≈ 35 s).
        XCTAssertTrue(
            app.staticTexts["You've arrived"].waitForExistence(timeout: 180),
            "Ride never reached arrival"
        )

        // End the ride → confirm → summary → save. Re-resolve the button:
        // the reference captured at ride start can go stale across the
        // arrival state change.
        let endNow = app.buttons["ride.end"].firstMatch
        XCTAssertTrue(endNow.waitForExistence(timeout: 10), "End button missing after arrival")
        endNow.tap()
        let confirmEnd = app.buttons["End ride"].firstMatch
        XCTAssertTrue(confirmEnd.waitForExistence(timeout: 5), "End confirmation dialog did not appear")
        confirmEnd.tap()
        XCTAssertTrue(app.buttons["Save ride"].waitForExistence(timeout: 10), "Ride summary did not appear")
        app.buttons["Save ride"].tap()

        // The saved ride is listed in history.
        let ridesTab = app.tabBars.buttons["Rides"]
        XCTAssertTrue(ridesTab.waitForExistence(timeout: 10), "Main tabs did not return after save")
        ridesTab.tap()
        XCTAssertTrue(
            app.staticTexts["Balanced"].firstMatch.waitForExistence(timeout: 10),
            "Saved ride missing from history"
        )
    }
}

/// Cheap focused check for the camera orientation control: flips
/// heading-up ↔ north-up right after launch, without riding anywhere.
final class OrientationToggleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOrientationToggleFlipsBothWays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoRide", "-demoTimeScale", "10"]
        app.launch()
        XCTAssertTrue(
            app.buttons["ride.orientation"].waitForExistence(timeout: 15),
            "Ride screen did not appear"
        )
        // Give the ride screen's first layout a beat, then flip and back.
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["ride.orientation"].tap()
        let toNorthUp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Switch to direction-of-travel map"),
            object: app.buttons["ride.orientation"].firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [toNorthUp], timeout: 5), .completed,
            "Orientation toggle did not flip to north-up"
        )
        app.buttons["ride.orientation"].tap()
        let backToHeading = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Switch to north-up map"),
            object: app.buttons["ride.orientation"].firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [backToHeading], timeout: 5), .completed,
            "Orientation toggle did not flip back to heading-up"
        )
    }

    /// Control experiment: the sibling map-overview button sits in the same
    /// trailing stack — if IT works while the orientation button doesn't,
    /// the bug is in the orientation button itself; if neither works, the
    /// whole trailing stack is losing the hit test.
    @MainActor
    func testTrailingStackControlExperiment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demoRide", "-demoTimeScale", "10"]
        app.launch()
        let mapToggle = app.buttons["Show whole route"]
        XCTAssertTrue(mapToggle.waitForExistence(timeout: 15), "Ride screen did not appear")
        Thread.sleep(forTimeInterval: 1.5)
        mapToggle.tap()
        XCTAssertTrue(
            app.buttons["Resume Navigation"].waitForExistence(timeout: 5),
            "Overview sheet did not open — trailing stack is not receiving taps"
        )
    }
}
