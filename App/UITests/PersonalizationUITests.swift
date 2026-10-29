import XCTest

/// Live walkthrough of Memory & personalization (PERS-01..04) against the test Server. Opt-in like
/// the other live UI tests: needs THESEUS_INTEGRATION=1 and a filled-in .env. It saves a nickname,
/// flips the Memory switch and adds, edits and deletes "[theseus-test]" Memory entries; teardown
/// restores the nickname, Instructions and Memory switch and deletes every "[theseus-test]" entry.
/// It never changes the Account's full name and never confirms "Forget all memory".
final class PersonalizationUITests: XCTestCase {
    private var credentials: (url: String, email: String, password: String)?
    private var server: PersonalizationLiveServer?
    private var original: PersonalizationLiveServer.Snapshot?

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The personalization walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        credentials = (url, email, password)
        let server = try await PersonalizationLiveServer.signIn(url: try XCTUnwrap(URL(string: url)), email: email, password: password)
        original = try await server.snapshot()
        self.server = server
    }

    override func tearDown() async throws {
        guard let server else { return }
        if let original { try? await server.restore(original) }
        try? await server.deleteTestMemories()
        try? await server.signOut()
    }

    @MainActor
    func testPersonalizationWalkthrough() throws {
        let credentials = try XCTUnwrap(credentials)
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: credentials.url, email: credentials.email, password: credentials.password)
        openSettings(app)

        // PERS-01: Profile shows Full name and Nickname; the check fills once something changes.
        app.buttons["settings.row.profile"].tap()
        let nickname = app.textFields["profile.nickname"]
        XCTAssertTrue(nickname.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["profile.fullName"].waitForValue(not: "", timeout: 10))
        snapshot("pers-01-profile")
        nickname.tap()
        nickname.clearText()
        nickname.typeText("Theseus Tester")
        snapshot("pers-01-profile-changed")
        let save = app.buttons["personalization.save"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForEnabled(false, timeout: 10), "saved: the check is empty again")
        goBack(app)

        // PERS-02: the Instructions page shows the Instructions shared with the web app.
        app.buttons["settings.row.instructions"].tap()
        XCTAssertTrue(app.textViews["instructions.editor"].waitForExistence(timeout: 10))
        snapshot("pers-02-instructions")
        goBack(app)

        // PERS-03: Capabilities > Memory: the switch and "View your memory".
        app.buttons["settings.row.capabilities"].tap()
        let toggle = app.switches["memory.toggle"]
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let initial = toggle.value as? String
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(toggle.waitForValue(not: initial, timeout: 5))
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(toggle.waitForValue(initial, timeout: 5))
        snapshot("pers-03-capabilities-memory")

        // PERS-04: the Memory summary sheet: add, edit and delete "[theseus-test]" entries.
        app.buttons["memory.view"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["memory.summary"].waitForExistence(timeout: 10))
        let emptyAdd = app.buttons["memory.empty.add"]
        if emptyAdd.waitForExistence(timeout: 5) {
            snapshot("pers-04-memory-empty")
            emptyAdd.tap()
        } else {
            app.buttons["memory.edit"].tap()
            app.buttons["memory.add"].tap()
        }
        addMemory(app, content: "[theseus-test] Prefers metric units and short answers", topic: "preferences", snapshotName: "pers-04-memory-add")

        if !app.buttons["memory.add"].exists { app.buttons["memory.edit"].tap() }
        app.buttons["memory.add"].tap()
        addMemory(app, content: "[theseus-test] Is building a native Open WebUI client in SwiftUI", topic: "work/projects")
        app.buttons["memory.edit"].tap()
        XCTAssertTrue(app.staticTexts["Work › Projects"].waitForExistence(timeout: 5))
        snapshot("pers-04-memory-summary")

        app.buttons["memory.edit"].tap()
        XCTAssertTrue(app.buttons["memory.add"].waitForExistence(timeout: 5))
        snapshot("pers-04-memory-editing")
        let entry = app.staticTexts["[theseus-test] Prefers metric units and short answers"]
        entry.tap()
        let content = app.textViews["memory.editor.content"].exists
            ? app.textViews["memory.editor.content"] : app.textFields["memory.editor.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        // The editor focuses itself with the cursor at the end; tapping could select a word.
        XCTAssertTrue(content.waitForKeyboardFocus(timeout: 5))
        content.typeText(" in English")
        snapshot("pers-04-memory-edit")
        app.buttons["personalization.save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["[theseus-test] Prefers metric units and short answers in English"].waitForExistence(timeout: 10))

        let forgetAll = app.buttons["memory.forgetAll"]
        scrollTo(forgetAll, in: app)
        forgetAll.tap()
        XCTAssertTrue(app.buttons["memory.forgetAll.confirm"].firstMatch.waitForExistence(timeout: 5))
        snapshot("pers-04-forget-all-confirm")
        // Never wipe the real Memory: dismiss the dialog and delete the test entries one by one.
        app.swipeDown(velocity: .slow)
        if app.buttons["memory.forgetAll.confirm"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        // The list re-renders after each delete, so re-query every time and only tap a hittable button
        // (tapping a stale match fails with "No matches found"). Teardown deletes any leftovers.
        for _ in 0..<10 {
            let delete = app.buttons["memory.entry.delete"].firstMatch
            guard delete.waitForExistence(timeout: 3) else { break }
            guard delete.isHittable else { usleep(300_000); continue }
            delete.tap()
            usleep(500_000)
        }
        app.buttons["memory.close"].firstMatch.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor
    private func addMemory(_ app: XCUIApplication, content: String, topic: String, snapshotName: String? = nil) {
        let field = app.textViews["memory.editor.content"].exists
            ? app.textViews["memory.editor.content"] : app.textFields["memory.editor.content"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(content)
        let topicField = app.textFields["memory.editor.topic"]
        topicField.tap()
        topicField.typeText(topic)
        if let snapshotName { snapshot(snapshotName) }
        app.buttons["personalization.save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[content].waitForExistence(timeout: 10))
    }

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

    func waitForEnabled(_ enabled: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled))
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }

    func clearText() {
        guard let current = value as? String, !current.isEmpty, current != placeholderValue else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
}

/// Minimal REST access for setup and cleanup: the Account's own settings keys this walkthrough
/// touches (`ui.system`, `ui.memory`, `theseus.profile`) and "[theseus-test]" Memory entries.
private struct PersonalizationLiveServer: Sendable {
    static let testPrefix = "[theseus-test]"

    struct Snapshot: Sendable {
        let instructions: String?
        let memory: Bool?
        let profileJSON: Data?
    }

    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> PersonalizationLiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return PersonalizationLiveServer(url: url, token: token)
    }

    func snapshot() async throws -> Snapshot {
        var settingsURL = url.appending(path: "api/v1/users/user/settings")
        settingsURL.append(queryItems: [URLQueryItem(name: "raw", value: "true")])
        let settings = try await Self.request(settingsURL, method: "GET", body: nil, token: token) as? [String: Any]
        let ui = settings?["ui"] as? [String: Any]
        let profile = (settings?["theseus"] as? [String: Any])?["profile"] as? [String: Any]
        return Snapshot(
            instructions: ui?["system"] as? String,
            memory: ui?["memory"] as? Bool,
            profileJSON: try profile.map { try JSONSerialization.data(withJSONObject: $0) }
        )
    }

    /// Puts back exactly the keys the walkthrough may change (`ui` keys are patched one by one).
    func restore(_ snapshot: Snapshot) async throws {
        let profile: Any = try snapshot.profileJSON.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let ui: [String: Any] = ["system": snapshot.instructions ?? NSNull(), "memory": snapshot.memory ?? NSNull()]
        var settingsURL = url.appending(path: "api/v1/users/user/settings")
        settingsURL.append(queryItems: [URLQueryItem(name: "raw", value: "true")])
        let current = try await Self.request(settingsURL, method: "GET", body: nil, token: token) as? [String: Any]
        var theseus = current?["theseus"] as? [String: Any] ?? [:]
        theseus["profile"] = profile
        let body = try JSONSerialization.data(withJSONObject: ["ui": ui, "theseus": theseus])
        _ = try await Self.request(url.appending(path: "api/v1/users/user/settings/update"), method: "POST", body: body, token: token)
    }

    func deleteTestMemories() async throws {
        let entries = try await Self.request(url.appending(path: "api/v1/memories/"), method: "GET", body: nil, token: token) as? [[String: Any]] ?? []
        for entry in entries {
            guard let id = entry["id"] as? String, (entry["content"] as? String)?.hasPrefix(Self.testPrefix) == true else { continue }
            _ = try await Self.request(url.appending(path: "api/v1/memories/\(id)"), method: "DELETE", body: nil, token: token)
        }
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
