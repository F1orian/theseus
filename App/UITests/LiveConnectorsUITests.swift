import XCTest

/// #186 on the live test Server (owner exception, 2026-10-25: writes allowed for this issue, every
/// item named `[theseus-test]` and removed again). Opt-in: `THESEUS_INTEGRATION=1` with the `.env`
/// credentials, plus `TEST_RUNNER_THESEUS_TOOLS_URL`, a fake OpenAPI tool server both the Server
/// and the simulator reach (`scripts/stub-server --host 0.0.0.0` → `http://<Mac LAN IP>:<port>/stub-tools`).
/// Run `.scratch/connectors-add/live-cleanup.py` afterwards as a safety net.
///
/// It adds a personal connector and has a real model call it from the device (`execute:tool`) in
/// an Incognito chat; adds a shared OpenAPI connection (admins only) and verifies it; adds an
/// OAuth 2.1 MCP server (Notion) and opens Connect up to the provider's sign-in; then removes all
/// three.
@MainActor
final class LiveConnectorsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-ui-testing"]
    }

    func testLiveConnectorsTour() throws {
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty,
              let tools = environment["THESEUS_TOOLS_URL"], !tools.isEmpty
        else { throw XCTSkip("Needs THESEUS_INTEGRATION=1, the .env credentials and TEST_RUNNER_THESEUS_TOOLS_URL") }
        app.launchSkippingWelcome()
        signIn(url: url, email: email, password: password)
        openConnectors()

        // 1. A personal connector, checked from the device.
        app.buttons["connectors.personal.add"].firstMatch.tap()
        type("[theseus-test] My notes", into: "connectors.form.name")
        type(tools, into: "connectors.form.url")
        let key = app.secureTextFields["connectors.form.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("stub-tool-key\n")
        app.buttons["connectors.form.verify"].firstMatch.tap()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 15))
        snapshot("71-live-personal-verified")
        app.buttons["connectors.form.save"].tap()
        XCTAssertTrue(element("connectors.personal.[theseus-test] My notes").waitForExistence(timeout: 15))

        // 2. A shared OpenAPI connection (only admins), verified by the Server itself.
        let addShared = app.buttons["connectors.empty.add"].exists ? app.buttons["connectors.empty.add"] : app.buttons["connectors.shared.add"]
        XCTAssertTrue(addShared.waitForExistence(timeout: 10))
        addShared.tap()
        type("[theseus-test] Team notes", into: "connectors.form.name")
        type(tools, into: "connectors.form.url")
        app.buttons["OpenAPI"].firstMatch.tap()
        chooseMenu("connectors.form.auth", "Bearer key")
        let sharedKey = app.secureTextFields["connectors.form.key"]
        XCTAssertTrue(sharedKey.waitForExistence(timeout: 5))
        sharedKey.tap()
        sharedKey.typeText("stub-tool-key\n")
        app.buttons["connectors.form.verify"].firstMatch.tap()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 20))
        snapshot("72-live-shared-verified")
        chooseMenu("connectors.form.access", "Only me")
        app.buttons["connectors.form.save"].tap()
        let shared = element("connectors.row.server:theseus-test-team-notes")
        XCTAssertTrue(shared.waitForExistence(timeout: 20))
        snapshot("73-live-managed-list")

        // 3. An OAuth 2.1 MCP server: register, save, Connect reaches the provider's sign-in.
        app.buttons["connectors.shared.add"].firstMatch.tap()
        type("[theseus-test] Notion", into: "connectors.form.name")
        type("https://mcp.notion.com/mcp", into: "connectors.form.url")
        chooseMenu("connectors.form.auth", "OAuth 2.1")
        app.buttons["connectors.form.verify"].firstMatch.tap()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 20))
        chooseMenu("connectors.form.access", "Only me")
        app.buttons["connectors.form.save"].tap()
        let connectNow = app.alerts.buttons["Connect now"].firstMatch
        XCTAssertTrue(connectNow.waitForExistence(timeout: 20))
        connectNow.tap()
        XCTAssertTrue(element("connectors.connect").waitForExistence(timeout: 20))
        let providerPage = app.webViews.firstMatch
        XCTAssertTrue(providerPage.waitForExistence(timeout: 20))
        sleep(6)
        snapshot("74-live-notion-sign-in")
        app.buttons["connectors.connect.cancel"].firstMatch.tap()

        // Remove both shared connections (confirmed), then the personal one.
        for id in ["connectors.row.server:mcp:theseus-test-notion", "connectors.row.server:theseus-test-team-notes"] {
            removeShared(element(id))
        }
        let personal = element("connectors.personal.[theseus-test] My notes")
        XCTAssertTrue(personal.waitForExistence(timeout: 10))

        // 4. A real model calls the personal connector; the device answers `execute:tool`.
        app.tapBack()
        app.buttons["settings.close"].firstMatch.tap()
        app.buttons["chat.incognito"].firstMatch.tap()
        app.chooseComposerModel("claude-haiku-5-5")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("[theseus-test] Use the list_notes tool with tag work, then reply with only the text of the note it returns.")
        app.buttons["composer.send"].tap()
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Ship #186' OR value CONTAINS 'Ship #186'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "the model got the note through the device")
        sleep(1)
        snapshot("75-live-chat-personal-connector")
        app.buttons["chat.incognito.leave"].firstMatch.tap()

        // Clean up the personal connector.
        openConnectors()
        let row = element("connectors.personal.[theseus-test] My notes")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        app.buttons["Remove"].firstMatch.tap()
        app.alerts.buttons["Remove"].firstMatch.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 15), .completed)
    }

    // MARK: Helpers

    private func removeShared(_ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.alerts.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 15), .completed)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func type(_ text: String, into identifier: String) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No field \(identifier)")
        field.tap()
        field.typeText(text + "\n")
    }

    private func chooseMenu(_ identifier: String, _ label: String) {
        let picker = app.buttons[identifier].firstMatch
        for _ in 0..<4 where !picker.isHittable {
            app.collectionViews.containing(.button, identifier: "connectors.form.verify").firstMatch.swipeUp()
        }
        picker.tap()
        let option = app.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "No option \(label)")
        option.tap()
        sleep(1)
    }

    private func signIn(url: String, email: String, password: String) {
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 20))
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["signin.password"]
        if !passwordField.exists { emailField.typeText("\n") }
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
    }

    private func openConnectors() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed)
        avatar.tap()
        let row = app.buttons["settings.row.connectors"]
        app.revealInSettings(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("settings.connectors").waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
