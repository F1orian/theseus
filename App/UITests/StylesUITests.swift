import XCTest

/// Live walkthrough of Styles (PERS-05) against the test Server (opt-in): Add to Chat › Choose
/// style, creating a `[theseus-test]` Style, its chip on the home, a Response that follows it, a
/// preset, and deleting the Style. Teardown puts `theseus.styles` back as it was, and the test
/// Chat is deleted.
final class StylesUITests: XCTestCase {
    private var credentials: (url: String, email: String, password: String)?
    private var server: StylesLiveServer?
    private var original: Data?

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The Styles walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        credentials = (url, email, password)
        let server = try await StylesLiveServer.signIn(url: try XCTUnwrap(URL(string: url)), email: email, password: password)
        original = try await server.styles()
        self.server = server
    }

    override func tearDown() async throws {
        guard let server else { return }
        try? await server.restoreStyles(original)
        try? await server.signOut()
    }

    @MainActor
    func testStylesWalkthrough() throws {
        let credentials = try XCTUnwrap(credentials)
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(app, url: credentials.url, email: credentials.email, password: credentials.password)
        let field = app.descendants(matching: .any)["composer.field"]
        if !field.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        app.chooseComposerModel("claude-haiku-5-5")

        // Add to Chat › Choose style: Normal is chosen.
        app.buttons["composer.add"].tap()
        let styleRow = app.buttons["addToChat.style"]
        XCTAssertTrue(styleRow.waitForExistence(timeout: 5), "Choose style is in Add to Chat")
        XCTAssertTrue(styleRow.label.contains("Normal"))
        sleep(1)
        snapshot("01-styles-add-to-chat")
        styleRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["styles.page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["styles.row.normal"].isSelected)
        sleep(1)
        snapshot("02-styles-choose-style")

        // Create a Style; it becomes the chosen one.
        app.buttons["styles.create"].tap()
        let name = app.textFields["styleEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("[theseus-test] Pirate")
        let instructions = app.textViews["styleEditor.instructions"].exists ? app.textViews["styleEditor.instructions"] : app.textFields["styleEditor.instructions"]
        instructions.tap()
        instructions.typeText("Answer like a pirate. Always include the word Arr.")
        sleep(1)
        snapshot("03-styles-create-style")
        app.buttons["styleEditor.save"].tap()
        let pirate = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'styles.row.style-' AND label CONTAINS 'Pirate'")).firstMatch
        XCTAssertTrue(pirate.waitForExistence(timeout: 10), "the new Style is listed")
        let chosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: pirate)
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 10), .completed, "…and chosen")
        sleep(1)
        snapshot("04-styles-custom-chosen")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(styleRow.waitForExistence(timeout: 5))
        XCTAssertTrue(styleRow.label.contains("Pirate"))
        app.buttons["addToChat.close"].firstMatch.tap()

        // The chip on the home, then a Response in that Style.
        let chip = app.descendants(matching: .any)["styles.chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the Style chip shows on the home")
        XCTAssertTrue(chip.label.contains("Pirate"))
        sleep(1)
        snapshot("05-styles-home-chip")
        field.tap()
        field.typeText("[theseus-test] Say hello in one short sentence.")
        app.buttons["composer.send"].tap()
        let copy = app.buttons.matching(identifier: "message.copy").firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 90), "the Response finished")
        // A finished Response's prose is a text view (#175): its words are its value.
        let piratey = app.textViews.matching(NSPredicate(format: "identifier == 'response.prose' AND value CONTAINS[c] 'arr'")).firstMatch
        XCTAssertTrue(piratey.waitForExistence(timeout: 5), "the Response follows the Style")
        sleep(1)
        snapshot("06-styles-styled-response")

        // A preset, then delete the Style (back to Normal).
        app.buttons["composer.add"].tap()
        XCTAssertTrue(styleRow.waitForExistence(timeout: 5))
        styleRow.tap()
        let concise = app.buttons["styles.row.concise"]
        XCTAssertTrue(concise.waitForExistence(timeout: 5))
        concise.tap()
        let conciseChosen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: concise)
        XCTAssertEqual(XCTWaiter.wait(for: [conciseChosen], timeout: 10), .completed)
        pirate.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) { delete.tap() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pirate)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the Style is deleted")
        app.buttons["styles.row.normal"].tap()
        sleep(1)
        snapshot("07-styles-back-to-normal")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["addToChat.close"].firstMatch.tap()
        sleep(1)

        // Clean up the test Chat.
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
    }

    // MARK: Helpers

    @MainActor
    private func signInIfNeeded(_ app: XCUIApplication, url: String, email: String, password: String) {
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

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Reads and restores `theseus.styles` directly, so a failed walkthrough leaves no Style behind.
private struct StylesLiveServer: Sendable {
    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> StylesLiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return StylesLiveServer(url: url, token: token)
    }

    private var settingsURL: URL {
        var url = url.appending(path: "api/v1/users/user/settings")
        url.append(queryItems: [URLQueryItem(name: "raw", value: "true")])
        return url
    }

    /// `theseus.styles` as JSON, or `nil` when unset.
    func styles() async throws -> Data? {
        let settings = try await Self.request(settingsURL, method: "GET", body: nil, token: token) as? [String: Any]
        let styles = (settings?["theseus"] as? [String: Any])?["styles"]
        return try styles.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func restoreStyles(_ original: Data?) async throws {
        let current = try await Self.request(settingsURL, method: "GET", body: nil, token: token) as? [String: Any]
        var theseus = current?["theseus"] as? [String: Any] ?? [:]
        theseus["styles"] = try original.map { try JSONSerialization.jsonObject(with: $0) }
        let body = try JSONSerialization.data(withJSONObject: ["theseus": theseus])
        _ = try await Self.request(url.appending(path: "api/v1/users/user/settings/update"), method: "POST", body: body, token: token)
    }

    func signOut() async throws {
        _ = try await Self.request(url.appending(path: "api/v1/auths/signout"), method: "POST", body: nil, token: token)
    }

    private static func request(_ url: URL, method: String, body: Data?, token: String?) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
