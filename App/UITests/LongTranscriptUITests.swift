import XCTest

/// #197: a long Chat's older Messages are built lazily. With real touches: it opens at the end, a
/// drag leaves the transcript where the finger put it, a step opened in an older Response is
/// still open after its row was dropped and rebuilt, and jump-to-bottom returns to the end. Runs
/// against `scripts/stub-server` (`long@example.com` has the 58-Message synthetic Chat). Opt-in:
/// `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`.
@MainActor
final class LongTranscriptUITests: XCTestCase {
    private var app: XCUIApplication!
    private let chatID = "00000000-0000-4000-8000-00000000c197"

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testScrollingALongChat() throws {
        guard let url = ProcessInfo.processInfo.environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("Needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url)
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(chatID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "drawer shows \(app.buttons.allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty })")
        row.tap()

        // Opens at the end: the footer under the latest Response is on screen.
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let footer = app.descendants(matching: .any)["conversation.disclaimer"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.frame.contains(CGPoint(x: footer.frame.midX, y: footer.frame.midY)), "opened at the end: footer \(footer.frame) transcript \(transcript.frame)")

        // A drag up stays where the finger left it.
        drag(down: true)
        let response = app.descendants(matching: .any).matching(identifier: "message.response").allElementsBoundByIndex
            .first { transcript.frame.intersects($0.frame) }
        let placed = try XCTUnwrap(response).frame
        sleep(1)
        XCTAssertEqual(try XCTUnwrap(response).frame.minY, placed.minY, accuracy: 1, "the transcript stays where it was dragged")
        XCTAssertTrue(app.buttons["conversation.scrollToBottom"].waitForExistence(timeout: 3))

        // Into the older Messages, open a Thinking step there.
        var opened: XCUIElement?
        for _ in 0..<40 where opened == nil {
            drag(down: true)
            opened = app.buttons.matching(identifier: "response.thinking").allElementsBoundByIndex
                .first { $0.isHittable && transcript.frame.insetBy(dx: 0, dy: 120).contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        let thinking = try XCTUnwrap(opened, "a Thinking step in an older Response")
        let openedLabel = thinking.label
        thinking.tap()
        sleep(1)
        XCTAssertTrue(openThinking.exists, "the step opened")

        // Far away (its row is dropped) and back (rebuilt): still open.
        for _ in 0..<30 { drag(down: true) }
        var back: Int?
        for index in 1...40 {
            drag(down: false)
            if openThinking.exists, transcript.frame.intersects(openThinking.frame) { back = index; break }
        }
        XCTAssertNotNil(back, "the step is still open after its row was rebuilt (opened \(openedLabel))")

        // Jump to bottom: the end again.
        app.buttons["conversation.scrollToBottom"].tap()
        sleep(2)
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.frame.contains(CGPoint(x: footer.frame.midX, y: footer.frame.midY)), "back at the end")
    }

    // MARK: Helpers

    /// A Thinking step that's open.
    private var openThinking: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'response.thinking' AND value == 'Expanded'")).firstMatch
    }

    /// Moves the content by 40% of the screen without momentum: `down` shows older Messages.
    /// (Clear of the header and the composer, which take their own touches.)
    private func drag(down: Bool) {
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        let top = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        (down ? top : bottom).press(forDuration: 0.05, thenDragTo: down ? bottom : top, withVelocity: .default, thenHoldForDuration: 0.2)
    }

    private func signIn(url: String) {
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
        email.typeText("long@example.com")
        let password = app.secureTextFields["signin.password"]
        if !password.exists { email.typeText("\n") }
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("theseus")
        app.buttons["signin.submit"].tap()
    }
}
