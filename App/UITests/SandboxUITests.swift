import XCTest

/// Live walkthrough of the Open Terminal area (epic #139) against the real test Server (opt-in, like
/// the other walkthroughs). One `[theseus-test]` Chat uses the Server's sandbox with harmless
/// commands inside its own `theseus-test-…` folder: a spreadsheet and a CSV are created and shown,
/// commands run (one fails on purpose), the file opens in Quick Look, and the Chat's files are
/// browsed. The folder and the Chat are deleted at the end.
@MainActor
final class SandboxUITests: XCTestCase {
    private var app: XCUIApplication!
    /// A folder of this run only, so parallel runs on the shared sandbox never touch each other.
    private let folder = "theseus-test-\(UUID().uuidString.prefix(6).lowercased())"

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    @MainActor
    func testSandboxWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        // System sheets (Quick Look) label their buttons in the device language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let composer = app.descendants(matching: .any)["composer.field"]
        if !composer.waitForExistence(timeout: 20) {
            app.buttons["chat.new"].firstMatch.tap()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        app.chooseComposerModel("claude-haiku-5-5")

        // OT-01: Add to Chat offers Code execution, on by default, because the model has a sandbox.
        app.buttons["composer.add"].tap()
        let codeExecution = app.switches["addToChat.toggle.code_interpreter"]
        XCTAssertTrue(codeExecution.waitForExistence(timeout: 5), "No Code execution switch")
        XCTAssertEqual(codeExecution.value as? String, "1")
        snapshot("01-add-to-chat-code-execution")
        app.swipeDown(velocity: .fast)
        sleep(1)

        // OT-01…03: the model works in the sandbox; runs and the created file render as cards.
        send("[theseus-test] Use the sandbox. Create the folder \(folder). With python3 and openpyxl, create \(folder)/planets.xlsx with the columns Planet and Moons and three planets. Then run these as separate run_command calls: `ls -la \(folder)` and `ls \(folder)/missing.txt` (that one fails, it's expected). Finally show me planets.xlsx with display_file. Reply in one short sentence.")
        let run = app.buttons.matching(identifier: "sandbox.run").firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 120), "No run card")
        snapshot("02-run-streaming")
        waitUntilIdle(timeout: 300)
        let file = app.buttons.matching(identifier: "sandbox.file").firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "No file card for planets.xlsx")
        XCTAssertTrue(file.label.contains("planets.xlsx"), file.label)
        snapshot("03-runs-and-file")

        // OT-02: a run expands to its command and output; the failing one shows its exit code.
        let failed = app.buttons.matching(NSPredicate(format: "identifier == 'sandbox.run' AND label CONTAINS 'missing.txt'")).firstMatch
        if failed.waitForExistence(timeout: 5) {
            XCTAssertTrue(failed.label.contains("Exit"), failed.label)
            failed.tap()
            XCTAssertTrue(app.staticTexts["sandbox.run.output"].firstMatch.waitForExistence(timeout: 5))
            sleep(1)
            snapshot("04-run-expanded")
            failed.tap()
        }

        // OT-03: the file opens (fetched through the Server's proxy). A spreadsheet gets the
        // phone-width preview instead of Quick Look's shrunken one (#143).
        file.tap()
        let preview = app.descendants(matching: .any)["spreadsheet.preview"].firstMatch
        let opened = preview.waitForExistence(timeout: 30)
        sleep(4)
        snapshot("05-quick-look")
        if !opened { dumpHierarchy("05-quick-look") }
        XCTAssertTrue(opened, "The spreadsheet preview didn't open")
        // The sheet's cells render at a readable size: "Planet" is a real web text element.
        XCTAssertTrue(app.webViews.staticTexts["Planet"].firstMatch.waitForExistence(timeout: 10), "No readable sheet")
        let cell = app.webViews.staticTexts["Planet"].firstMatch
        XCTAssertGreaterThanOrEqual(cell.frame.height, 16, "the sheet still renders shrunken: \(cell.frame)")
        app.buttons["spreadsheet.close"].firstMatch.tap()
        sleep(1)

        // OT-04: the Chat's files, from the Chat menu.
        app.buttons["chat.menu"].firstMatch.tap()
        let filesItem = app.buttons["chat.menu.files"]
        let hasFiles = filesItem.waitForExistence(timeout: 5)
        if !hasFiles { dumpHierarchy("06-chat-menu") }
        XCTAssertTrue(hasFiles, "No Files in the Chat menu")
        filesItem.tap()
        let browser = app.descendants(matching: .any)["sandbox.browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 10))
        let notice = app.buttons["sandbox.browser.noticeDismiss"]
        if notice.waitForExistence(timeout: 3) {
            snapshot("06-files-notice")
            notice.tap()
        }
        let folderRow = app.buttons.matching(NSPredicate(format: "identifier == 'sandbox.browser.entry' AND label CONTAINS %@", folder)).firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 15), "The run's folder isn't listed")
        snapshot("07-files-root")
        folderRow.tap()
        let xlsxRow = app.buttons.matching(NSPredicate(format: "identifier == 'sandbox.browser.entry' AND label CONTAINS 'planets.xlsx'")).firstMatch
        XCTAssertTrue(xlsxRow.waitForExistence(timeout: 15))
        sleep(1)
        snapshot("08-files-folder")
        // Back to the root, then close the sheet.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let close = app.buttons["sandbox.browser.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        sleep(1)

        // #140: `/` in the composer lists the Server's Skills; picking one adds a chip.
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("/discern")
        let slashItem = app.buttons["composer.slash.discernment-nudge"]
        XCTAssertTrue(slashItem.waitForExistence(timeout: 10), "No Skills in the / menu")
        snapshot("09-slash-skills")
        // The scroll-to-bottom button may float over the middle of the row.
        slashItem.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["composer.skill.discernment-nudge"].waitForExistence(timeout: 5))
        snapshot("10-skill-chip")
        send("[theseus-test] In one sentence: should I double-check facts before acting on them?")
        waitUntilIdle(timeout: 120)
        // The picked Skill stays for the Chat until its chip is tapped.
        let chip = app.buttons["composer.skill.discernment-nudge"].firstMatch
        XCTAssertTrue(chip.exists)
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        sleep(1)

        // Clean up the sandbox folder (inside this run's own folder only).
        send("[theseus-test] Run `rm -rf \(folder)` in the sandbox, then reply with one word: done.")
        waitUntilIdle(timeout: 180)

        // SET-05 + #140/#141: Capabilities shows the sandbox row, follow-ups and the Server's Skills.
        let chatTitle = app.staticTexts["chat.title"].firstMatch.label
        openSettings()
        app.buttons["settings.row.capabilities"].tap()
        let sandboxRow = app.switches["capabilities.sandbox"]
        XCTAssertTrue(sandboxRow.waitForExistence(timeout: 10), "No code execution and file creation row")
        XCTAssertFalse(app.switches["capabilities.codeInterpreter"].exists, "one code execution row (ADR 0120)")
        XCTAssertTrue(app.switches["capabilities.followUps"].exists)
        sleep(1)
        snapshot("11-capabilities")
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "capabilities.skill").firstMatch.waitForExistence(timeout: 10))
        snapshot("12-capabilities-skills")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let closeSettings = app.buttons["settings.close"].firstMatch
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 5))
        closeSettings.tap()
        sleep(1)
        // Only ever delete the walkthrough's own Chat.
        XCTAssertEqual(app.staticTexts["chat.title"].firstMatch.label, chatTitle)

        // Clean up: delete the test Chat through the Chat menu (CHATS-07).
        app.buttons["chat.menu"].firstMatch.tap()
        app.buttons["chat.menu.delete"].tap()
        let confirm = app.buttons["chat.menu.deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
    }

    // MARK: Helpers

    @MainActor
    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
    }

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
            if let value = emailField.value as? String, !value.isEmpty, value != "Email" {
                emailField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            emailField.typeText(email)
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
    private func waitUntilIdle(timeout: TimeInterval = 180) {
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
        sleep(1)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Also straight to disk when asked, so a run that dies early still leaves its screens.
        if let directory = ProcessInfo.processInfo.environment["THESEUS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    private func dumpHierarchy(_ name: String) {
        if let directory = ProcessInfo.processInfo.environment["THESEUS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? app.debugDescription.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }
}
