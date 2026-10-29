import XCTest

/// Walkthroughs of Connectors & tools (CONN-*). Both are opt-in:
/// - `testStubConnectorsTour` needs `scripts/stub-server` running and
///   `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`: it has Connectors to list, connect
///   (a fake MCP OAuth page) and disconnect, which the test Server doesn't.
/// - `testLiveConnectorsWalkthrough` needs `THESEUS_INTEGRATION=1` and the `.env` credentials: the
///   empty Connectors state, Permissions, and a web-searching `[theseus-test]` Chat that is deleted
///   at the end.
/// Screenshots are attachments named `NN-name` (export with `scripts/export-walkthrough-screens`).
@MainActor
final class ConnectorsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    // MARK: Stub Server

    func testStubConnectorsTour() throws {
        guard let url = environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("The stub tour needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: "user@example.com", password: "theseus")
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))

        // CONN-02: Settings › Connectors lists what the Server offers, A–Z.
        openSettings()
        let connectorsRow = app.buttons["settings.row.connectors"]
        // The iPad's Settings form sheet shows fewer rows: scroll to it.
        app.revealInSettings(connectorsRow)
        XCTAssertTrue(connectorsRow.waitForExistence(timeout: 10))
        connectorsRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connectors.row.server:mcp:docs"].waitForExistence(timeout: 10))
        snapshot("21-settings-connectors")

        // CONN-03 / CONN-04: the directory, with search.
        app.buttons["connectors.add"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connectors.directory"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("22-directory")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("lin")
            sleep(1)
            snapshot("23-directory-search")
        }

        // CONN-03: Connect runs the Server's OAuth flow in a signed-in web view.
        let connect = app.buttons["connectors.directory.connect.server:mcp:linear"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let allow = app.webViews.buttons["Allow access"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15))
        sleep(1)
        snapshot("24-connect-web-view")
        allow.tap()
        let connected = app.descendants(matching: .any)["connectors.directory.row.server:mcp:linear"]
            .staticTexts["Connected"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
        snapshot("25-connected")
        // Leave search: its round cancel button sits right of the field while search is active.
        let close = app.buttons["connectors.directory.close"].firstMatch
        if !close.exists, search.exists {
            search.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: 36, dy: 0)).tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.descendants(matching: .any)["connectors.row.server:mcp:linear"].waitForExistence(timeout: 5))

        // CONN-05: long-press a connected Connector to disconnect it.
        app.descendants(matching: .any)["connectors.row.server:mcp:linear"].press(forDuration: 1.2)
        let disconnect = app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        snapshot("26-disconnect-menu")
        disconnect.tap()
        let confirm = app.alerts.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("27-disconnect-alert")
        confirm.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["connectors.row.server:mcp:linear"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed)
        app.tapBack()

        // CONN-07: Settings › Permissions › Location.
        permissionsTour(prefix: "28")
        app.buttons["settings.close"].firstMatch.tap()

        // CONN-02: Add to Chat › Connectors, switched per Chat.
        app.buttons["composer.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["addToChat"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("30-add-to-chat")
        // The half-height sheet lists Connectors below Choose style: scroll to it.
        let chatConnectorsRow = app.buttons["addToChat.connectors"]
        if !chatConnectorsRow.waitForExistence(timeout: 2) || !chatConnectorsRow.isHittable {
            app.descendants(matching: .any)["addToChat"].firstMatch.swipeUp()
            sleep(1)
        }
        chatConnectorsRow.tap()
        let weather = app.switches["connectors.toggle.weather"]
        XCTAssertTrue(weather.waitForExistence(timeout: 10))
        weather.switches.firstMatch.exists ? weather.switches.firstMatch.tap() : weather.tap()
        sleep(1)
        snapshot("31-chat-connectors")
        app.tapBack()
        sleep(1)
        snapshot("32-add-to-chat-with-value")
        app.buttons["addToChat.close"].firstMatch.tap()
    }

    // MARK: Live test Server

    func testLiveConnectorsWalkthrough() throws {
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // CONN-02: the test Server has tools enabled but none configured: the empty state.
        openSettings()
        let connectorsRow = app.buttons["settings.row.connectors"]
        // The iPad's Settings form sheet shows fewer rows: scroll to it.
        app.revealInSettings(connectorsRow)
        XCTAssertTrue(connectorsRow.waitForExistence(timeout: 10))
        connectorsRow.tap()
        let empty = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'connectors.empty' OR label BEGINSWITH 'No connectors yet'")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        snapshot("01-live-connectors-empty")
        app.tapBack()

        // CONN-08: the test Server's code interpreter is Pyodide, so Capabilities has no Code execution row.
        let capabilities = app.buttons["settings.row.capabilities"]
        if capabilities.waitForExistence(timeout: 5) {
            // On iPad's shorter Settings sheet the row may sit under the navigation bar.
            app.revealInSettings(capabilities)
            capabilities.tap()
            XCTAssertTrue(app.descendants(matching: .any)["capabilities.webSearch"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.descendants(matching: .any)["capabilities.codeInterpreter"].exists)
            sleep(1)
            snapshot("02-live-capabilities")
            app.tapBack()
        }
        app.buttons["settings.close"].firstMatch.tap()

        // CONN-01: Web search per Chat from Add to Chat. The Pyodide interpreter backs no switch, but
        // the Server's sandbox does (Open Terminal, ADR 0120), so Code execution is offered.
        app.buttons["composer.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["addToChat"].waitForExistence(timeout: 5))
        let webSearch = app.switches["addToChat.toggle.web_search"]
        XCTAssertTrue(webSearch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["addToChat.toggle.code_interpreter"].exists, "the sandbox backs Code execution")
        if (webSearch.value as? String) != "1" {
            webSearch.switches.firstMatch.exists ? webSearch.switches.firstMatch.tap() : webSearch.tap()
        }
        sleep(1)
        snapshot("03-live-add-to-chat-web-search")
        app.buttons["addToChat.close"].firstMatch.tap()

        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("[theseus-test] Search the web: what is the latest stable Swift version? One sentence.")
        app.buttons["composer.send"].tap()
        sleep(3)
        waitUntilIdle(timeout: 180)
        snapshot("04-live-web-search-response")
        let searched = app.buttons["response.tools"].firstMatch.waitForExistence(timeout: 5)
            || app.buttons["response.sources"].firstMatch.exists
            || app.descendants(matching: .any)["response.status"].firstMatch.exists
        XCTAssertTrue(searched, "the Response shows its web search")

        // Clean up the test Chat.
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    /// Settings › Permissions › Location: choosing Always asks iOS (allowed here) and shares.
    private func permissionsTour(prefix: String) {
        let permissions = app.buttons["settings.row.permissions"]
        for _ in 0..<3 where !permissions.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        permissions.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.permissions"].waitForExistence(timeout: 5))
        snapshot("\(prefix)-permissions")
        app.buttons["permissions.location"].tap()
        let always = app.buttons["permissions.location.always"]
        XCTAssertTrue(always.waitForExistence(timeout: 5))
        always.tap()
        // The iOS location prompt belongs to SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // "Allow While Using App" is the middle button, whatever the simulator's language.
        let prompt = springboard.alerts.firstMatch
        if prompt.waitForExistence(timeout: 5), prompt.buttons.count >= 3 { prompt.buttons.element(boundBy: 1).tap() }
        sleep(2)
        snapshot("\(String(format: "%02d", (Int(prefix) ?? 0) + 1))-location")
        app.tapBack()
        app.tapBack()
    }

    private func signInIfNeeded(url: String, email: String, password: String) {
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

    /// Opens Settings from the drawer's account button (as in ComposerUITests).
    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
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
