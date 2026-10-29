import XCTest

/// Live walkthrough of the Platform deep links (PLAT-03) against the test Server (opt-in, like the
/// other walkthroughs): `theseus://` URLs open a prepared new Chat, send a prompt, start the
/// camera and Voice mode, and open the Chats list and a saved Chat. Its `[theseus-test]` Chats
/// are deleted at the end. Screenshots are kept as attachments of the result bundle.
@MainActor
final class PlatformUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testDeepLinkWalkthrough() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty, let server = URL(string: url),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        let marker = "platform-\(UUID().uuidString.prefix(8).lowercased())"
        defer {
            Task { try? await Self.deleteChats(server: server, email: email, password: password, text: marker) }
        }

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-scripted-speech"]
        // Voice mode sends what it "hears": mark it so the cleanup below finds that Chat too.
        app.launchEnvironment["THESEUS_SCRIPTED_SPEECH"] = "[theseus-test] \(marker): Say hi in two words"
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let anyField = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(anyField.waitForExistence(timeout: 30), "signed in on a new Chat")

        // A prompt link fills a new Chat's composer without sending it.
        let draft = "[theseus-test] \(marker): Reply with OK only."
        try openLink("theseus://new?prompt=\(draft.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
        XCTAssertTrue(waitForValue(of: composerField, containing: marker), "the link's prompt is in the composer")
        XCTAssertTrue(app.descendants(matching: .any)["conversation.greeting"].exists, "a new Chat")
        snapshot("01-prompt-link")
        app.chooseComposerModel("claude-haiku-5-5")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 30), "the sent Chat is saved")
        waitUntilIdle()

        // `send=1` sends right away (with the model used last) and shows the saved Chat.
        let question = "[theseus-test] \(marker): What is 2 + 3? Reply with the number only."
        try openLink("theseus://new?send=1&prompt=\(question.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
        let sentBubble = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "What is 2 + 3")).firstMatch
        XCTAssertTrue(sentBubble.waitForExistence(timeout: 30), "the prompt was sent")
        waitUntilIdle()
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 10))
        snapshot("02-send-link")

        // The camera link opens the camera, or says why it can't (the simulator has none).
        try openLink("theseus://new?start=camera")
        let notice = app.descendants(matching: .any)["composer.notice"]
        let camera = app.buttons["DismissButton"]
        let cameraOrNotice = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in camera.exists || notice.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cameraOrNotice], timeout: 15), .completed, "the camera opened, or a notice says why not")
        snapshot("03-camera-link")
        if camera.exists { camera.tap() }

        // Voice mode (VOICE-03) opens over a new Chat; a later link ends it.
        try openLink("theseus://voice")
        let endVoice = app.buttons["voice.end"]
        XCTAssertTrue(endVoice.waitForExistence(timeout: 15) || notice.exists, "Voice mode started")
        sleep(1)
        snapshot("04-voice-link")

        // The Chats list, then a saved Chat by id.
        try openLink("theseus://chats")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        _ = row.waitForExistence(timeout: 10)
        snapshot("05-chats-link")
        let ids = try await Self.searchChats(server: server, email: email, password: password, text: marker)
        let chatID = try XCTUnwrap(ids.first, "the walkthrough's Chats are on the Server")
        try openLink("theseus://chat/\(chatID)")
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["message.response"].firstMatch.waitForExistence(timeout: 15))
        snapshot("06-chat-link")

        try await Self.deleteChats(server: server, email: email, password: password, text: marker)
    }

    /// PLAT-01: the Quick chat widget's buttons open Theseus. Needs the widget on the simulator's
    /// home screen (add it once by hand); skips otherwise.
    func testHomeScreenWidgetOpensANewChat() throws {
        guard ProcessInfo.processInfo.environment["THESEUS_OWUI_URL"]?.isEmpty == false else {
            throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env")
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-scripted-speech"]
        app.launchEnvironment["THESEUS_SCRIPTED_SPEECH"] = "[theseus-test] dictated from the widget"
        app.launchSkippingWelcome()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30), "signed in")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dictate = springboard.buttons["Dictate"]
        var pages = 0
        while !dictate.waitForExistence(timeout: 1), pages < 3 {
            springboard.swipeLeft()
            pages += 1
        }
        guard dictate.exists else { throw XCTSkip("Add the Theseus Quick chat widget to the home screen first") }
        snapshot("07-widget")
        dictate.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the widget opened Theseus")
        // Dictation (VOICE-01): its first-use intro or the recording bar.
        let intro = app.descendants(matching: .any)["dictationIntro"]
        let recording = app.buttons["dictation.confirm"]
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in intro.exists || recording.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed, "the widget's mic started Dictation")
        snapshot("08-widget-dictate")
        XCUIDevice.shared.press(.home)
        let chat = springboard.buttons["New chat"]
        if chat.waitForExistence(timeout: 5) {
            chat.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(app.descendants(matching: .any)["conversation.greeting"].waitForExistence(timeout: 10))
            snapshot("09-widget-chat")
        }
    }

    /// PLAT-04: share a web page from Safari into Theseus; a new Chat opens with the link and the
    /// note in its composer (nothing is sent).
    func testShareExtensionStartsANewChat() throws {
        guard ProcessInfo.processInfo.environment["THESEUS_OWUI_URL"]?.isEmpty == false else {
            throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env")
        }
        guard !app.usesSidebarLayout else {
            throw XCTSkip("Drives Safari's iPhone toolbar and share sheet; iPad Safari lays them out differently")
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-scripted-speech"]
        app.launchEnvironment["THESEUS_SCRIPTED_SPEECH"] = "[theseus-test] dictated from the widget"
        app.launchSkippingWelcome()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30), "signed in")

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let page = try XCTUnwrap(URL(string: "https://www.swift.org/about/"))
        XCUIDevice.shared.system.open(page)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        let more = safari.buttons["MoreMenuButton"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let share = safari.buttons["ShareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        let theseus = safari.cells.matching(NSPredicate(format: "identifier == 'shareCell' AND label == 'Theseus'")).firstMatch
        XCTAssertTrue(theseus.waitForExistence(timeout: 10), "Theseus is offered in the share sheet")
        theseus.tap()

        // The extension's sheet: what's shared, the Account, an optional message.
        let send = safari.buttons["share.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the Share extension opened")
        XCTAssertTrue(safari.staticTexts["share.account"].waitForExistence(timeout: 5))
        let note = safari.textFields["share.note"].exists ? safari.textFields["share.note"] : safari.textViews["share.note"]
        if note.waitForExistence(timeout: 3) {
            note.tap()
            note.typeText("What is this page about?")
        }
        snapshot("10-share-extension")
        send.tap()

        // Theseus opens on a new Chat holding the link and the note.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the Share extension opened Theseus")
        XCTAssertTrue(waitForValue(of: composerField, containing: "swift.org"), "the link is in the composer")
        XCTAssertTrue(waitForValue(of: composerField, containing: "What is this page about?"))
        snapshot("11-shared-chat")
    }

    // MARK: Helpers

    private var composerField: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    private func openLink(_ string: String) throws {
        let url = try XCTUnwrap(URL(string: string))
        app.open(url)
        // Opening a URL can surface the "Open in Theseus?" confirmation the first time.
        // (The simulator's own language decides the button's title.)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN {'Open', 'Öffnen'}")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let field = composerField
            if field.exists, (field.value as? String)?.contains(text) == true { return true }
            usleep(300_000)
        }
        return false
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

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        sleep(1)
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

    private nonisolated static func token(server: URL, email: String, password: String) async throws -> String {
        var signIn = URLRequest(url: server.appending(path: "api/v1/auths/signin"))
        signIn.httpMethod = "POST"
        signIn.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, _) = try await URLSession.shared.data(for: signIn)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String ?? ""
    }

    /// The ids of the Account's Chats whose title or Messages contain `text`.
    private nonisolated static func searchChats(server: URL, email: String, password: String, text: String) async throws -> [String] {
        let token = try await token(server: server, email: email, password: password)
        var components = URLComponents(url: server.appending(path: "api/v1/chats/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let searchURL = components?.url else { return [] }
        var search = URLRequest(url: searchURL)
        search.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: search)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }
    }

    private nonisolated static func deleteChats(server: URL, email: String, password: String, text: String) async throws {
        let token = try await token(server: server, email: email, password: password)
        for id in try await searchChats(server: server, email: email, password: password, text: text) {
            var delete = URLRequest(url: server.appending(path: "api/v1/chats/\(id)"))
            delete.httpMethod = "DELETE"
            delete.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try await URLSession.shared.data(for: delete)
        }
    }
}
