import XCTest

/// Live walkthrough of the one-time welcome (AUTH-08) against the test Server (opt-in): after a
/// fresh sign-in it lists what works with the Server, closes with "Start chatting", and doesn't
/// come back on the next launch. `-theseus-show-welcome` shows it even if this simulator's
/// Account has seen it before.
@MainActor
final class WelcomeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testWelcomeAfterFirstSignIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchArguments = ["-theseus-reset", "-theseus-show-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAsPro()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email + "\n")  // email-first flow (AUTH-02)
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()

        // ADR 0171: the AI data consent comes first, unless this simulator already agreed.
        let agree = app.buttons["consent.agree"]
        if agree.waitForExistence(timeout: 15) { agree.tap() }

        // The welcome: what works with this Server, from its Capabilities.
        let sheet = app.descendants(matching: .any)["welcome.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "the welcome shows after the first sign-in")
        let chats = app.descendants(matching: .any)["welcome.item.chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        XCTAssertTrue(chats.label.contains(URL(string: url)?.host() ?? url), "it names the Server")
        // The test Server has no speech engines: voice runs on-device (ADR 0080).
        let voice = app.descendants(matching: .any)["welcome.item.voice"]
        if voice.exists { XCTAssertTrue(voice.label.contains("on this device")) }
        XCTAssertTrue(app.descendants(matching: .any)["welcome.item.projects"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'upgrade' OR label CONTAINS[c] 'desktop'")).firstMatch.exists, "no promotion")
        sleep(1)
        snapshot("01-welcome")
        app.buttons["welcome.start"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 10), "Start chatting lands on the home")
        sleep(1)
        snapshot("02-after-welcome")

        // Once seen, it stays away for this Account.
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAsPro()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertFalse(sheet.exists, "the welcome shows once")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
