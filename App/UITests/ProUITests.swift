import XCTest

/// Live walkthrough of Theseus Pro in the free tier (ADR 0173, #182) against the test Server,
/// with the App Store in memory (`-theseus-pro free`). It sends nothing and changes nothing on
/// the Server. Opt-in like the other live UI tests: THESEUS_INTEGRATION=1 and a filled-in .env.
final class ProUITests: XCTestCase {
    private var credentials: (url: String, email: String, password: String)?

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The Theseus Pro walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        credentials = (url, email, password)
    }

    @MainActor
    func testFreeTierUpsellAndPurchase() throws {
        let credentials = try XCTUnwrap(credentials)
        let app = XCUIApplication()
        // None of today's free code execution runs used yet (UserDefaults' argument domain; the count
        // outlives `-theseus-reset`, which forgets Accounts only).
        app.launchArguments = ["-theseus-reset", "-theseus-pro", "free", "-theseus.pro.sandbox.used", "0"]
        app.launchSkippingWelcome()
        signIn(app, url: credentials.url, email: credentials.email, password: credentials.password)

        // Voice mode is Pro: the composer's waveform opens the paywall with its own headline.
        let voice = app.buttons["composer.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()
        let headline = app.staticTexts["paywall.headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertEqual(headline.label, "Voice mode is part of Theseus Pro")
        XCTAssertTrue(app.buttons["paywall.purchase"].label.contains("$9.99"))
        snapshot("pro-01-paywall-voice")
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["paywall.promise"].waitForExistence(timeout: 3))
        snapshot("pro-02-paywall-promise")
        app.buttons["paywall.close"].firstMatch.tap()

        // Add to Chat: today's free code execution runs under Code execution, Skills with a Pro badge.
        app.buttons["composer.add"].tap()
        let allowance = app.buttons["addToChat.sandboxAllowance"]
        XCTAssertTrue(allowance.waitForExistence(timeout: 5))
        XCTAssertTrue(allowance.label.contains("5 of 5 free runs left today"), allowance.label)
        snapshot("pro-03-add-to-chat")
        let skills = app.buttons["addToChat.skillsRow"]
        if skills.waitForExistence(timeout: 3) {
            skills.tap()
            XCTAssertTrue(app.staticTexts["paywall.headline"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["paywall.headline"].label, "Skills are part of Theseus Pro")
            app.buttons["paywall.close"].firstMatch.tap()
        }
        app.buttons["addToChat.close"].firstMatch.tap()

        // Settings: the upgrade card on top, and the Theseus Pro page.
        openSettings(app)
        let card = app.descendants(matching: .any)["settings.pro.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        snapshot("pro-04-settings-card")
        let row = app.buttons["settings.row.pro"]
        app.revealInSettings(row)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.pro.page"].waitForExistence(timeout: 5))
        snapshot("pro-05-pro-page")
        app.tapBack()

        // Buying from the card shows the thank-you; Settings then says Active.
        let unlock = app.buttons["settings.pro.unlock"]
        app.swipeDown()
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.tap()
        XCTAssertTrue(app.staticTexts["paywall.headline"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["paywall.headline"].label, "Theseus Pro")
        snapshot("pro-06-paywall")
        app.buttons["paywall.purchase"].tap()
        XCTAssertTrue(app.staticTexts["paywall.thanks"].waitForExistence(timeout: 5))
        snapshot("pro-07-thanks")
        app.buttons["paywall.done"].tap()
        XCTAssertFalse(card.waitForExistence(timeout: 2), "the card goes once Pro is unlocked")
        app.revealInSettings(row)
        XCTAssertTrue(row.label.contains("Active"), row.label)
        snapshot("pro-08-settings-active")
    }

    /// The last free sandbox run of the day: the Response shows the run's footer, then the composer
    /// says code execution is back tomorrow. One harmless `echo` in the sandbox; the Chat is deleted.
    @MainActor
    func testLastFreeSandboxRun() throws {
        let credentials = try XCTUnwrap(credentials)
        let app = XCUIApplication()
        // Four of today's five free runs are already used (UserDefaults' argument domain).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        app.launchArguments = [
            "-theseus-reset", "-theseus-pro", "free",
            "-theseus.pro.sandbox.day", formatter.string(from: Date()),
            "-theseus.pro.sandbox.used", "4",
        ]
        app.launchSkippingWelcome()
        signIn(app, url: credentials.url, email: credentials.email, password: credentials.password)
        app.chooseComposerModel("claude-haiku-5-5")

        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("[theseus-test] Use the sandbox: run `echo theseus` with run_command, then reply with one word.")
        let responses = app.responseCount
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.sendWentThrough(responsesBefore: responses))
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(180)
        while stop.exists, Date() < deadline { usleep(300_000) }

        let footer = app.descendants(matching: .any)["sandbox.freeRun"]
        XCTAssertTrue(footer.waitForExistence(timeout: 15), "No free-run footer under the Response")
        let notice = app.buttons["composer.notice.action"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "No 'used up' notice on the composer")
        snapshot("pro-09-last-free-run")
        notice.tap()
        XCTAssertTrue(app.staticTexts["paywall.headline"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["paywall.headline"].label, "You've used today's free code execution runs")
        snapshot("pro-10-paywall-sandbox")
        app.buttons["paywall.close"].firstMatch.tap()

        // Clean up: delete the test Chat through the Chat menu (CHATS-07).
        app.buttons["chat.menu"].firstMatch.tap()
        app.buttons["chat.menu.delete"].tap()
        let confirm = app.buttons["chat.menu.deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
    }

    // MARK: Helpers

    @MainActor
    private func signIn(_ app: XCUIApplication, url: String, email: String, password: String) {
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

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        _ = XCTWaiter().wait(for: [hittable], timeout: 5)
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
