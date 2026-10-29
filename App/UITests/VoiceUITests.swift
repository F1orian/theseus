import XCTest

/// Live walkthrough of the Voice Feature area (VOICE-01…07) against the test Server (opt-in).
/// The simulator has nobody talking into its microphone, so the app runs with scripted speech
/// (`-theseus-scripted-speech`): the recogniser "hears" the phrases below, everything else (the
/// Chat, the Server's Response, on-device speech) is live. The `[theseus-test]` Chat it creates is
/// deleted at the end, and Voice settings are put back to their defaults.
@MainActor
final class VoiceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testVoiceWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-scripted-speech"]
        app.launchEnvironment["THESEUS_SCRIPTED_SPEECH"] = [
            // Dictation (VOICE-01).
            "Plan a picnic for four people",
            // Voice mode, first turn (VOICE-03).
            "[theseus-test] In two short sentences, what is a good breakfast",
        ].joined(separator: "|")
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)

        let field = app.descendants(matching: .any)["composer.field"]
        if !field.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        app.chooseComposerModel("claude-haiku-5-5")

        // VOICE-02: the Dictation intro on first use, with the Speech language list.
        let mic = app.buttons["composer.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        let intro = app.descendants(matching: .any)["dictationIntro"]
        if intro.waitForExistence(timeout: 3) {
            sleep(1)
            snapshot("01-dictation-intro")
            app.buttons["dictationIntro.language"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["speechLanguage.list"].waitForExistence(timeout: 5))
            sleep(1)
            snapshot("02-speech-language")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.buttons["dictationIntro.continue"].tap()
        }

        // VOICE-01: the recording bar with the live transcript, then the text in the composer.
        let transcript = app.staticTexts["dictation.transcript"]
        XCTAssertTrue(app.buttons["dictation.confirm"].waitForExistence(timeout: 5), "the recording bar replaces the composer")
        let heard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'picnic'"), object: transcript)
        XCTAssertEqual(XCTWaiter.wait(for: [heard], timeout: 10), .completed, "the live transcript shows")
        snapshot("03-dictation-recording")
        app.buttons["dictation.confirm"].tap()
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'picnic'"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 5), .completed, "the dictated text lands in the composer")
        sleep(1)
        snapshot("04-dictated-text")
        // Clear the draft again: the voice button only shows on an empty composer.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 5))
        app.swipeDown()

        // VOICE-06: Settings → Voice.
        openSettings()
        let voiceRow = app.buttons["settings.row.voice"]
        // Connectors and Permissions sit above Voice in the App group; scroll if it's below the fold.
        for _ in 0..<3 where !voiceRow.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(voiceRow.waitForExistence(timeout: 10))
        voiceRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voiceSettings"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("05-settings-voice")
        app.buttons["voiceSettings.mode.handsFree"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.close"].firstMatch.tap()
        sleep(1)

        // VOICE-03: Voice mode — the turn is heard, sent and the Response spoken.
        let voiceButton = app.buttons["composer.voice"]
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 5))
        voiceButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voice.mode"].waitForExistence(timeout: 5))
        // #131: entering Voice mode dismisses the keyboard.
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 3), .completed, "no keyboard over Voice mode")
        snapshot("06-voice-start")
        XCTAssertTrue(app.staticTexts["voice.transcript"].waitForExistence(timeout: 10))
        snapshot("07-voice-listening")
        XCTAssertTrue(app.staticTexts["voice.userMessage"].waitForExistence(timeout: 15), "the turn was sent")
        XCTAssertTrue(app.staticTexts["voice.response"].waitForExistence(timeout: 60), "the Response arrives")
        sleep(2)
        snapshot("08-voice-speaking")
        XCTAssertTrue(app.buttons["voice.thumbsUp"].waitForExistence(timeout: 90), "the Response finished")

        // VOICE-05: mute.
        app.buttons["voice.mute"].tap()
        XCTAssertTrue(app.staticTexts["voice.microphoneOff"].waitForExistence(timeout: 3))
        sleep(1)
        snapshot("09-voice-muted")
        app.buttons["voice.mute"].tap()

        // VOICE-06 / VOICE-04: the gear opens Voice settings; switch to push to talk.
        app.buttons["voice.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["voiceSettings"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("10-voice-settings-sheet")
        app.buttons["voiceSettings.mode.pushToTalk"].tap()
        sleep(1)
        app.buttons["voiceSettings.close"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voice.pushToTalk"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stays down after Voice settings (#131)")
        snapshot("11-push-to-talk")

        // Back to hands free (the setting roams with the Account).
        app.buttons["voice.settings"].tap()
        XCTAssertTrue(app.buttons["voiceSettings.mode.handsFree"].waitForExistence(timeout: 5))
        app.buttons["voiceSettings.mode.handsFree"].tap()
        sleep(1)
        app.buttons["voiceSettings.close"].firstMatch.tap()
        sleep(1)

        // VOICE-07: end; the banner and the exchange as ordinary Messages in the Chat.
        app.buttons["voice.end"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["voiceEnded.banner"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("12-voice-ended")
        app.buttons["voiceEnded.thumbsUp"].tap()
        let feedback = app.descendants(matching: .any)["feedback.sheet"]
        if feedback.waitForExistence(timeout: 5) {
            sleep(1)
            snapshot("13-session-feedback")
            app.buttons["sheet.close"].firstMatch.tap()
        }
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

    /// Opens Settings from the drawer's Account avatar.
    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
