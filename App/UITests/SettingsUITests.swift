import XCTest

/// Live walkthrough of the Settings sheet (SET-*) against the test Server. Opt-in like the other
/// live UI tests: needs THESEUS_INTEGRATION=1 and a filled-in .env. It changes only on-device
/// preferences and Shared links of its own "[theseus-test]" Chat, which it deletes afterwards.
/// Screenshots are kept as attachments of the result bundle.
final class SettingsUITests: XCTestCase {
    private var credentials: (url: String, email: String, password: String)?
    private var server: SettingsLiveServer?
    private var sharedChatID: String?

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The Settings walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        credentials = (url, email, password)
        // SET-08 needs a Shared link: share a throwaway "[theseus-test]" Chat with two Messages.
        let server = try await SettingsLiveServer.signIn(url: try XCTUnwrap(URL(string: url)), email: email, password: password)
        sharedChatID = try await server.createSharedChat(title: "\(SettingsLiveServer.testPrefix) Shared walk")
        self.server = server
    }

    override func tearDown() async throws {
        guard let server else { return }
        if let sharedChatID {
            try? await server.unshare(chatID: sharedChatID)
            try? await server.deleteChat(id: sharedChatID)
        }
        try? await server.resetTheseusSettings()
        try? await server.signOut()
    }

    @MainActor
    func testSettingsWalkthrough() throws {
        let credentials = try XCTUnwrap(credentials)
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: credentials.url, email: credentials.email, password: credentials.password)

        // SET-01: the drawer's Account row opens the Settings sheet.
        openSettings(app)
        XCTAssertTrue(app.staticTexts["settings.account.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.row.sharedLinks"].waitForExistence(timeout: 10))
        snapshot("set-01-settings")

        // SET-05: Capabilities shows only what the Server allows; switching saves to the Server.
        app.buttons["settings.row.capabilities"].tap()
        let webSearch = app.switches["capabilities.webSearch"]
        XCTAssertTrue(webSearch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["capabilities.imageGeneration"].exists, "image generation is off on the test Server")
        snapshot("set-05-capabilities")
        let initial = webSearch.value as? String
        webSearch.switches.firstMatch.tap()
        XCTAssertTrue(webSearch.waitForValue(not: initial, timeout: 5))
        webSearch.switches.firstMatch.tap()
        XCTAssertTrue(webSearch.waitForValue(initial, timeout: 5))
        goBack(app)

        // SET-08: Shared links lists the shared Chat; the snapshot is read-only; deleting keeps the Chat.
        let chatID = try XCTUnwrap(sharedChatID)
        app.buttons["settings.row.sharedLinks"].tap()
        let row = app.buttons["sharedLinks.row.\(chatID)"]
        if !row.waitForExistence(timeout: 10) {
            // Pull to refresh once in case the list loaded before the Server listed the new link.
            app.swipeDown()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snapshot("set-08-shared-links")
        row.tap()
        XCTAssertTrue(app.staticTexts["Plan a short walk"].waitForExistence(timeout: 10))
        snapshot("set-08-shared-snapshot")
        app.buttons["sharedChat.menu"].firstMatch.tap()
        app.buttons["sharedChat.delete"].firstMatch.tap()
        let confirmDelete = app.buttons["Delete link"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sharedLinks"].waitForExistence(timeout: 10))
        XCTAssertFalse(row.waitForExistence(timeout: 2), "the link is gone")
        goBack(app)

        // SET-09: Server & usage replaces Billing.
        app.buttons["settings.row.serverUsage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["serverUsage.tiles"].waitForExistence(timeout: 15))
        snapshot("set-09-server-usage")
        goBack(app)

        // SET-06: Response notifications ask iOS for permission when turned on.
        app.buttons["settings.row.notifications"].tap()
        let responses = app.switches["notifications.responses"]
        XCTAssertTrue(responses.waitForExistence(timeout: 5))
        if responses.value as? String != "1" {
            responses.switches.firstMatch.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 5) {
                snapshot("set-06-permission")
                alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
            }
        }
        XCTAssertTrue(responses.waitForValue("1", timeout: 5))
        snapshot("set-06-notifications")
        goBack(app)

        // SET-07 + SET-10: Data & privacy, with the contact-the-admin dialog for Delete account.
        app.buttons["settings.row.dataPrivacy"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dataPrivacy.admin"].waitForExistence(timeout: 10))
        snapshot("set-07-data-privacy")
        let delete = app.buttons["account.delete"]
        scrollTo(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.alerts["Contact your Server admin"].waitForExistence(timeout: 5))
        snapshot("set-10-delete-account")
        app.alerts.buttons["Cancel"].tap()
        goBack(app)

        // SET-11: the info menu headed by the app version, the About page and acknowledgements.
        app.buttons["settings.info"].firstMatch.tap()
        let about = app.buttons["About Theseus"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        snapshot("set-11-info-menu")
        about.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.about"].waitForExistence(timeout: 5))
        snapshot("set-11-about")
        goBack(app)

        // SET-02: Dark re-themes the app at once; System follows the device again.
        let dark = app.buttons["settings.appearance.dark"]
        scrollTo(dark, in: app)
        dark.tap()
        snapshot("set-02-appearance-dark")
        app.buttons["settings.appearance.system"].tap()
        snapshot("set-02-appearance-system")

        // SET-03: the haptics switch.
        XCTAssertTrue(app.switches["settings.haptics"].exists)

        // SET-04: Log out asks first, then returns to sign-in.
        let logOut = app.buttons["account.signOut"]
        scrollTo(logOut, in: app)
        logOut.tap()
        let confirm = app.buttons["account.signOut.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("set-04-log-out")
        confirm.tap()
        let password = app.secureTextFields["signin.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))

        // SET-10: sign in again, then remove the Account from this device: back to Server entry.
        password.tap()
        password.typeText(credentials.password)
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.buttons["drawer.open"].firstMatch.waitForExistence(timeout: 20))
        openSettings(app)
        app.buttons["settings.row.dataPrivacy"].tap()
        let remove = app.buttons["account.removeFromDevice"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        scrollTo(remove, in: app)
        remove.tap()
        let confirmRemoval = app.buttons
            .matching(NSPredicate(format: "label == 'Remove from this device' AND identifier != 'account.removeFromDevice'"))
            .firstMatch
        XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 5))
        confirmRemoval.tap()
        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        // The Settings sheet's own back button (on iPad the split view has navigation bars too).
        app.descendants(matching: .any)["settings.sheet"].navigationBars.buttons.element(boundBy: 0).tap()
        // Back on the Settings page (its Close button); on iPad's shorter sheet the Account card
        // may have scrolled away.
        XCTAssertTrue(app.buttons["settings.close"].firstMatch.waitForExistence(timeout: 5))
    }

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

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    @MainActor
    private func signIn(_ app: XCUIApplication, url: String, email: String, password: String) {
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
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        // The new-chat home, not just a drawer button: the model list has one too while the
        // Account loads, and a tap there can be lost when the home replaces it.
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func waitForValue(_ value: String?, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value ?? "")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForValue(not value: String?, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value != %@", value ?? "")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}

/// Minimal REST access for setup and cleanup. Only touches "[theseus-test]" Chats it creates and
/// the Account's own `theseus` settings namespace.
private struct SettingsLiveServer: Sendable {
    static let testPrefix = "[theseus-test]"
    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> SettingsLiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return SettingsLiveServer(url: url, token: token)
    }

    func createSharedChat(title: String) async throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let messages: [String: Any] = [
            "m1": ["id": "m1", "parentId": NSNull(), "childrenIds": ["m2"], "role": "user",
                   "content": "Plan a short walk", "timestamp": now],
            "m2": ["id": "m2", "parentId": "m1", "childrenIds": [], "role": "assistant",
                   "content": "**Route:** the park loop, about *30 minutes*.", "done": true, "timestamp": now],
        ]
        let chat: [String: Any] = [
            "chat": ["title": title, "models": [], "history": ["messages": messages, "currentId": "m2"], "messages": []],
        ]
        let created = try await Self.request(
            url.appending(path: "api/v1/chats/new"), method: "POST",
            body: try JSONSerialization.data(withJSONObject: chat), token: token
        )
        guard let id = (created as? [String: Any])?["id"] as? String else { throw URLError(.cannotParseResponse) }
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(id)/share"), method: "POST", body: Data("{}".utf8), token: token)
        return id
    }

    func unshare(chatID: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(chatID)/share"), method: "DELETE", body: nil, token: token)
    }

    func deleteChat(id: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(id)"), method: "DELETE", body: nil, token: token)
    }

    /// The walkthrough flips Capability switches back and forth; leave no `theseus` values behind.
    func resetTheseusSettings() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["theseus": NSNull()])
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
