import XCTest

/// #183: while a long Response streams, a finger on the transcript stops it from following, and
/// the content stays where it is; the jump-to-bottom button follows again. Runs against
/// `scripts/stub-server` (`stream@example.com` streams about 35 s of markdown over SSE). Opt-in:
/// `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`; with `THESEUS_SCREENSHOT_DIR` set, the
/// frames are also written there.
@MainActor
final class StreamingFollowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTouchStopsFollowingAndJumpToBottomResumes() throws {
        guard let url = ProcessInfo.processInfo.environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("Needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url)
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("[theseus-test] Walk me through the labyrinth, corridor by corridor.")
        app.buttons["composer.send"].tap()

        let response = app.descendants(matching: .any).matching(identifier: "message.response").firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 20))
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        // Let the Response grow past the screen while the transcript follows it.
        let followDeadline = Date().addingTimeInterval(30)
        while Date() < followDeadline, response.frame.height < transcript.frame.height * 1.5 { sleep(1) }
        XCTAssertTrue(app.buttons["composer.stop"].exists, "still streaming")
        snapshot("01-following")
        let followedTop = response.frame.minY
        sleep(2)
        XCTAssertLessThan(response.frame.minY, followedTop - 20, "the transcript follows the stream")

        // Touch and hold mid-stream: following stops at once and the content stays put.
        let before = response.frame.minY
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 3)
        let released = response.frame.minY
        snapshot("02-held")
        // `before` is read a moment ahead of the touch, while the transcript still follows (one
        // chunk's glide at most); following for the 3 s of the hold would move it hundreds of points.
        XCTAssertEqual(released, before, accuracy: 60, "held still under the finger while text arrived")
        sleep(3)
        XCTAssertTrue(app.buttons["composer.stop"].exists, "text was still arriving")
        snapshot("03-released-still")
        XCTAssertEqual(response.frame.minY, released, accuracy: 1, "stream growth alone doesn't follow again")

        // A small drag near the end doesn't resume either; the jump-to-bottom button does.
        let jump = app.buttons["conversation.scrollToBottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "the jump-to-bottom button shows while not following")
        jump.tap()
        sleep(1)
        let resumedTop = response.frame.minY
        sleep(2)
        if app.buttons["composer.stop"].exists {
            XCTAssertLessThan(response.frame.minY, resumedTop - 20, "following again after the button")
        }
        snapshot("04-following-again")

        // Reading mid-Response when the stream ends: the finished text doesn't move the view.
        for _ in 0..<2 {
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.2)
        }
        sleep(1)
        snapshot("05-reading-mid-response")
        // The user Message above the Response marks where the transcript is scrolled to.
        let user = app.descendants(matching: .any).matching(identifier: "message.user").firstMatch
        let reading = user.frame.minY
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(60)
        while stop.exists, Date() < deadline { usleep(300_000) }
        sleep(2)
        snapshot("06-finished-while-reading")
        XCTAssertEqual(user.frame.minY, reading, accuracy: 2, "the end of the stream doesn't scroll the view")
    }

    // MARK: Helpers

    private var composerField: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    /// #188: Messages fade out behind and below the composer like under the header; at the end
    /// the last line sits clear of the fade. Screenshots only (run in light and dark;
    /// `THESEUS_STUB_USER=incognito` for the night Incognito chat).
    func testComposerFade() throws {
        guard let url = ProcessInfo.processInfo.environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("Needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        let user = ProcessInfo.processInfo.environment["THESEUS_STUB_USER"] ?? "stream"
        let prefix = ProcessInfo.processInfo.environment["THESEUS_SHOT_PREFIX"] ?? "fade"
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url, email: "\(user)@example.com")
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("[theseus-test] Walk me through the labyrinth, corridor by corridor.")
        app.buttons["composer.send"].tap()
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 20))
        sleep(12)
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)),
                   withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.3)
        sleep(1)
        snapshot("\(prefix)-mid-scroll")
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(60)
        while stop.exists, Date() < deadline { usleep(300_000) }
        let jump = app.buttons["conversation.scrollToBottom"]
        if jump.waitForExistence(timeout: 3) { jump.tap() }
        sleep(2)
        snapshot("\(prefix)-at-end")
        XCTAssertTrue(app.buttons.matching(identifier: "message.copy").firstMatch.isHittable, "the last action row stays tappable")
    }

    private func signIn(url: String, email emailAddress: String = "stream@example.com") {
        let address = app.textFields["server.address"]
        let home = app.descendants(matching: .any)["composer.field"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !address.exists, !home.exists, !app.textFields["signin.email"].exists {
            usleep(200_000)
        }
        if address.exists {
            address.tap()
            address.typeText(url)
            app.buttons["server.continue"].tap()
        }
        let email = app.textFields["signin.email"]
        guard email.waitForExistence(timeout: home.exists ? 1 : 15) else { return }
        email.tap()
        email.typeText(emailAddress)
        let password = app.secureTextFields["signin.password"]
        if !password.exists { email.typeText("\n") }
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("theseus")
        app.buttons["signin.submit"].tap()
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["THESEUS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
