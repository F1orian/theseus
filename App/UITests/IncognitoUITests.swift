import XCTest

/// Live walkthrough of Incognito chats (INCOG-01) against the test Server (opt-in, like the other
/// walkthroughs). Two turns in an Incognito chat, then leave it; afterwards the Server must hold
/// no Chat with the walkthrough's marker. Screenshots are kept as attachments of the result bundle.
@MainActor
final class IncognitoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testIncognitoWalkthrough() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty, let server = URL(string: url),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        let marker = "incognito-\(UUID().uuidString.prefix(8).lowercased())"

        // System pickers follow the app's language; keep the walkthrough in English.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // INCOG-01: the ghost button switches the new Chat to Incognito.
        let ghost = app.buttons["chat.incognito"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 10), "the test Account may use Incognito chats")
        ghost.tap()
        XCTAssertTrue(app.staticTexts["chat.incognito.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["incognito.notice"].exists)
        XCTAssertTrue(app.buttons["chat.incognito.leave"].exists)
        XCTAssertFalse(greeting.exists)
        snapshot("01-incognito-home")
        app.chooseComposerModel("claude-haiku-5-5")

        // Two turns: the second can only be answered with the first one's history.
        let codeWord = "kestrel\(Int.random(in: 1000...9999))"
        send("[theseus-test] \(marker): Remember the code word \(codeWord). Reply with OK only.")
        waitUntilIdle()
        snapshot("02-incognito-answer")
        send("[theseus-test] What was the code word? Reply with the word only.")
        waitUntilIdle()
        let responses = app.descendants(matching: .any).matching(identifier: "message.response")
        XCTAssertEqual(responses.count, 2)
        // A finished Response's prose is a text view (#175): its words are its value.
        let recalled = responses.element(boundBy: 1).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", codeWord, codeWord))
        XCTAssertGreaterThan(recalled.count, 0, "the second turn saw the first")
        // Photos travel inline (nothing uploads); files aren't offered. The walkthrough drives
        // the iPhone Photos picker; on iPad it's a popover with other controls.
        if !app.usesSidebarLayout {
            app.buttons["composer.add"].tap()
            XCTAssertTrue(app.buttons["addToChat.photos"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["addToChat.files"].exists, "Incognito chats can't take files")
            app.buttons["addToChat.photos"].tap()
            let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
            if photo.waitForExistence(timeout: 8) {
                photo.tap()
                let confirm = app.buttons.matching(NSPredicate(format: "label IN {'Add', 'Done'}")).firstMatch
                if confirm.waitForExistence(timeout: 3) { confirm.tap() }
                XCTAssertTrue(app.descendants(matching: .any)["composer.attachment"].firstMatch.waitForExistence(timeout: 10))
                snapshot("03a-incognito-photo")
                send("[theseus-test] Name the two colours of the attached checkerboard photo, two words.")
                waitUntilIdle()
                XCTAssertEqual(responses.count, 3)
                // A finished Response's prose is a text view (#175): its words are its value.
                let pattern = ".*(orange|brown|red|terracotta|coral|salmon|copper|black|dark|grey|gray|charcoal).*"
                let colours = responses.element(boundBy: 2).descendants(matching: .any).matching(NSPredicate(
                    format: "label MATCHES[c] %@ OR value MATCHES[c] %@", pattern, pattern
                ))
                XCTAssertGreaterThan(colours.count, 0, "the model saw the inline photo")
            } else {
                // The simulator has no photo yet (scripts/prepare-composer-simulator seeds one).
                app.buttons["Cancel"].firstMatch.tap()
            }
        }
        XCTAssertTrue(app.staticTexts["chat.incognito.title"].exists, "still Incognito after sending")
        XCTAssertFalse(app.buttons["chat.menu"].exists, "no Chat menu for a Chat that isn't saved")
        snapshot("03-incognito-follow-up")

        // Nothing shows up in the drawer.
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.newChat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'code word'")).firstMatch.exists)
        snapshot("04-drawer")
        app.buttons["drawer.newChat"].tap()

        // Back on a saved new Chat; the X leaves Incognito too.
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        app.buttons["chat.incognito"].tap()
        XCTAssertTrue(app.buttons["chat.incognito.leave"].waitForExistence(timeout: 5))
        app.buttons["chat.incognito.leave"].tap()
        XCTAssertTrue(greeting.waitForExistence(timeout: 5))
        snapshot("05-left-incognito")

        // The Server kept nothing.
        let found = try await Self.searchChats(server: server, email: email, password: password, text: marker)
        XCTAssertEqual(found, [], "an Incognito chat was saved")
    }

    // MARK: Helpers

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

    private func send(_ prompt: String) {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let responses = app.responseCount
        send.tap()
        XCTAssertTrue(app.sendWentThrough(responsesBefore: responses))
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

    /// The ids of the Account's Chats whose title or Messages contain `text`.
    private nonisolated static func searchChats(server: URL, email: String, password: String, text: String) async throws -> [String] {
        var signIn = URLRequest(url: server.appending(path: "api/v1/auths/signin"))
        signIn.httpMethod = "POST"
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (tokenData, _) = try await URLSession.shared.data(for: signIn)
        let token = (try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])?["token"] as? String ?? ""
        var components = URLComponents(url: server.appending(path: "api/v1/chats/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let searchURL = components?.url else { return [] }
        var search = URLRequest(url: searchURL)
        search.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: search)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }
    }
}
