import XCTest

/// Live walkthrough of the Chat & streaming area against the real test Server (opt-in, like
/// `testSignInShowsModelList`). One `[theseus-test]` Chat gets every turn, screenshots are
/// attached to the result bundle, and the Chat is deleted at the end.
@MainActor
final class ChatStreamingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    @MainActor
    func testConversationWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)

        // The signed-in app opens on a new Chat (or start one from the header).
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 20) {
            app.buttons["chat.new"].firstMatch.tap()
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        snapshot("01-new-chat")
        // Haiku follows formatting instructions reliably and is fast.
        app.chooseComposerModel("claude-haiku-5-5")

        // CHAT-01/03/04/05: markdown, code, table and math, streamed.
        send("[theseus-test] Answer in markdown with: a level-2 heading, a 3-item bullet list with bold lead-ins, a 2-row table, a short fenced swift code block, the inline formula $E = mc^2$ and the display formula $$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$.")
        let response = app.descendants(matching: .any)["message.response"].firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 30))
        sleep(2)
        snapshot("02-streaming")
        waitUntilIdle()
        snapshot("03-response-bottom")
        app.swipeDown()
        sleep(1)
        snapshot("04-response-scrolled")
        let scrollDown = app.buttons["conversation.scrollToBottom"]
        if scrollDown.waitForExistence(timeout: 3) { scrollDown.tap() }

        // CHAT-02: stop keeps the partial text.
        send("[theseus-test] Write a 700-word story about a mouse solving a maze.")
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: 15))
        sleep(4)
        app.buttons["composer.stop"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["response.stopped"].waitForExistence(timeout: 20))
        waitUntilIdle()
        snapshot("05-stopped")

        // CHAT-06: Thinking (tag-based reasoning), expanded.
        send("[theseus-test] Begin your reply with the literal tag <think>, reason briefly inside it, close it with </think>, then answer: what is 17 × 23?")
        waitUntilIdle()
        let thinking = app.buttons.matching(identifier: "response.thinking").firstMatch
        if thinking.waitForExistence(timeout: 5) {
            thinking.tap()
            sleep(1)
        }
        snapshot("06-thinking")

        // CHAT-07/08: web search tool steps and Sources.
        send("[theseus-test] Search the web: what is the latest released version of Open WebUI? Cite your sources.")
        let tools = app.buttons.matching(identifier: "response.tools").firstMatch
        if tools.waitForExistence(timeout: 40) { snapshot("07-tool-activity") }
        waitUntilIdle(timeout: 240)
        snapshot("08-web-answer")
        let sources = app.buttons.matching(identifier: "response.sources").firstMatch
        if sources.waitForExistence(timeout: 5) {
            sources.tap()
            XCTAssertTrue(app.descendants(matching: .any)["sources.sheet"].waitForExistence(timeout: 5))
            sleep(1)
            snapshot("09-sources")
            app.buttons["Close"].firstMatch.tap()
            sleep(1)
        }

        // CHAT-09: clarifying questions card, answered.
        send("[theseus-test] I want to plan a weekend trip. Before answering, you MUST call the ask_user tool with exactly two questions (destination type and budget), each with 2 options. Do not answer before calling it.")
        let card = app.descendants(matching: .any)["question.card"]
        if card.waitForExistence(timeout: 90) {
            sleep(1)
            snapshot("10-clarifying-question")
            app.buttons["question.option.0"].firstMatch.tap()
            sleep(1)
            app.buttons["question.option.0"].firstMatch.tap()
            sleep(3)
            waitUntilIdle(timeout: 180)
            snapshot("11-answered")
        }

        // CHAT-11: the generated title sits in the header.
        XCTAssertFalse(app.staticTexts["chat.title"].label.isEmpty)

        // Clean up: delete the test Chat through the Chat menu (CHATS-07).
        app.buttons["chat.menu"].firstMatch.tap()
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
        sleep(1)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
