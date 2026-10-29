import XCTest

final class TheseusUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Offline smoke test: a fresh launch lands on Server entry and validates the address.
    @MainActor
    func testLaunchShowsServerEntryAndValidatesAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-ui-testing"]
        app.launchSkippingWelcome()

        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("ftp://not-a-server")
        app.buttons["server.continue"].tap()

        XCTAssertTrue(app.staticTexts["server.error"].waitForExistence(timeout: 5))
    }

    /// Live flow: Server entry → sign in → model list. Runs only when the test runner gets
    /// credentials (scripts/test.sh passes them as TEST_RUNNER_THESEUS_OWUI_* with
    /// THESEUS_INTEGRATION=1). Leaves the app signed in, so a relaunch shows the model list.
    @MainActor
    func testSignInShowsModelList() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("Live sign-in needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()

        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()

        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email + "\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()

        // Signed in: the model list, then the new-chat screen once Chat services are ready.
        let firstModel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'model.' OR identifier == 'composer.field'"))
            .firstMatch
        XCTAssertTrue(firstModel.waitForExistence(timeout: 20))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Model list"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
