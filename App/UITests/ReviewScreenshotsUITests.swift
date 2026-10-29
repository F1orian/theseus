import XCTest

/// Screenshots for App Store Connect (App Review's in-app purchase screenshot), against
/// `scripts/stub-server` so they show no real Server or data. Opt-in: start the stub, then run with
/// `TEST_RUNNER_THESEUS_REVIEW_SCREENS=1` and `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:<port>`.
/// `scripts/export-walkthrough-screens <xcresult> <dir>` copies the images out.
@MainActor
final class ReviewScreenshotsUITests: XCTestCase {
    private let app = XCUIApplication()
    private let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// The general Theseus Pro paywall, as Settings' upgrade card opens it in the free tier, on a
    /// Server with a sandbox and Skills (the stub's review@ Account), so it lists everything Pro adds.
    func testPaywall() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_REVIEW_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_REVIEW_SCREENS=1") }
        guard let stub = environment["THESEUS_STUB_URL"], !stub.isEmpty else { throw XCTSkip("Start scripts/stub-server and set THESEUS_STUB_URL") }
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome", "-theseus-skip-consent", "-theseus-pro", "free"] + english
        app.launch()
        signIn(url: stub, email: "review@example.com", password: "theseus")

        openSettings()
        let unlock = app.buttons["settings.pro.unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        let headline = app.staticTexts["paywall.headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["paywall.purchase"].label.contains("$9.99"))
        let sandbox = app.descendants(matching: .any)["paywall.feature.sandbox"]
        XCTAssertTrue(sandbox.waitForExistence(timeout: 5))
        XCTAssertTrue(sandbox.label.contains("Run code and create files"), sandbox.label)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.connectors"].exists)
        sleep(2)
        snapshot("review-paywall")
        app.swipeUp()
        sleep(1)
        snapshot("review-paywall-promise")

        // Forget the stub Account, so later launches don't reuse it.
        app.terminate()
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome"] + english
        app.launch()
        _ = app.textFields["server.address"].waitForExistence(timeout: 15)
        app.terminate()
    }

    /// ADR 0173: on a Server without a sandbox or a Jupyter code interpreter (the stub's other
    /// Accounts), the paywall leaves code execution out and leads with what the Server offers.
    func testPaywallOnAServerWithoutCodeExecution() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_REVIEW_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_REVIEW_SCREENS=1") }
        guard let stub = environment["THESEUS_STUB_URL"], !stub.isEmpty else { throw XCTSkip("Start scripts/stub-server and set THESEUS_STUB_URL") }
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome", "-theseus-skip-consent", "-theseus-pro", "free"] + english
        app.launch()
        signIn(url: stub, email: "user@example.com", password: "theseus")

        openSettings()
        let card = app.descendants(matching: .any)["settings.pro.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Skills, Voice mode'")).firstMatch.exists)
        XCTAssertFalse(card.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'code execution'")).firstMatch.exists)
        app.buttons["settings.pro.unlock"].tap()
        XCTAssertTrue(app.staticTexts["paywall.headline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["paywall.feature.skills"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["paywall.feature.sandbox"].exists)
        sleep(1)
        snapshot("paywall-no-code-execution")

        app.terminate()
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome"] + english
        app.launch()
        _ = app.textFields["server.address"].waitForExistence(timeout: 15)
        app.terminate()
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
        emailField.typeText(email + "\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
    }

    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        _ = XCTWaiter().wait(for: [hittable], timeout: 5)
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
