import XCTest

/// Walkthroughs of Skills (#187) against `scripts/stub-server`. Opt-in: they need the stub
/// running and `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`. Run them once per appearance
/// (`xcrun simctl ui <udid> appearance light|dark`); restart the stub between runs, since its
/// Skills live in memory.
/// - `testWriterSkillsTour`: a user who may create Skills writes one, edits it, adds one from a
///   link, deletes it, and picks Skills for a Chat in the composer.
/// - `testReaderSkillsTour`: a user without the permission sees the explanation and shared Skills.
/// - `testAdminSkillsTour`: an admin shares a Skill with everyone in Server administration › Skills
///   and creates a shared Skill.
/// Screenshots are attachments named `NN-name` (export with `scripts/export-walkthrough-screens`).
@MainActor
final class SkillsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-theseus-ui-testing"]
    }

    private func stubURL() throws -> String {
        guard let url = environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("The Skills tours need scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        return url
    }

    // MARK: Writer

    func testWriterSkillsTour() throws {
        let url = try stubURL()
        app.launchSkippingWelcome()
        signIn(url: url, email: "writer@example.com")
        openSkills()

        // Yours ("Only you") and From <host> (shared with the writer: everyone + the Legal group).
        XCTAssertTrue(element("skills.yours.tone-check").waitForExistence(timeout: 10))
        XCTAssertTrue(element("skills.shared.brand-voice").exists)
        XCTAssertTrue(element("skills.shared.legal-review").exists)
        sleep(1)
        snapshot("01-skills-yours-and-shared")

        // Write a skill.
        addMenu("skills.add.write")
        let name = app.textFields["skillEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Meeting notes")
        let description = app.textFields["skillEditor.description"].exists
            ? app.textFields["skillEditor.description"] : app.textViews["skillEditor.description"]
        description.tap()
        description.typeText("Turn rough notes into minutes.")
        let content = app.textViews["skillEditor.content"]
        content.tap()
        content.typeText("# Minutes\n\n- List the decisions.\n- Name an owner for each action.")
        sleep(1)
        snapshot("02-editor-new")
        if app.segmentedControls["skillEditor.mode"].buttons["Preview"].exists {
            app.segmentedControls["skillEditor.mode"].buttons["Preview"].tap()
            sleep(1)
            snapshot("03-editor-preview")
            app.segmentedControls["skillEditor.mode"].buttons["Write"].tap()
        }
        app.buttons["skillEditor.save"].tap()
        let created = element("skills.yours.meeting-notes")
        XCTAssertTrue(created.waitForExistence(timeout: 10), "the new skill is listed under Yours")
        sleep(1)
        snapshot("04-created")

        // Edit it.
        created.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["skillEditor.name"].waitForExistence(timeout: 10))
        let editDescription = app.textFields["skillEditor.description"].exists
            ? app.textFields["skillEditor.description"] : app.textViews["skillEditor.description"]
        // Tap at the trailing end so the cursor lands after the text.
        editDescription.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        editDescription.typeText(" Keep it short.")
        sleep(1)
        snapshot("05-editor-edit")
        app.buttons["skillEditor.save"].tap()
        let edited = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Keep it short.'")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10), "the edit is saved")

        // Disable and enable it again.
        let toggle = app.switches["skills.toggle.meeting-notes"]
        if toggle.waitForExistence(timeout: 5) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
            sleep(1)
            snapshot("06-disabled")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        }

        // Add from a link (the stub serves a SKILL.md); the writer may import, so it's reviewed.
        addMenu("skills.add.url")
        let link = app.textFields["skillLink.field"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        link.typeText("\(url)/stub-skills/pdf-tools/SKILL.md")
        sleep(1)
        snapshot("07-add-from-link")
        app.buttons["skillLink.add"].tap()
        XCTAssertTrue(element("skillImport").waitForExistence(timeout: 15), "the import review opens")
        sleep(1)
        snapshot("08-import-review")
        app.buttons["skillImport.confirm"].tap()
        let imported = element("skills.yours.pdf-tools")
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        sleep(1)
        snapshot("09-imported")

        // Delete it, with confirmation.
        imported.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) {
            delete.tap()
            let confirm = app.buttons["skills.delete.confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            sleep(1)
            snapshot("10-delete-confirm")
            confirm.tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: imported)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the skill is deleted")
        }

        // From a .skill file: the Files importer opens.
        addMenu("skills.add.file")
        // The document picker runs out of process and takes a moment to slide in.
        let cancel = app.buttons["Cancel"].firstMatch
        _ = cancel.waitForExistence(timeout: 10)
        sleep(2)
        snapshot("11-import-file")
        if cancel.exists { cancel.tap() }
        sleep(1)

        // The composer's skill list shows both groups, and a shared Skill can be picked.
        closeSettings()
        app.buttons["composer.add"].tap()
        XCTAssertTrue(element("addToChat").waitForExistence(timeout: 5))
        let skillsRow = app.buttons["addToChat.skillsRow"].firstMatch
        if !skillsRow.waitForExistence(timeout: 3) { element("addToChat").swipeUp() }
        XCTAssertTrue(skillsRow.waitForExistence(timeout: 5))
        skillsRow.tap()
        XCTAssertTrue(app.buttons["addToChat.skill.brand-voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addToChat.skill.meeting-notes"].exists)
        sleep(1)
        snapshot("12-composer-skills")
        app.buttons["addToChat.skill.brand-voice"].tap()
        sleep(1)
        snapshot("13-composer-skill-picked")
    }

    // MARK: Reader

    func testReaderSkillsTour() throws {
        let url = try stubURL()
        app.launchSkippingWelcome()
        signIn(url: url, email: "reader@example.com")
        openSkills()
        XCTAssertTrue(element("skills.noPermission").waitForExistence(timeout: 10))
        XCTAssertTrue(element("skills.shared.brand-voice").exists)
        XCTAssertFalse(app.buttons["skills.add"].exists, "no Add button without permission")
        sleep(1)
        snapshot("20-no-permission")
    }

    // MARK: Admin

    func testAdminSkillsTour() throws {
        let url = try stubURL()
        app.launchSkippingWelcome()
        signIn(url: url, email: "user@example.com")
        openSkills()
        XCTAssertTrue(element("skills.yours.release-notes").waitForExistence(timeout: 10))
        sleep(1)
        snapshot("30-admin-skills")

        let administration = app.buttons["skills.administration"]
        app.revealInSettings(administration)
        XCTAssertTrue(administration.waitForExistence(timeout: 5))
        administration.tap()
        XCTAssertTrue(element("adminSkills.header").waitForExistence(timeout: 10))
        XCTAssertTrue(element("adminSkills.row.tone-check").waitForExistence(timeout: 10), "admins see others' private skills")
        sleep(1)
        snapshot("31-server-admin-skills")

        // Share "Release notes" with everyone.
        let sharing = app.buttons["adminSkills.sharing.release-notes"].firstMatch
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        sharing.tap()
        // Menu items carry their labels, not identifiers.
        let everyone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Everyone on'")).firstMatch
        XCTAssertTrue(everyone.waitForExistence(timeout: 5))
        sleep(1)
        snapshot("32-sharing-menu")
        everyone.tap()
        let shared = app.buttons.matching(NSPredicate(format: "identifier == 'adminSkills.sharing.release-notes' AND label CONTAINS 'Everyone'")).firstMatch
        XCTAssertTrue(shared.waitForExistence(timeout: 10), "Release notes is shared with everyone")
        sleep(1)
        snapshot("33-shared-with-everyone")

        // Create a shared skill directly.
        app.buttons["adminSkills.add"].firstMatch.tap()
        let write = app.buttons["skills.add.write"].firstMatch
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        write.tap()
        let name = app.textFields["skillEditor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("House style")
        let content = app.textViews["skillEditor.content"]
        content.tap()
        content.typeText("Use sentence case in headings.")
        // Hide the keyboard and show the Share with section.
        let hideKeyboard = app.buttons["skillEditor.format.keyboard.chevron.compact.down"].firstMatch
        if hideKeyboard.waitForExistence(timeout: 3) { hideKeyboard.tap() }
        sleep(1)
        element("skillEditor").swipeUp()
        sleep(1)
        snapshot("34-create-shared")
        app.buttons["skillEditor.save"].tap()
        XCTAssertTrue(element("adminSkills.row.house-style").waitForExistence(timeout: 10))
        sleep(1)
        snapshot("35-created-shared")
    }

    // MARK: Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func addMenu(_ item: String) {
        let add = app.buttons["skills.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let entry = app.buttons[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(item) is in the + menu")
        entry.tap()
    }

    private func openSkills() {
        XCTAssertTrue(element("composer.field").waitForExistence(timeout: 20))
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(element("settings.sheet").waitForExistence(timeout: 5))
        let row = app.buttons["settings.row.skills"]
        app.revealInSettings(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("settings.skills").waitForExistence(timeout: 10))
    }

    private func closeSettings() {
        app.tapBack()
        let close = app.buttons["settings.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        sleep(1)
    }

    private func signIn(url: String, email: String) {
        let address = app.textFields["server.address"]
        let newChat = element("composer.field")
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
            emailField.typeText(email)
            let passwordField = app.secureTextFields["signin.password"]
            if !passwordField.exists { emailField.typeText("\n") }
            XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
            passwordField.tap()
            passwordField.typeText("theseus")
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
