import XCTest

/// #179: Settings › Appearance › Accent colour against the test Server. Sends one short
/// `[theseus-test]` Chat, then for Verdigris, Ultramarine and Oxblood: picks the accent in
/// Settings (the sheet stays open and in place), closes Settings (the same Chat is still showing,
/// recoloured) and keeps the Chat, the drawer and the new-chat home. Ends on Verdigris and deletes
/// the Chat. Run it once per appearance (`xcrun simctl ui <udid> appearance light|dark`).
///
/// Opt-in twice over: it needs the live-Server credentials and `THESEUS_ACCENT_SCREENS=1` (pass it
/// as `TEST_RUNNER_THESEUS_ACCENT_SCREENS=1`), so `scripts/test.sh` skips it. Screenshots are
/// result-bundle attachments, and PNGs in `THESEUS_SCREENSHOT_DIR` when set.
@MainActor
final class AccentUITests: XCTestCase {
    private var app: XCUIApplication!
    private let choices = ["verdigris", "ultramarine", "oxblood"]

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testChoosingTheAccent() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_ACCENT_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_ACCENT_SCREENS=1 for the accent walkthrough") }
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The accent walkthrough needs a filled-in .env") }

        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(url: url, email: email, password: password)

        // A Chat with a Response: the user bubble is accentSoft, links and citations the accent.
        app.chooseComposerModel("claude-haiku-5-5")
        let field = composerField
        field.tap()
        field.typeText("[theseus-test] Accent check: in two short sentences, what is verdigris?")
        app.buttons["composer.send"].tap()
        waitUntilIdle()
        let chatMenu = app.buttons["chat.menu"].firstMatch
        XCTAssertTrue(chatMenu.waitForExistence(timeout: 10), "the Chat has its menu once saved")
        sleep(1)

        for (index, choice) in choices.enumerated() {
            openSettings()
            let swatch = app.buttons["settings.accent.\(choice)"]
            app.revealInSettings(swatch)
            XCTAssertTrue(swatch.waitForExistence(timeout: 5))
            if index == 0, swatch.value as? String != "selected" {
                // A previous run left another accent.
                swatch.tap()
            }
            if index > 0 {
                let before = swatch.frame
                swatch.tap()
                // Live: the sheet stays up, scrolled where it was, with the new choice ticked.
                XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].exists, "Settings stayed open")
                XCTAssertEqual(swatch.frame, before, "Settings kept its scroll position")
            }
            XCTAssertTrue(swatch.waitForValue("selected", timeout: 5))
            XCTAssertEqual(swatch.label, "\(choice.capitalized), accent colour")
            for other in choices where other != choice {
                XCTAssertNotEqual(app.buttons["settings.accent.\(other)"].value as? String, "selected")
            }
            sleep(1)
            snapshot("\(index + 1)-\(choice)-1-settings")

            // The same Chat is still showing underneath, now in the new accent.
            app.buttons["settings.close"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(chatMenu.waitForExistence(timeout: 5), "still in the Chat")
            sleep(1)
            snapshot("\(index + 1)-\(choice)-2-chat")

            // The drawer: the current Chat's row in accentSoft and the New chat pill.
            app.openSidebar()
            XCTAssertTrue(app.buttons["drawer.account"].waitForExistence(timeout: 5))
            sleep(1)
            snapshot("\(index + 1)-\(choice)-3-drawer")

            // The new-chat home (the drawer's New chat pill), then back to the Chat (the newest row).
            app.buttons["drawer.newChat"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["conversation.greeting"].waitForExistence(timeout: 10))
            sleep(2)
            snapshot("\(index + 1)-\(choice)-4-home")
            app.openSidebar()
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(chatMenu.waitForExistence(timeout: 10))
            sleep(1)
        }

        // Back to Verdigris, then delete the test Chat.
        openSettings()
        let verdigris = app.buttons["settings.accent.verdigris"]
        app.revealInSettings(verdigris)
        verdigris.tap()
        XCTAssertTrue(verdigris.waitForValue("selected", timeout: 5))
        app.buttons["settings.close"].firstMatch.tap()
        XCTAssertTrue(chatMenu.waitForExistence(timeout: 5))
        chatMenu.tap()
        app.buttons["chat.menu.delete"].tap()
        let confirm = app.buttons["chat.menu.deleteConfirm"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    /// At an accessibility text size the swatches stack as rows and keep their labels.
    func testAccentPickerAtAnAccessibilitySize() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_ACCENT_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_ACCENT_SCREENS=1 for the accent walkthrough") }
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The accent walkthrough needs a filled-in .env") }

        app.launchArguments = [
            "-theseus-reset", "-theseus-skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
        ]
        app.launch()
        signIn(url: url, email: email, password: password)
        openSettings()
        let ultramarine = app.buttons["settings.accent.ultramarine"]
        app.revealInSettings(ultramarine)
        XCTAssertTrue(ultramarine.waitForExistence(timeout: 5))
        ultramarine.tap()
        XCTAssertTrue(ultramarine.waitForValue("selected", timeout: 5))
        XCTAssertEqual(ultramarine.label, "Ultramarine, accent colour")
        let verdigris = app.buttons["settings.accent.verdigris"]
        XCTAssertLessThan(verdigris.frame.maxY, ultramarine.frame.minY + 1, "stacked as rows")
        sleep(1)
        snapshot("5-accessibility-xl-settings")
        app.revealInSettings(verdigris)
        verdigris.tap()
        XCTAssertTrue(verdigris.waitForValue("selected", timeout: 5))
    }

    // MARK: Helpers

    private var composerField: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        _ = stop.waitForExistence(timeout: 5)
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
    }

    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

    private func signIn(url: String, email: String, password: String) {
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["signin.password"]
        if !passwordField.exists { emailField.typeText("\n") }  // email-first flow (AUTH-02)
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30), "Didn't reach the new Chat screen")
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

private extension XCUIElement {
    func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
