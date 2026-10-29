import XCTest

/// PLAT-06: the main flow at an accessibility Dynamic Type size, driven by the VoiceOver
/// identifiers and labels, with Xcode's accessibility audit on every screen (contrast, hit
/// regions, clipped text, Dynamic Type, missing descriptions). Live against the test Server
/// (opt-in); the `[theseus-test]` Chat it sends is deleted at the end.
@MainActor
final class AccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!
    /// Every issue the audits found, for the report attachment.
    private var findings: [String] = []

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testMainFlowAtAccessibilitySize() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            // The largest-but-one accessibility text size.
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
            "-theseus-scripted-speech",
        ]
        app.launchEnvironment["THESEUS_SCRIPTED_SPEECH"] = "[theseus-test] Say hello in three words"
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)

        // Home: the composer and its icon buttons carry VoiceOver labels.
        let field = app.descendants(matching: .any)["composer.field"]
        if !field.waitForExistence(timeout: 20) { app.buttons["chat.new"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertEqual(app.buttons["composer.add"].label, "Add to chat")
        XCTAssertEqual(app.buttons["drawer.open"].firstMatch.label, app.usesSidebarLayout ? "Hide sidebar" : "Open sidebar")
        audit("01-home")

        // Add to Chat.
        app.buttons["composer.add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["addToChat"].waitForExistence(timeout: 5))
        sleep(1)
        audit("02-add-to-chat", sheet: "addToChat")
        app.buttons["addToChat.close"].firstMatch.tap()
        sleep(1)

        // Select model.
        app.buttons["composer.model"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["modelPicker"].waitForExistence(timeout: 5))
        sleep(1)
        audit("03-model-picker", sheet: "modelPicker")
        if app.buttons["modelPicker.model.claude-haiku-5-5"].exists {
            app.buttons["modelPicker.model.claude-haiku-5-5"].tap()
        } else {
            app.buttons["modelPicker.close"].firstMatch.tap()
        }
        sleep(1)

        // Send: the transcript reads the Message, then the Response, then its actions.
        send("[theseus-test] Reply with one short sentence about tea.")
        waitUntilIdle()
        let user = app.descendants(matching: .any)["message.user"].firstMatch
        let response = app.descendants(matching: .any)["message.response"].firstMatch
        let copy = app.buttons.matching(identifier: "message.copy").firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 30))
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertEqual(copy.label, "Copy")
        XCTAssertTrue(user.exists)
        assertReadingOrder(["message.user", "message.response", "message.copy"])
        audit("04-conversation")

        // Voice mode over the conversation, then delete the test Chat.
        let voice = app.buttons["composer.voice"]
        if voice.waitForExistence(timeout: 5) {
            voice.tap()
            XCTAssertTrue(app.descendants(matching: .any)["voice.mode"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard over Voice mode (#131)")
            sleep(2)
            audit("05-voice-mode", container: "voice.mode")
            app.buttons["voice.end"].tap()
            sleep(1)
            if app.buttons["voiceEnded.dismiss"].waitForExistence(timeout: 3) { app.buttons["voiceEnded.dismiss"].tap() }
        }
        let menu = app.buttons["chat.menu"].firstMatch
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
            sleep(1)
            audit("06-chat-menu")
            app.buttons["chat.menu.delete"].tap()
            let confirm = app.buttons["chat.menu.deleteConfirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the delete confirmation shows")
            confirm.tap()
            XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 10), "deleted: back on the home")
        }
        sleep(1)

        // The drawer and the Chats list.
        app.openSidebar()
        let chats = app.buttons["drawer.chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        sleep(1)
        audit("07-drawer")
        chats.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chats.list"].waitForExistence(timeout: 10))
        sleep(1)
        audit("08-chats-list")

        // Projects, when the Server has folders.
        app.openSidebar()
        let projects = app.buttons["drawer.projects"]
        if projects.waitForExistence(timeout: 5) {
            sleep(1)
            projects.tap()
            sleep(2)
            audit("09-projects")
            app.openSidebar()
        }

        // Settings.
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        sleep(1)
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
        sleep(1)
        audit("10-settings", sheet: "settings.sheet")
        app.buttons["settings.close"].firstMatch.tap()
        sleep(1)

        let report = XCTAttachment(string: findings.isEmpty ? "No issues" : findings.joined(separator: "\n"))
        report.name = "accessibility-audit.txt"
        report.lifetime = .keepAlways
        add(report)
    }

    // MARK: Audit

    /// Runs Xcode's accessibility audit on the screen showing now and fails on every issue that
    /// isn't tolerated (see `isTolerated`). `container`: the element the screen lives in when it
    /// covers another one (Voice mode over the Chat); issues outside it are about covered views.
    /// `sheet`: the presented sheet's identifier; its edges clip content like the screen's do.
    private func audit(_ screen: String, container: String? = nil, sheet: String? = nil) {
        snapshot(screen)
        // Floating chrome that scrolled content passes under (the composer, the header, pills).
        let chrome = ["composer", "drawer.open", "chat.title", "chat.new", "chat.menu", "chat.incognito",
                      "drawer.newChat", "drawer.account", "chats.newChat", "chats.search"]
            .map { app.descendants(matching: .any)[$0].firstMatch }
            .filter(\.exists)
            .map(\.frame)
            + app.searchFields.allElementsBoundByIndex.map(\.frame)
        let inside = container.map { id in
            let elements = app.descendants(matching: .any)[id].descendants(matching: .any).allElementsBoundByIndex
            return (ids: Set(elements.map(\.identifier)), labels: Set(elements.map(\.label)))
        }
        // The model chip: a filled capsule inside its 44 pt hit target (see `isTolerated`).
        let modelChip = app.buttons["composer.model"].firstMatch
        let chipFrame = modelChip.exists ? modelChip.frame : nil
        let screenFrame = sheet.map { app.descendants(matching: .any)[$0].firstMatch }.flatMap { $0.exists ? $0.frame : nil } ?? app.frame
        do {
            try app.performAccessibilityAudit(for: .all) { [self] issue in
                // A snapshot, not live queries: the element may be gone by now.
                let element = try? issue.element?.snapshot()
                let id = element?.identifier ?? ""
                let label = element?.label ?? ""
                let frame = element?.frame ?? .zero
                let tolerated = Self.isTolerated(
                    issue, type: element?.elementType, id: id, label: label, frame: frame, chrome: chrome, screen: screenFrame,
                    modelChip: chipFrame,
                    isCovered: inside.map { id.isEmpty ? !$0.labels.contains(label) : !$0.ids.contains(id) } ?? false
                )
                let kind = element.map { "type=\($0.elementType.rawValue) frame=\($0.frame)" } ?? "gone"
                findings.append("\(screen) · \(tolerated ? "tolerated" : "FAILED") · \(Self.name(of: issue.auditType)) · id=\(id) label=\(label) \(kind) · \(issue.compactDescription)")
                return tolerated
            }
        } catch {
            XCTFail("\(screen): the audit couldn't run: \(error)")
        }
    }

    /// Issues the audit reports that aren't defects:
    /// - system UI (the keyboard, the status bar) and views covered by a full-screen overlay;
    /// - contrast and clipping of scrolled content passing under floating chrome (the audit
    ///   samples the overlap) or the screen edge, and of filled capsule pills (it samples the
    ///   canvas outside the capsule);
    /// - the floating header title: fixed-size chrome like a navigation bar, capped at the first
    ///   accessibility size, one line, with the Large Content Viewer and the full title for VoiceOver.
    /// - the contrast of the composer's model chip (BRAND-03): its plaque text sits on a
    ///   `recessedSurface` capsule inside a 44 pt hit target on the white composer, and the audit
    ///   samples the composer outside the capsule (like the capsule pills above). `textPrimary` on
    ///   `recessedSurface` is checked at 4.5:1 or better by `DesignTokenTests`.
    private static func isTolerated(
        _ issue: XCUIAccessibilityAuditIssue, type: XCUIElement.ElementType?, id: String, label: String,
        frame: CGRect, chrome: [CGRect], screen: CGRect, modelChip: CGRect? = nil, isCovered: Bool
    ) -> Bool {
        guard let type else { return true }
        if [.key, .keyboard, .statusBar].contains(type) || isCovered { return true }
        let visual: [XCUIAccessibilityAuditType] = [.contrast, .textClipped]
        if visual.contains(issue.auditType) {
            // The header and the composer fade the content next to them: 24 pt beyond their frames.
            let underChrome = chrome.contains { $0 != frame && $0.insetBy(dx: 0, dy: -24).intersects(frame) && !$0.contains(frame) }
            let atEdge = !screen.insetBy(dx: 0, dy: 1).contains(frame)
            let isPill = id == "drawer.newChat" || id == "chats.newChat" || label == "New chat"
            if underChrome || atEdge || isPill { return true }
        }
        if id == "chat.title", [.contrast, .textClipped, .dynamicType].contains(issue.auditType) { return true }
        if issue.auditType == .contrast, let modelChip, modelChip.insetBy(dx: -1, dy: -1).contains(frame) { return true }
        // Sidebar Chat titles wrap without a line limit at the accessibility sizes; the audit
        // still flags a line that fills the sidebar's width (checked in 07-drawer on iPad).
        if issue.auditType == .textClipped, id.hasPrefix("drawer.chat.") { return true }
        // List-row Labels the audit reports as clipped although they lay out in full (checked
        // in the 02-add-to-chat and 09-settings screenshots).
        if [.textClipped, .dynamicType].contains(issue.auditType), verifiedListRows.contains(label) { return true }
        // Capped chrome (header buttons, the composer's button row) by design.
        if issue.auditType == .dynamicType,
           id.hasPrefix("composer.") || id.hasPrefix("chat.") || id == "drawer.open" || chrome.contains(where: { $0.contains(frame) }) {
            return true
        }
        return false
    }

    private static let verifiedListRows: Set<String> = ["Camera", "Photos", "Files", "Switch account"]

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "description"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "other(\(type.rawValue))"
        }
    }

    /// `identifiers` appear in this order in the accessibility tree (VoiceOver's reading order).
    private func assertReadingOrder(_ identifiers: [String]) {
        let all = app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier)
        var cursor = all.startIndex
        for identifier in identifiers {
            guard let index = all[cursor...].firstIndex(of: identifier) else {
                XCTFail("\(identifier) isn't read after \(identifiers.prefix { $0 != identifier })")
                return
            }
            cursor = index
        }
    }

    // MARK: Helpers

    private func send(_ prompt: String) {
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(prompt)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.label, "Send")
        send.tap()
    }

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        _ = stop.waitForExistence(timeout: 5)
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
        sleep(2)
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

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
