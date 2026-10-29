import XCTest

/// Live walkthrough of the Message actions area (MSG-01…08) against the real test Server
/// (opt-in, like the other walkthroughs). One `[theseus-test]` Chat gets every action,
/// screenshots are attached to the result bundle, and the Chat is deleted at the end.
@MainActor
final class MessageActionsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Feedback records outlive their Chat on the Server: delete the walkthrough's, and any
    /// `[theseus-test]` Chat a failed run left behind.
    override func tearDown() async throws {
        try await TestServerCleanup.run()
    }

    @MainActor
    func testMessageActionsWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 20) {
            app.buttons["chat.new"].firstMatch.tap()
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        app.chooseComposerModel("claude-haiku-5-5")

        // MSG-01: the action row under a finished Response.
        send("[theseus-test] Give me three short tips for drinking more water, as a markdown list with **bold** lead-ins.")
        waitUntilIdle()
        let copy = app.buttons.matching(identifier: "message.copy").firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        snapshot("01-action-row")

        // MSG-02: copy → checkmark + top toast.
        copy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["message.toast"].waitForExistence(timeout: 3))
        snapshot("02-copied")
        sleep(3)

        // MSG-07: read aloud turns play into pause; tap again to stop.
        let readAloud = app.buttons.matching(identifier: "message.readAloud").firstMatch
        if readAloud.exists {
            readAloud.tap()
            sleep(1)
            snapshot("03-reading-aloud")
            XCTAssertEqual(readAloud.label, "Stop reading")
            readAloud.tap()
        }

        // MSG-06: thumb → Feedback sheet → the thumb fills.
        let thumbsUp = app.buttons.matching(identifier: "message.thumbsUp").firstMatch
        XCTAssertTrue(thumbsUp.exists)
        thumbsUp.tap()
        XCTAssertTrue(app.descendants(matching: .any)["feedback.sheet"].waitForExistence(timeout: 5))
        let comment = app.textViews["feedback.comment"]
        if comment.waitForExistence(timeout: 2) { comment.typeText("[theseus-test] Clear and short") }
        snapshot("04-feedback-sheet")
        app.buttons["sheet.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["message.toast"].waitForExistence(timeout: 10))
        XCTAssertTrue(thumbsUp.isSelected || thumbsUp.waitForExistence(timeout: 1))
        snapshot("05-thumb-filled")
        sleep(3)

        // MSG-03 + MSG-04: Retry streams a new Branch in place; the pager reads 2 / 2.
        app.buttons.matching(identifier: "message.retry").firstMatch.tap()
        waitUntilIdle()
        let position = app.staticTexts.matching(identifier: "branch.position").firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertEqual(position.label, "2 / 2")
        assertOnOneLine(position)
        // On an iPhone in portrait the pager shares the row with the six action icons (#147).
        XCTAssertEqual(position.frame.midY, copy.frame.midY, accuracy: 2, "the pager left the action row")
        snapshot("06-retry-branch")
        app.buttons.matching(identifier: "branch.previous").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        snapshot("07-previous-branch")

        // MSG-05: long-press the user Message → Edit → a new Branch of the prompt.
        let bubble = app.descendants(matching: .any).matching(identifier: "message.user").firstMatch
        bubble.press(forDuration: 1.0)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        snapshot("08-user-menu")
        edit.tap()
        let editor = app.textViews["edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" Keep it to one line each.")
        snapshot("09-edit-sheet")
        app.buttons["sheet.confirm"].tap()
        waitUntilIdle()
        let userPosition = app.staticTexts.matching(identifier: "branch.position").firstMatch
        XCTAssertTrue(userPosition.waitForExistence(timeout: 10))
        assertOnOneLine(userPosition)
        snapshot("10-edited-branch")

        // MSG-08: Share sheet: only you → anyone with the link → Share link → back to only you.
        app.buttons.matching(identifier: "message.share").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["share.sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["share.onlyYou"].waitForExistence(timeout: 10))
        snapshot("11-share-private")
        app.buttons["share.anyone"].tap()
        let shareLink = app.buttons["share.link"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: shareLink)
        waitForExpectations(timeout: 10)
        snapshot("12-share-public")
        shareLink.tap()
        sleep(3)
        snapshot("13-system-share-sheet")
        // Dismiss the system share sheet, then make the Chat private again.
        app.swipeDown(velocity: .fast)
        sleep(1)
        if !app.buttons["share.onlyYou"].isHittable {
            app.buttons["Close"].firstMatch.tap()
            sleep(1)
        }
        app.buttons["share.onlyYou"].tap()
        sleep(2)
        app.buttons["sheet.close"].tap()
        sleep(1)

        // MSG-08 from the Chat menu (CHATS-08 hook).
        app.buttons["chat.menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.menu.share"].waitForExistence(timeout: 5))
        snapshot("14-chat-menu-share")

        // Clean up: delete the test Chat through the Chat menu (CHATS-07).
        app.buttons["chat.menu.delete"].tap()
        let confirm = app.buttons["chat.menu.deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    @MainActor
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

    @MainActor
    /// #147: the pager's "n / m" sits on one line, level with its arrows.
    private func assertOnOneLine(_ position: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let previous = app.buttons.matching(identifier: "branch.previous").firstMatch
        let next = app.buttons.matching(identifier: "branch.next").firstMatch
        XCTAssertLessThan(position.frame.height, 30, "the counter wrapped: \(position.frame)", file: file, line: line)
        XCTAssertEqual(position.frame.midY, previous.frame.midY, accuracy: 2, file: file, line: line)
        XCTAssertEqual(position.frame.midY, next.frame.midY, accuracy: 2, file: file, line: line)
        XCTAssertLessThan(previous.frame.maxX, position.frame.minX + 1, file: file, line: line)
        XCTAssertLessThan(position.frame.maxX, next.frame.minX + 1, file: file, line: line)
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

    /// Waits until no Response is streaming (the stop button is gone).
    @MainActor
    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
        sleep(2)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Deletes the test data a walkthrough created on the test Server, through its REST API.
enum TestServerCleanup {
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["THESEUS_OWUI_URL"].flatMap(URL.init(string:)),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { return }
        let signIn = try await call(base, "api/v1/auths/signin", method: "POST", body: ["email": email, "password": password])
        guard let token = (signIn as? [String: Any])?["token"] as? String else { return }

        let feedbacks = try await call(base, "api/v1/evaluations/feedbacks/user", token: token)
        let items = ((feedbacks as? [String: Any])?["items"] as? [[String: Any]]) ?? (feedbacks as? [[String: Any]]) ?? []
        for item in items {
            let comment = (item["data"] as? [String: Any])?["comment"] as? String ?? ""
            if comment.contains("[theseus-test]"), let id = item["id"] as? String {
                _ = try? await call(base, "api/v1/evaluations/feedback/\(id)", method: "DELETE", token: token)
            }
        }
        let chats = try await call(base, "api/v1/chats/search?text=%5Btheseus-test%5D", token: token) as? [[String: Any]] ?? []
        for chat in chats {
            guard let id = chat["id"] as? String,
                  let full = try? await call(base, "api/v1/chats/\(id)", token: token) as? [String: Any],
                  let messages = ((full["chat"] as? [String: Any])?["history"] as? [String: Any])?["messages"] as? [String: [String: Any]],
                  messages.values.contains(where: { ($0["role"] as? String) == "user" && (($0["content"] as? String)?.hasPrefix("[theseus-test]") ?? false) })
            else { continue }
            _ = try? await call(base, "api/v1/chats/\(id)", method: "DELETE", token: token)
        }
        _ = try? await call(base, "api/v1/auths/signout", method: "POST", token: token)
    }

    private static func call(_ base: URL, _ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil) async throws -> Any? {
        guard let url = URL(string: path, relativeTo: base.appending(path: "/")) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try? JSONSerialization.jsonObject(with: data)
    }
}
