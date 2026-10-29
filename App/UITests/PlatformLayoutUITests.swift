import XCTest

/// Live walkthrough of the iPad layout (PLAT-05) against the test Server (opt-in): the persistent
/// sidebar and its Hide / Show button in landscape and portrait, and the keyboard shortcuts
/// ⌘N, ⌘, and ⌘⇧O. The `[theseus-test]` Chat it sends is deleted at the end.
@MainActor
final class PlatformLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testRegularWidthSidebarAndKeyboardShortcuts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        guard app.usesSidebarLayout else {
            throw XCTSkip("The persistent sidebar and hardware-keyboard shortcuts are the iPad layout; iPhone keeps the drawer")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)

        let field = app.descendants(matching: .any)["composer.field"]
        if !field.waitForExistence(timeout: 20) { app.typeKey("n", modifierFlags: .command) }
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        // The sidebar is there without opening anything; the header button hides and shows it.
        let account = app.buttons["drawer.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(account.isHittable, "the sidebar shows next to the Chat")
        sleep(1)
        snapshot("01-sidebar-landscape")
        let toggle = app.buttons["drawer.open"].firstMatch
        XCTAssertEqual(toggle.label, "Hide sidebar")
        toggle.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: account)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Hide sidebar hides it")
        sleep(1)
        snapshot("02-sidebar-hidden")
        XCTAssertEqual(app.buttons["drawer.open"].firstMatch.label, "Show sidebar")
        app.buttons["drawer.open"].firstMatch.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: account)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "Show sidebar brings it back")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(account.isHittable, "the sidebar stays in portrait")
        snapshot("03-sidebar-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)

        // ⌘K (search Chats) isn't sent here: the Simulator itself maps ⌘K to "Toggle Software
        // Keyboard". ShellCommandTests covers what it does; the menu bar lists it.

        // ⌘N: a new Chat (from the Chats list). Return / ⇧Return need a hardware keyboard, which
        // a headless simulator doesn't have (ComposerReturnKeyTests covers them): send with the button.
        app.buttons["drawer.chats"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chats.screen"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘N starts a new Chat")
        app.chooseComposerModel("claude-haiku-5-5")
        field.tap()
        field.typeText("[theseus-test] Reply with the word ok")
        app.buttons["composer.send"].tap()
        let user = app.descendants(matching: .any)["message.user"].firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 10), "sent")
        XCTAssertTrue(app.buttons.matching(identifier: "message.copy").firstMatch.waitForExistence(timeout: 90), "the Response finished")
        sleep(1)
        snapshot("05-return-sent")

        // ⌘,: Settings.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.descendants(matching: .any)["settings.sheet"]
        // The Simulator sometimes drops the first key command after typing: press once more.
        if !settings.waitForExistence(timeout: 3) { app.typeKey(",", modifierFlags: .command) }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, opens Settings")
        sleep(1)
        snapshot("06-command-comma-settings")
        app.buttons["settings.close"].firstMatch.tap()
        sleep(1)

        // Clean up the test Chat.
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
        sleep(1)

        // ⌘⇧O: an Incognito chat, when the Server offers them.
        app.typeKey("o", modifierFlags: [.command, .shift])
        if app.descendants(matching: .any)["chat.incognito.title"].waitForExistence(timeout: 5) {
            sleep(1)
            snapshot("07-command-shift-o-incognito")
            app.typeKey("n", modifierFlags: .command)
        }
        XCUIDevice.shared.orientation = .portrait
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

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
