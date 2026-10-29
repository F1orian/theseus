import XCTest

/// Screenshot steps for the validation pass: features no other walkthrough photographs. Opt-in:
/// the stub tours need `scripts/stub-server` (`TEST_RUNNER_THESEUS_STUB_URL`), the live tour needs
/// THESEUS_INTEGRATION=1 and a filled-in .env. Screenshots are attached to the result bundle;
/// `xcrun xcresulttool export attachments` collects them.
@MainActor
final class ValidationTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Stub Server tours

    /// INCOG-02: an Account whose permissions enforce temporary chats only gets Incognito Chats.
    func testStubIncognitoPolicyTour() throws {
        let url = try stubURL()
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url, email: "incognito@example.com", password: "theseus")
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))
        sleep(2)
        snapshot("incog-02-enforced-home")
        app.openSidebar()
        sleep(1)
        snapshot("incog-02-enforced-drawer")
    }

    /// HOME-04: a Server banner above the composer; CHAT-13: the stub has no streaming socket and
    /// no completions endpoint, so the connectivity banner and an inline error show.
    func testStubNoticeAndErrorTour() throws {
        let url = try stubURL()
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url, email: "notice@example.com", password: "theseus")
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        sleep(3)
        snapshot("home-04-server-banner")
        let connection = app.descendants(matching: .any)["chat.connectionBanner"]
        if connection.waitForExistence(timeout: 30) {
            snapshot("chat-13-connection-banner")
        }
        let input = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        input.tap()
        input.typeText("Hello stub")
        sleep(1)
        snapshot("chat-13-send-paused")
        if app.buttons["composer.send"].isEnabled {
            app.buttons["composer.send"].tap()
            sleep(5)
            snapshot("chat-13-sending")
            // The stub has no completions endpoint: the Response should end in an inline error with Retry.
            let failed = app.descendants(matching: .any)["response.error"]
            if failed.waitForExistence(timeout: 90) {
                sleep(1)
                snapshot("chat-13-send-error")
            } else {
                snapshot("chat-13-no-error-after-90s")
            }
        }
    }

    // MARK: Live tour

    /// #141 follow-up suggestions (switched on for the run, off again afterwards), plus the
    /// Conversation chrome around a finished Response (CHAT-10) and its generated title (CHAT-11).
    func testLiveFollowUpsAndChrome() throws {
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live tour needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        app.launchSkippingWelcome()
        signIn(url: url, email: email, password: password)
        let composer = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30))

        setFollowUps(true)
        defer { setFollowUps(false) }

        app.chooseComposerModel("claude-haiku-5-5")
        send("[theseus-test] Name three famous lighthouses, one line each.")
        waitUntilIdle()
        let followUps = app.descendants(matching: .any)["followUps"]
        if followUps.waitForExistence(timeout: 45) { sleep(1) }
        snapshot("chat-141-follow-ups")
        sleep(4)
        snapshot("chat-11-title")
        app.swipeDown()
        sleep(1)
        snapshot("chat-10-scroll-down")

        // Clean up: only this tour's Chat.
        app.buttons["chat.menu"].firstMatch.tap()
        app.buttons["chat.menu.delete"].tap()
        let confirm = app.buttons["chat.menu.deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    private func stubURL() throws -> String {
        guard let url = environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("The stub tours need scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        return url
    }

    private func setFollowUps(_ on: Bool) {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
        let row = app.buttons["settings.row.capabilities"]
        app.revealInSettings(row)
        row.tap()
        let toggle = app.switches["capabilities.followUps"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if ((toggle.value as? String) == "1") != on {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
            sleep(2)
        }
        if on { snapshot("chat-141-capabilities-switch") }
        app.tapBack()
        let close = app.buttons["settings.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        sleep(1)
    }

    private func signIn(url: String, email: String, password: String) {
        let address = app.textFields["server.address"]
        let newChat = app.descendants(matching: .any)["composer.field"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !address.exists, !newChat.exists, !app.textFields["signin.email"].exists {
            usleep(200_000)
        }
        if address.exists {
            address.tap()
            address.typeText(url)
            app.buttons["server.continue"].tap()
        }
        let emailField = app.textFields["signin.email"]
        if emailField.waitForExistence(timeout: newChat.exists ? 1 : 15) {
            emailField.tap()
            if (emailField.value as? String)?.isEmpty ?? true || emailField.value as? String == "Email" {
                emailField.typeText(email)
            }
            let passwordField = app.secureTextFields["signin.password"]
            if !passwordField.exists { emailField.typeText("\n") }  // email-first flow (AUTH-02)
            XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
            passwordField.tap()
            passwordField.typeText(password)
            app.buttons["signin.submit"].tap()
        }
    }

    private func send(_ prompt: String) {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 10) || app.buttons["composer.send"].exists)
    }

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
        sleep(1)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
