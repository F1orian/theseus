import XCTest

/// BRAND-03 (#168): walks the branded chat surfaces against the test Server and keeps a
/// screenshot of each (welcome, sign-in, the welcome sheet, the home with "Today in the
/// collection", the running mouse while waiting, a finished Response with its avatar and
/// Thinking, Incognito, the home at an accessibility text size; and, against
/// `scripts/stub-server`, the full-screen error). Run it once per appearance
/// (`xcrun simctl ui <udid> appearance light|dark`). Opt-in twice over: it needs the live-Server
/// credentials and `THESEUS_BRAND_SCREENS=1` (pass it to the runner as
/// `TEST_RUNNER_THESEUS_BRAND_SCREENS=1`), so `scripts/test.sh` skips it. The Chat it sends is
/// `[theseus-test]`-marked and deleted at the end.
@MainActor
final class BrandChatScreensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testBrandedChatSurfaces() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_BRAND_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_BRAND_SCREENS=1 for the brand screenshots") }
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The brand walkthrough needs a filled-in .env") }
        let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

        // Welcome / server connect, then sign-in, then the one-time welcome sheet.
        app.launchArguments = ["-theseus-reset", "-theseus-show-welcome", "-theseus-skip-consent"] + english
        app.launchAsPro()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        sleep(2)
        snapshot("01-welcome")
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        sleep(1)
        snapshot("02-sign-in")
        emailField.tap()
        emailField.typeText(email + "\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        let sheet = app.descendants(matching: .any)["welcome.sheet"]
        if sheet.waitForExistence(timeout: 30) {
            sleep(2)
            snapshot("03-welcome-sheet")
            app.buttons["welcome.start"].tap()
        }

        // The new-chat home: the sitting mouse, the greeting and today's work.
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 20))
        let today = app.buttons["home.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 5), "Today in the collection shows on the home")
        sleep(2)
        snapshot("04-home")
        XCTAssertTrue(today.label.lowercased().hasPrefix("today in the collection"), today.label)

        // Ask about it: the composer gets a question naming the work.
        today.tap()
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let asked = (field.value as? String) ?? ""
        XCTAssertTrue(asked.hasPrefix("Tell me about "), asked)
        sleep(1)
        snapshot("05-home-asked")
        clear(field)

        // Waiting for the first token: the running mouse (several shots, for both frames).
        app.chooseComposerModel("claude-haiku-5-5")
        field.tap()
        field.typeText(
            "[theseus-test] Begin your reply with the literal tag <think>, reason briefly inside it, close it with </think>, "
                + "then answer in two sentences: who painted St. Jerome in his Study, and when?"
        )
        app.buttons["composer.send"].tap()
        for index in 1...4 { snapshot("06-waiting-\(index)") }
        waitUntilIdle()
        sleep(2)
        let thinking = app.buttons.matching(identifier: "response.thinking").firstMatch
        if thinking.waitForExistence(timeout: 3) {
            XCTAssertTrue(thinking.label.hasPrefix("Thought") || thinking.label == "Thinking", thinking.label)
        }
        snapshot("07-response")

        // Delete the test Chat.
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // Incognito: the night hero and the lantern.
        let ghost = app.buttons["chat.incognito"]
        if ghost.waitForExistence(timeout: 5) {
            ghost.tap()
            XCTAssertTrue(app.descendants(matching: .any)["incognito.notice"].waitForExistence(timeout: 5))
            sleep(2)
            snapshot("08-incognito")
            app.buttons["chat.incognito.leave"].tap()
            XCTAssertTrue(greeting.waitForExistence(timeout: 5))
        }

        // The home at an accessibility text size.
        app.terminate()
        app.launchArguments = english + ["-theseus-skip-welcome", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launchAsPro()
        if !greeting.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        sleep(2)
        snapshot("10-home-accessibility-xl")
    }

    /// The full-screen error, against `scripts/stub-server` (a Chat it doesn't have answers 404;
    /// the live Server answers 401, which signs the Account out). Start the stub first and pass
    /// its address as `THESEUS_STUB_URL` (`TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`).
    func testErrorScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_BRAND_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_BRAND_SCREENS=1 for the brand screenshots") }
        guard let stub = environment["THESEUS_STUB_URL"], !stub.isEmpty else { throw XCTSkip("Start scripts/stub-server and set THESEUS_STUB_URL") }
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAsPro()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(stub)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText("user@example.com\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText("theseus")
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))

        // A Chat the Server doesn't have, through the system so the running app takes the link.
        XCUIDevice.shared.system.open(URL(string: "theseus://chat/theseus-test-missing-chat")!)
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let failed = app.descendants(matching: .any)["conversation.loadError"]
        XCTAssertTrue(failed.waitForExistence(timeout: 15), "the missing Chat shows the error screen")
        XCTAssertTrue(app.buttons["conversation.retryLoad"].exists)
        sleep(2)
        snapshot("09-error")

        // Leave the simulator signed out, so the live walkthroughs don't start on the stub.
        app.terminate()
        app.launchArguments = ["-theseus-reset"]
        app.launchAsPro()
        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 15))
    }

    // MARK: Helpers

    private var composerField: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    private func clear(_ field: XCUIElement) {
        let text = (field.value as? String) ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        _ = stop.waitForExistence(timeout: 5)
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
