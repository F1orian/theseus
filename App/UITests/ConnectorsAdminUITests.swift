import XCTest

/// Walkthroughs of adding connections (#186) against `scripts/stub-server`. Opt-in: start the
/// stub and pass `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`. Each test resets the stub
/// first (`POST /api/v1/stub/reset`). Run once per appearance (`xcrun simctl ui <udid>
/// appearance light|dark`); screenshots are attachments named `NN-name` (export with
/// `scripts/export-walkthrough-screens`).
///
/// - `testAdminConnectionsTour` (fresh@, admin): the empty state, the Add sheet for each sign-in
///   kind, Verify, saving an OAuth 2.1 MCP server (then Connect now) and an OpenAPI server with a
///   bearer key, edit, turn off, remove, and both default user permissions.
/// - `testPersonalConnectorTour` (builder@, a user allowed personal connectors): adds a personal
///   OpenAPI connector (its key saved in the user settings, like the web client, #189), and a chat
///   uses it through `execute:tool`, called from the device with that key.
/// - `testNonAdminWithoutPermission` (newbie@): the explanation and the non-admin empty state.
/// - `testStaticOAuthTour` (fresh@, #193): an MCP server whose provider refuses dynamic client
///   registration (the stub's "github" URLs, like GitHub): Save with OAuth 2.1 explains it and
///   offers OAuth 2.1 (static) or a personal token; the switch keeps the fields, the sheet shows the
///   callback URL to register, and the static entry saves and connects.
@MainActor
final class ConnectorsAdminUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stubURL: String!

    override func setUp() async throws {
        continueAfterFailure = true
        guard let url = ProcessInfo.processInfo.environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("Needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        stubURL = url
        try await resetStub()
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-ui-testing"]
    }

    /// Leaves the stub as it started, so walkthroughs of other areas (#187's Skills) see the
    /// default permissions again.
    override func tearDown() async throws {
        if stubURL != nil { try? await resetStub() }
    }

    private var prefix: String {
        let dark = ProcessInfo.processInfo.environment["THESEUS_APPEARANCE"] == "dark"
        return dark ? "dark-" : "light-"
    }

    // MARK: Admin

    func testAdminConnectionsTour() throws {
        signIn(email: "fresh@example.com")
        openConnectors()

        // The admin empty state: nothing on the Server yet, with the next step.
        let empty = element("connectors.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        sleep(1)
        snapshot("41-admin-empty")

        // Add connector: MCP with OAuth 2.1.
        app.buttons["connectors.empty.add"].firstMatch.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        type("[theseus-test] Notion", into: "connectors.form.name")
        type("https://mcp.notion.example/mcp", into: "connectors.form.url")
        snapshot("42-add-mcp-none")
        chooseAuth("Bearer key")
        snapshot("43-add-mcp-bearer")
        chooseAuth("Session")
        snapshot("44-add-mcp-session")
        chooseAuth("OAuth 2.1")
        snapshot("45-add-mcp-oauth")
        tapVerify()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 10))
        snapshot("46-verify-oauth")
        app.buttons["connectors.form.save"].tap()

        // Saved: offer to connect right away (the existing Connect sheet, ADR 0090).
        let connectNow = app.alerts.buttons["Connect now"].firstMatch
        XCTAssertTrue(connectNow.waitForExistence(timeout: 10))
        snapshot("47-connect-now")
        connectNow.tap()
        let allow = app.webViews.buttons["Allow access"]
        if allow.waitForExistence(timeout: 15) {
            snapshot("48-connect-sheet")
            allow.tap()
        }
        XCTAssertTrue(element("connectors.row.server:mcp:theseus-test-notion").waitForExistence(timeout: 15))

        // Add connector: OpenAPI with a bearer key.
        app.buttons["connectors.shared.add"].firstMatch.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        type("[theseus-test] Notes", into: "connectors.form.name")
        type("\(stubURL!)/stub-tools", into: "connectors.form.url")
        app.buttons["OpenAPI"].firstMatch.tap()
        chooseAuth("Bearer key")
        let key = app.secureTextFields["connectors.form.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("stub-tool-key\n")
        snapshot("49-add-openapi-bearer")
        tapVerify()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 10))
        reveal(element("connectors.form.verifyResult"))
        snapshot("50-verify-openapi")
        app.buttons["connectors.form.save"].tap()
        let notes = element("connectors.row.server:theseus-test-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 20))
        sleep(1)
        snapshot("51-managed-list")

        // Edit: the key shows as set, and only the description changes.
        notes.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectors.form.replaceKey"].waitForExistence(timeout: 5), "the key is masked")
        snapshot("52-edit-masked-key")
        let description = element("connectors.form.description")
        reveal(description)
        description.tap()
        description.typeText("Team notes")
        app.buttons["connectors.form.save"].tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 10))

        // Turn off: it leaves the chat list but stays manageable ("Off").
        notes.press(forDuration: 1.2)
        let turnOff = app.buttons["Turn off for everyone"].firstMatch
        XCTAssertTrue(turnOff.waitForExistence(timeout: 5))
        snapshot("53-manage-menu")
        turnOff.tap()
        let off = element("connectors.shared.theseus-test-notes")
        XCTAssertTrue(off.waitForExistence(timeout: 10))
        snapshot("54-turned-off")

        // Remove, after a confirmation that names the effect.
        off.press(forDuration: 1.2)
        app.buttons["Remove"].firstMatch.tap()
        let confirm = app.alerts.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("55-remove-confirmation")
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: off)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed)
        app.tapBack()

        // Server administration: Connectors and User permissions.
        let administration = app.buttons["settings.row.administration"]
        app.revealInSettings(administration)
        XCTAssertTrue(administration.waitForExistence(timeout: 10))
        administration.tap()
        XCTAssertTrue(element("settings.administration").waitForExistence(timeout: 5))
        snapshot("56-server-administration")
        app.buttons["settings.administration.connectors"].firstMatch.tap()
        XCTAssertTrue(element("administration.connectors").waitForExistence(timeout: 5))
        sleep(1)
        snapshot("57-administration-connectors")
        app.tapBack()

        app.buttons["settings.administration.userPermissions"].firstMatch.tap()
        let personal = app.switches["settings.userPermissions.features.direct_tool_servers"]
        XCTAssertTrue(personal.waitForExistence(timeout: 10))
        snapshot("58-user-permissions")
        flip(personal)
        let save = app.alerts.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        snapshot("59-permission-confirmation")
        save.tap()
        let skills = app.switches["settings.userPermissions.workspace.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 5))
        sleep(1)
        flip(skills)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        sleep(1)
        XCTAssertEqual(personal.value as? String, "1")
        XCTAssertEqual(skills.value as? String, "1")
        snapshot("60-user-permissions-on")
    }

    // MARK: Personal

    func testPersonalConnectorTour() throws {
        signIn(email: "builder@example.com")
        openConnectors()

        let add = app.buttons["connectors.personal.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        snapshot("61-yours-empty")
        add.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        type("[theseus-test] My notes", into: "connectors.form.name")
        type("\(stubURL!)/stub-tools", into: "connectors.form.url")
        let key = app.secureTextFields["connectors.form.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("stub-tool-key\n")
        snapshot("62-add-personal")
        tapVerify()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 10))
        reveal(element("connectors.form.verifyResult"))
        snapshot("63-verify-personal")
        app.buttons["connectors.form.save"].tap()
        let row = element("connectors.personal.[theseus-test] My notes")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let explanation = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'like the web app does in the browser'")).firstMatch
        XCTAssertTrue(explanation.exists, "Yours explains who calls personal connectors")
        sleep(2)
        snapshot("64-yours-list")
        app.tapBack()
        app.buttons["settings.close"].firstMatch.tap()

        // A chat: the stub asks the app to run the connector's tool; the device calls it.
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("[theseus-test] What notes do I have for work?")
        app.buttons["composer.send"].tap()
        // Finished prose is one text view (ADR 0150): match its label or value.
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'answered' OR value CONTAINS 'answered'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 40), "the personal connector answered through execute:tool, with the key from its entry")
        let used = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'list notes'")).firstMatch
        XCTAssertTrue(used.waitForExistence(timeout: 5), "the Response shows the tool call")
        sleep(1)
        snapshot("65-chat-used-personal-connector")
    }

    // MARK: OAuth 2.1 (static) (#193)

    func testStaticOAuthTour() throws {
        signIn(email: "fresh@example.com")
        openConnectors()
        let add = app.buttons["connectors.empty.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        type("[theseus-test] GitHub", into: "connectors.form.name")
        type("https://api.githubcopilot.example/mcp/", into: "connectors.form.url")
        chooseAuth("OAuth 2.1")
        app.buttons["connectors.form.save"].tap()

        // The provider has no dynamic client registration: a plain explanation and two ways on.
        let help = element("connectors.form.registrationHelp")
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectors.form.useStatic"].exists)
        XCTAssertTrue(app.buttons["connectors.form.useBearer"].exists)
        sleep(1)
        snapshot("76-dcr-unsupported")

        // Switch to OAuth 2.1 (static): the fields stay (the callback URL's id comes from the
        // name), and the callback URL is shown.
        app.buttons["connectors.form.useStatic"].tap()
        let callback = element("connectors.form.callbackURL")
        XCTAssertTrue(callback.waitForExistence(timeout: 5))
        XCTAssertTrue(callback.label.contains("/oauth/clients/mcp:theseus-test-github/callback"), callback.label)
        XCTAssertFalse(help.exists, "the explanation goes once sign-in changed")
        type("Ov23liStubClient", into: "connectors.form.clientID")
        let secret = app.secureTextFields["connectors.form.clientSecret"]
        reveal(secret)
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        secret.tap()
        secret.typeText("stub-secret\n")
        if !callback.isHittable { formList.swipeDown() }
        reveal(callback)
        // Bring the Sign-in picker into the picture, above the OAuth app section.
        let scope = app.textFields["connectors.form.scope"]
        if scope.exists {
            let start = scope.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        }
        sleep(1)
        snapshot("77-add-static-oauth")
        app.buttons["connectors.form.copyCallback"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3))

        tapVerify()
        XCTAssertTrue(element("connectors.form.verifyResult").waitForExistence(timeout: 10))
        app.buttons["connectors.form.save"].tap()

        // Saved with the app's credentials: Connect now works as for OAuth 2.1.
        let connectNow = app.alerts.buttons["Connect now"].firstMatch
        XCTAssertTrue(connectNow.waitForExistence(timeout: 10))
        sleep(1)
        connectNow.tap()
        let allow = app.webViews.buttons["Allow access"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "the Connect sheet opens the Server's authorize page")
        sleep(1)
        snapshot("78-static-connect-sheet")
        allow.tap()
        let row = element("connectors.row.server:mcp:theseus-test-github")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(1)
        snapshot("79-static-saved")

        // Edit: the secret shows as set and isn't sent again unless replaced.
        row.tap()
        XCTAssertTrue(element("connectors.form").waitForExistence(timeout: 5))
        let replaceSecret = app.buttons["connectors.form.replaceSecret"]
        for _ in 0..<4 where !(replaceSecret.exists && replaceSecret.isHittable) {
            dragFormUp()
        }
        XCTAssertTrue(replaceSecret.waitForExistence(timeout: 5), "the client secret is masked")
        XCTAssertEqual(app.textFields["connectors.form.clientID"].value as? String, "Ov23liStubClient")
        snapshot("80-edit-static-masked-secret")
        app.buttons["connectors.form.cancel"].tap()
    }

    // MARK: Non-admin without the permission

    func testNonAdminWithoutPermission() throws {
        signIn(email: "newbie@example.com")
        openConnectors()
        let explanation = element("connectors.personal.unavailable")
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["connectors.personal.add"].exists)
        XCTAssertFalse(app.buttons["connectors.shared.add"].exists, "no admin controls")
        XCTAssertTrue(element("connectors.empty").waitForExistence(timeout: 5))
        sleep(1)
        snapshot("66-non-admin-explanation-empty")
        app.tapBack()
        XCTAssertFalse(app.buttons["settings.row.administration"].exists, "Server administration is admins only")
    }

    // MARK: Helpers

    private func resetStub() async throws {
        guard let url = URL(string: "\(stubURL!)/api/v1/stub/reset") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func type(_ text: String, into identifier: String) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No field \(identifier)")
        field.tap()
        // Return ends editing, so screenshots show the form, not the keyboard.
        field.typeText(text + "\n")
    }

    private func chooseAuth(_ label: String) {
        let picker = app.buttons["connectors.form.auth"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons[label].firstMatch.exists ? app.buttons[label].firstMatch : app.collectionViews.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "No sign-in option \(label)")
        option.tap()
        sleep(1)
    }

    /// The sheet's list (the frontmost collection view).
    private var formList: XCUIElement {
        app.collectionViews.containing(.button, identifier: "connectors.form.verify").firstMatch
    }

    private func tapVerify() {
        let verify = app.buttons["connectors.form.verify"].firstMatch
        reveal(verify)
        verify.tap()
    }

    /// Scrolls the form until `target` is fully on screen.
    private func reveal(_ target: XCUIElement, in container: XCUIElement? = nil) {
        for _ in 0..<5 {
            if target.exists, target.isHittable, target.frame.maxY < app.windows.firstMatch.frame.maxY - 40 { return }
            if formList.exists { formList.swipeUp() } else { dragFormUp() }
        }
    }

    /// Scrolls the frontmost list up by dragging in the middle of the screen (for when the Verify
    /// button that finds `formList` is scrolled out of the lazy list).
    private func dragFormUp() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
    }

    private func flip(_ toggle: XCUIElement) {
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
    }

    private func signIn(email: String) {
        app.launchSkippingWelcome()
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        address.tap()
        address.typeText(stubURL)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let password = app.secureTextFields["signin.password"]
        if !password.exists { emailField.typeText("\n") }
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("theseus")
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))
    }

    private func openConnectors() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed)
        avatar.tap()
        XCTAssertTrue(element("settings.sheet").waitForExistence(timeout: 5))
        let row = app.buttons["settings.row.connectors"]
        app.revealInSettings(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("settings.connectors").waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name.prefix(3) + prefix + name.dropFirst(3)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
