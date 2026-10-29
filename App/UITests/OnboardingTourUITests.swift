import XCTest

/// Opt-in screenshot tours of the signed-out experience. They run only when the test runner gets
/// `THESEUS_SCREENSHOT_DIR` (pass `TEST_RUNNER_THESEUS_SCREENSHOT_DIR=<dir>` to xcodebuild) and
/// write PNGs there; `scripts/stub-server` provides the Server for the stub tours.
final class OnboardingTourUITests: XCTestCase {
    private var directory: URL!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = environment["THESEUS_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Screenshot tours need TEST_RUNNER_THESEUS_SCREENSHOT_DIR")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func snap(_ name: String, settle: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: directory.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ arguments: [String] = ["-theseus-ui-testing"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchSkippingWelcome()
        return app
    }

    private func connect(_ app: XCUIApplication, to address: String) {
        let field = app.textFields["server.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address + "\n")
    }

    private func enterCredentials(_ app: XCUIApplication, email: String, password: String) {
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email + "\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(password + "\n")
    }

    /// The live test Server: Server entry → sign-in → main shell.
    @MainActor
    func testLiveTour() throws {
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live tour needs the .env credentials") }

        let app = launch()
        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 10))
        snap("auth-01-server-entry")
        connect(app, to: url.replacingOccurrences(of: "https://", with: ""))
        XCTAssertTrue(app.textFields["signin.email"].waitForExistence(timeout: 15))
        snap("auth-02-sign-in")
        let emailField = app.textFields["signin.email"]
        emailField.tap()
        emailField.typeText(email + "\n")
        XCTAssertTrue(app.secureTextFields["signin.password"].waitForExistence(timeout: 5))
        snap("auth-02-sign-in-password")
        app.secureTextFields["signin.password"].typeText(password + "\n")
        let firstModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(firstModel.waitForExistence(timeout: 20))
        snap("auth-02-signed-in")

        // Revoke the session we just created.
        openSettings(app)
        let signOut = app.buttons["account.signOut"]
        for _ in 0..<4 where !signOut.isHittable {
            app.swipeUp()
        }
        signOut.tap()
        let confirm = app.buttons["account.signOut.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["signin.email"].waitForExistence(timeout: 10))
    }

    /// The drawer's account row opens Settings (CHATS-01 / SET-01).
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

    // MARK: Stub Server tours (scripts/stub-server)

    private var stubAddress: String {
        (environment["THESEUS_STUB_URL"] ?? "http://localhost:8765").replacingOccurrences(of: "http://", with: "")
    }

    /// AUTH-06: a pending Account lands on the approval screen with the admin's message.
    @MainActor
    func testStubPendingTour() throws {
        let app = launch()
        connect(app, to: stubAddress)
        enterCredentials(app, email: "pending@example.com", password: "theseus")
        XCTAssertTrue(app.staticTexts["pending.message"].waitForExistence(timeout: 10))
        snap("auth-06-pending-approval", settle: 1.5)
        app.buttons["pending.checkAgain"].tap()
        XCTAssertTrue(app.staticTexts["pending.status"].waitForExistence(timeout: 10))
    }

    /// AUTH-03: verify with a TOTP code, then enrol a new authenticator and see the recovery codes.
    @MainActor
    func testStubVerificationTour() throws {
        let app = launch()
        connect(app, to: stubAddress)
        enterCredentials(app, email: "verify@example.com", password: "theseus")
        let code = app.textFields["verify.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        snap("auth-03-verify")
        code.typeText("123456")
        let firstModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(firstModel.waitForExistence(timeout: 15), "the code auto-submits")

        let enrolling = launch()
        connect(enrolling, to: stubAddress)
        enterCredentials(enrolling, email: "enroll@example.com", password: "theseus")
        XCTAssertTrue(enrolling.staticTexts["verify.manualKey"].waitForExistence(timeout: 10))
        snap("auth-03-enroll", settle: 1.2)
        let enrollCode = enrolling.textFields["verify.code"]
        enrollCode.tap()
        enrollCode.typeText("123456")
        XCTAssertTrue(enrolling.buttons["verify.finish"].waitForExistence(timeout: 10))
        snap("auth-03-recovery-codes")

        let recovering = launch()
        connect(recovering, to: stubAddress)
        enterCredentials(recovering, email: "recover@example.com", password: "theseus")
        XCTAssertTrue(recovering.textFields["verify.code"].waitForExistence(timeout: 10))
        snap("auth-03-recover")
    }

    /// AUTH-04: SSO pills, the sign-on sheet, cookie capture, and the Server's own MFA page.
    @MainActor
    func testStubSingleSignOnTour() throws {
        let app = launch()
        connect(app, to: stubAddress)
        let pill = app.buttons["signin.sso.stub"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        snap("auth-04-sign-in-sso")
        pill.tap()
        let idpContinue = app.webViews.buttons["Continue"]
        XCTAssertTrue(idpContinue.waitForExistence(timeout: 15))
        snap("auth-04-sso-sheet", settle: 1.2)
        idpContinue.tap()
        let firstModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(firstModel.waitForExistence(timeout: 15), "the token cookie signs in")

        let mfa = launch()
        connect(mfa, to: stubAddress)
        XCTAssertTrue(mfa.buttons["signin.sso.stub-mfa"].waitForExistence(timeout: 10))
        mfa.buttons["signin.sso.stub-mfa"].tap()
        XCTAssertTrue(mfa.webViews.buttons["Continue"].waitForExistence(timeout: 15))
        mfa.webViews.buttons["Continue"].tap()
        let code = mfa.webViews.textFields.firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        code.typeText("123456")
        snap("auth-04-sso-server-mfa")
        mfa.webViews.buttons["Continue"].tap()
        let model = mfa.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 15), "the cookie set after the web MFA page signs in")
    }

    /// AUTH-07: two Accounts on one device, switching between them from the account menu.
    @MainActor
    func testStubAccountsTour() throws {
        let app = launch()
        connect(app, to: stubAddress)
        enterCredentials(app, email: "user@example.com", password: "theseus")
        let firstModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(firstModel.waitForExistence(timeout: 15))

        openSwitcher(app)
        app.buttons["accounts.add"].tap()
        XCTAssertTrue(app.buttons["onboarding.cancel"].waitForExistence(timeout: 5))
        connect(app, to: stubAddress)
        enterCredentials(app, email: "second@example.com", password: "theseus")
        XCTAssertTrue(firstModel.waitForExistence(timeout: 15))

        openSwitcher(app)
        snap("auth-07-account-switcher")
        app.buttons["accounts.row.user@example.com"].tap()
        XCTAssertTrue(firstModel.waitForExistence(timeout: 15))
    }

    @MainActor
    private func openSwitcher(_ app: XCUIApplication) {
        openSettings(app)
        app.buttons["settings.switchAccount"].tap()
        XCTAssertTrue(app.buttons["accounts.add"].waitForExistence(timeout: 5))
    }

    /// ADR 0171: a new Account agrees to send its data to the Server and its AI providers before
    /// the shell opens; Sign out goes back to sign-in, Agree lands on the home.
    @MainActor
    func testStubAsksForAIDataConsent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-ui-testing"]  // no -theseus-skip-welcome: the consent shows
        app.launch()
        connect(app, to: stubAddress)
        enterCredentials(app, email: "user@example.com", password: "theseus")
        let agree = app.buttons["consent.agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "the consent shows after sign-in")
        XCTAssertTrue(app.descendants(matching: .any)["consent.disclosure"].exists)
        snap("consent-ai-data", settle: 1)
        app.buttons["consent.signOut"].tap()
        // Back on sign-in for this Server, with the email prefilled.
        let password = app.secureTextFields["signin.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("theseus\n")
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "declining doesn't count as agreeing")
        agree.tap()
        let home = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'composer.field' OR identifier == 'welcome.sheet'"))
            .firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15), "agreeing opens the shell")
    }

    /// ADR 0170: no account creation in the app, even where the Server allows sign-up (the stub does).
    @MainActor
    func testStubOffersNoSignUp() throws {
        let app = launch()
        connect(app, to: stubAddress)
        XCTAssertTrue(app.textFields["signin.email"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["signin.toggleSignUp"].exists)
        XCTAssertFalse(app.textFields["signup.name"].exists)
    }
}
