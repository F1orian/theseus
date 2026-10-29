import XCTest

/// Live walkthroughs of the Artifacts area against the real test Server (opt-in, like the other
/// walkthroughs). ART-01…03: one `[theseus-test]` Chat gets a web page, a revision of it, a diagram
/// and an image. ART-04: seeded Chats fill the library. Screenshots are attached to the result
/// bundle, and the Chats are deleted at the end.
@MainActor
final class ArtifactsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: SeedServer?

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        // Only the library walkthrough seeds Chats; it deletes them even when it fails.
        try? await server?.deleteSeeded()
    }

    @MainActor
    func testArtifactsWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        let composer = app.descendants(matching: .any)["composer.field"]
        if !composer.waitForExistence(timeout: 20) {
            app.buttons["chat.new"].firstMatch.tap()
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // Haiku follows formatting instructions reliably and is fast.
        app.chooseComposerModel("claude-haiku-5-5")
        // Artifacts come from fenced code blocks; with the sandbox on, the model may write files
        // instead (ADR 0120), so this walkthrough runs without Code execution.
        app.buttons["composer.add"].tap()
        let codeExecution = app.switches["addToChat.toggle.code_interpreter"]
        if codeExecution.waitForExistence(timeout: 5), (codeExecution.value as? String) == "1" {
            codeExecution.switches.firstMatch.exists ? codeExecution.switches.firstMatch.tap() : codeExecution.tap()
        }
        app.buttons["addToChat.close"].firstMatch.tap()
        sleep(1)

        // ART-01: a web page streams into a card ("Writing…"), with the pill at the top.
        send("[theseus-test] Build a small single-file HTML page titled \"Tip Calculator\" (use a <title> tag) with an input for the bill, a slider for the tip percentage and the computed total. Inline CSS and JS only, no external resources. Reply with one short sentence, then the whole page in one fenced html code block.")
        let card = app.buttons.matching(identifier: "artifact.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        snapshot("01-card-writing")
        waitUntilIdle()
        XCTAssertTrue(app.buttons["artifacts.pill"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["artifacts.pill"].label, "1 artifact")
        snapshot("02-card-and-pill")

        // ART-02: the viewer runs the page offline; Code shows the source; the menu copies and shares.
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
        sleep(3)
        snapshot("03-viewer-preview")
        // The page is interactive: drags inside it (a slider, a swipe) never close the viewer;
        // only the X does.
        let viewer = app.descendants(matching: .any)["artifact.viewer"]
        viewer.swipeLeft()
        viewer.swipeRight()
        viewer.swipeDown(velocity: .fast)
        sleep(1)
        XCTAssertTrue(viewer.exists, "a swipe closed the Artifact viewer")
        app.buttons["Code"].firstMatch.tap()
        sleep(1)
        snapshot("04-viewer-code")
        app.buttons["artifact.more"].tap()
        sleep(1)
        snapshot("05-viewer-menu")
        app.buttons["artifact.copy"].firstMatch.tap()
        // The caption confirms the copy for a moment ("Copied to the clipboard.").
        snapshot("06-copied")
        app.buttons["artifact.close"].tap()
        sleep(1)

        // ART-03: "make it pink" becomes Version 2 of the same Artifact.
        send("[theseus-test] Make it pink: change the colour scheme of the Tip Calculator to pink. Keep the same <title>. Reply with one short sentence, then the whole updated page in one fenced html code block.")
        waitUntilIdle()
        let version2 = app.buttons.matching(NSPredicate(format: "identifier == 'artifact.card' AND label CONTAINS 'Version 2'")).firstMatch
        XCTAssertTrue(version2.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["artifacts.pill"].label, "2 artifacts")
        snapshot("07-version-2-card")
        version2.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
        sleep(3)
        snapshot("08-viewer-version-2")
        app.buttons["artifact.versions"].tap()
        let version1 = app.buttons["Version 1"].firstMatch
        XCTAssertTrue(version1.waitForExistence(timeout: 5))
        snapshot("09-version-picker")
        version1.tap()
        sleep(3)
        snapshot("10-viewer-version-1")
        app.buttons["artifact.close"].tap()
        sleep(1)

        // A Mermaid diagram, drawn offline with the bundled runtime.
        send("[theseus-test] Show the steps of making tea as a mermaid flowchart (graph TD, 5 nodes) in a fenced mermaid code block, after one short sentence.")
        waitUntilIdle()
        let diagram = app.buttons.matching(NSPredicate(format: "identifier == 'artifact.card' AND label CONTAINS 'Diagram'")).firstMatch
        XCTAssertTrue(diagram.waitForExistence(timeout: 10))
        diagram.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
        sleep(4)
        snapshot("11-viewer-diagram")
        app.buttons["artifact.close"].tap()
        sleep(1)

        // An SVG image.
        send("[theseus-test] Draw a simple SVG icon of a sun (a circle with 8 rays), 120x120, with a <title>Sun icon</title>. Reply with one sentence and the SVG in a fenced svg code block.")
        waitUntilIdle()
        let image = app.buttons.matching(NSPredicate(format: "identifier == 'artifact.card' AND label CONTAINS 'Image'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        snapshot("12-image-card")
        image.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("13-viewer-image")
        app.buttons["artifact.close"].tap()
        sleep(1)

        // The pill lists the Chat's Artifacts, newest first.
        app.buttons["artifacts.pill"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifacts.chatList"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("14-chat-artifacts")
        app.buttons["Close"].firstMatch.tap()
        sleep(1)

        // ART-04: Drawer › Artifacts collects them across Chats; long-press leads back to the Chat.
        let chatTitle = app.staticTexts["chat.title"].firstMatch.label
        app.openSidebar()
        let artifactsRow = app.buttons["drawer.artifacts"]
        XCTAssertTrue(artifactsRow.waitForExistence(timeout: 5))
        artifactsRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifacts.library"].waitForExistence(timeout: 5))
        let item = app.buttons.matching(NSPredicate(format: "identifier == 'artifacts.library.item' AND label CONTAINS 'Sun icon'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 120))
        sleep(1)
        snapshot("15-library")
        item.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("16-library-viewer")
        app.buttons["artifact.close"].tap()
        sleep(1)
        item.press(forDuration: 1.2)
        let openChat = app.buttons["Open chat"].firstMatch
        XCTAssertTrue(openChat.waitForExistence(timeout: 5))
        openChat.tap()
        XCTAssertTrue(app.buttons["artifacts.pill"].waitForExistence(timeout: 20))
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

    // MARK: ART-04 library (#180)

    /// Drawer › Artifacts with one Artifact of every kind, seeded through the REST API (exact
    /// content, not model-written), plus a Chat imported from Claude: each opens from the library
    /// and, for the fragment and the import, from its Chat's card.
    @MainActor
    func testLibraryRendersEveryKind() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The live walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        let server = try await SeedServer(url: url, email: email, password: password)
        self.server = server
        try await server.seed(SeedServer.samples)

        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        XCTAssertTrue(app.buttons["drawer.open"].firstMatch.waitForExistence(timeout: 30) || app.buttons["drawer.account"].exists)
        openLibrary()
        let library = app.descendants(matching: .any)["artifacts.library"]
        // The seeded Chats are new: pull to refresh until the last one shows.
        let newest = item(SeedServer.samples.last!)
        let deadline = Date().addingTimeInterval(240)
        while !newest.exists, Date() < deadline {
            library.swipeDown()
            _ = newest.waitForExistence(timeout: 30)
        }
        XCTAssertTrue(newest.exists, "the seeded Artifacts never reached the library")
        sleep(1)
        snapshot("lib-00-grid")

        for (index, sample) in SeedServer.samples.enumerated() {
            let cell = item(sample)
            guard let title = sample.expectedTitle else {
                // #180: a pasted `<script>` snippet showed up as a blank "Web page".
                XCTAssertFalse(cell.exists, "\(sample.name) shouldn't be an Artifact")
                continue
            }
            XCTAssertTrue(cell.waitForExistence(timeout: 5), "no library item for \(sample.name)")
            XCTAssertTrue(cell.label.hasPrefix(title + ", " + sample.typeLabel), "unexpected item \(cell.label)")
            if !cell.isHittable { library.swipeUp() }
            cell.tap()
            XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
            sleep(3)
            snapshot(String(format: "lib-%02d-%@", index + 1, sample.slug))
            if sample.checksCanvas { assertBrowserCanvas(sample.name) }
            app.buttons["artifact.close"].tap()
            sleep(1)
        }

        // The same Artifacts from their Chats' cards: the viewer is shared, so library-only
        // defects and renderer defects show apart.
        for sample in SeedServer.samples where sample.opensFromChat {
            let cell = item(sample)
            if !cell.isHittable { library.swipeDown() }
            cell.press(forDuration: 1.2)
            let openChat = app.buttons["Open chat"].firstMatch
            XCTAssertTrue(openChat.waitForExistence(timeout: 5))
            openChat.tap()
            let card = app.buttons.matching(NSPredicate(format: "identifier == 'artifact.card' AND label BEGINSWITH %@", sample.expectedTitle ?? "")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 20), "no card for \(sample.name) in its Chat")
            // #180: imported Chats showed their `<details>` serialization as text.
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '<details'")).firstMatch.exists, "raw <details> markup in the transcript")
            snapshot("chat-\(sample.slug)-transcript")
            card.tap()
            XCTAssertTrue(app.descendants(matching: .any)["artifact.viewer"].waitForExistence(timeout: 5))
            sleep(3)
            snapshot("chat-\(sample.slug)-viewer")
            if sample.checksCanvas { assertBrowserCanvas(sample.name) }
            app.buttons["artifact.close"].tap()
            sleep(1)
            openLibrary()
        }
    }

    /// #180: a page without its own background must sit on a white, browser-like canvas, also in
    /// dark mode (it was drawn on the clear web view over the app's dark background).
    @MainActor
    private func assertBrowserCanvas(_ name: String) {
        let web = app.descendants(matching: .any)["artifact.webView"].firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 5), "no web view for \(name)")
        // The page's content sits at the top; the bottom of the view is bare canvas.
        let frame = web.frame
        let brightness = XCUIScreen.main.screenshot().brightness(at: CGPoint(x: frame.midX, y: frame.maxY - 24))
        XCTAssertGreaterThan(brightness ?? 0, 0.9, "\(name) isn't drawn on a light canvas")
    }

    @MainActor
    private func openLibrary() {
        app.openSidebar()
        let artifactsRow = app.buttons["drawer.artifacts"]
        XCTAssertTrue(artifactsRow.waitForExistence(timeout: 10))
        artifactsRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["artifacts.library"].waitForExistence(timeout: 5))
    }

    /// The library item of `sample`'s Chat (its label ends with "from <Chat title>").
    private func item(_ sample: SeedServer.Sample) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'artifacts.library.item' AND label ENDSWITH %@", "from " + SeedServer.prefix + sample.name)).firstMatch
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
            if let value = emailField.value as? String, !value.isEmpty, value != "Email" {
                // Clear anything typed before.
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
