import XCTest

/// Live walkthrough of Home & composer, Models & effort and Attachments against the test Server
/// (opt-in). Expects a photo in the simulator's library and `[theseus-test] atlas.txt` in
/// Files → On My iPhone (see `scripts/prepare-composer-simulator`). The `[theseus-test]` Chat it
/// creates is deleted at the end.
@MainActor
final class ComposerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testComposerWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        guard !app.usesSidebarLayout else {
            throw XCTSkip("Drives the iPhone Photos and Files pickers; on iPad they present as popovers with other controls")
        }

        // System pickers follow the app's language; keep the walkthrough in English.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)

        // HOME-01: the greeting over the empty new chat, composer pinned to the bottom.
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        sleep(2)
        snapshot("01-home")

        // MODEL-01: Select model.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["modelPicker"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("02-model-picker")

        // MODEL-03: More models.
        let more = app.buttons["modelPicker.more"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            sleep(1)
            snapshot("03-more-models")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        let haiku = app.buttons["modelPicker.model.claude-haiku-5-5"]
        XCTAssertTrue(haiku.waitForExistence(timeout: 3))
        haiku.tap()
        sleep(1)

        // MODEL-02: Effort for Haiku (reasoning_effort on this Server).
        app.buttons["composer.model"].tap()
        let effort = app.buttons["modelPicker.effort"]
        if effort.waitForExistence(timeout: 3) {
            effort.tap()
            sleep(1)
            app.buttons["effort.level.medium"].tap()
            sleep(1)
            snapshot("04-effort")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
            snapshot("04b-picker-with-effort")
        }
        app.buttons["modelPicker.close"].firstMatch.tap()
        sleep(1)
        snapshot("05-chip-with-effort")

        // HOME-03: Add to Chat.
        app.buttons["composer.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["addToChat"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("06-add-to-chat")

        // ATT-02: a photo from the library (the HEIC checkerboard).
        app.buttons["addToChat.photos"].tap()
        sleep(3)
        snapshot("07-photos-picker")
        // The newest photo (the checkerboard) comes first.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        if photo.waitForExistence(timeout: 5) {
            photo.tap()
        } else {
            print("PICKER-DUMP-BEGIN\n\(app.debugDescription.prefix(6000))\nPICKER-DUMP-END")
        }
        sleep(1)
        let confirm = app.buttons.matching(NSPredicate(format: "label IN {'Add', 'Done'}")).firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        let attachment = app.descendants(matching: .any)["composer.attachment"].firstMatch
        if !attachment.waitForExistence(timeout: 10) {
            print("ATTACH-DUMP-BEGIN\n\(app.debugDescription.prefix(6000))\nATTACH-DUMP-END")
        }
        sleep(3)
        snapshot("08-photo-attached")

        // ATT-01: a document from Files → On My iPhone.
        app.buttons["composer.add"].tap()
        XCTAssertTrue(app.buttons["addToChat.files"].waitForExistence(timeout: 5))
        app.buttons["addToChat.files"].tap()
        sleep(4)
        snapshot("09-files-picker")
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'atlas'")).firstMatch
        if !file.waitForExistence(timeout: 3) {
            if app.buttons["Browse"].exists { app.buttons["Browse"].tap() }
            let onDevice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'On My'")).firstMatch
            if onDevice.waitForExistence(timeout: 5) { onDevice.tap() }
        }
        if file.waitForExistence(timeout: 5) {
            file.tap()
            sleep(1)
            let open = app.buttons["Open"]
            if open.waitForExistence(timeout: 3) { open.tap() }
        } else {
            print("FILES-DUMP-BEGIN\n\(app.debugDescription.prefix(6000))\nFILES-DUMP-END")
        }
        sleep(4)
        snapshot("10-file-attached")

        // ATT-04: send; the Message shows its photo and file card.
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("[theseus-test] What pattern and colours does the photo show, and what is the capital of Atlantis according to the document? Two short sentences.")
        let send = app.buttons["composer.send"]
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: send)
        waitForExpectations(timeout: 60)
        snapshot("11-ready-to-send")
        send.tap()
        sleep(3)
        waitUntilIdle(timeout: 120)
        app.swipeDown()
        sleep(1)
        snapshot("12-sent-with-attachments")

        let thumbnail = app.buttons["message.attachment.image"].firstMatch
        if thumbnail.waitForExistence(timeout: 5) {
            // The floating header can cover the top of the thumbnail.
            thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            sleep(2)
            snapshot("13-image-preview")
            app.buttons["attachment.preview.close"].tap()
            sleep(1)
        }

        // MODEL-04: Settings → Models.
        openSettings()
        let models = app.buttons["settings.row.models"]
        if models.waitForExistence(timeout: 10) {
            models.tap()
            sleep(2)
            snapshot("14-settings-models")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["settings.close"].firstMatch.tap()
        sleep(1)

        // Clean up the test Chat (its uploads are removed by scripts/prepare-composer-simulator --cleanup).
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // The mic starts Dictation now (VOICE-01): VoiceUITests covers it with scripted speech.
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
}
