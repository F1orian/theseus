import XCTest

/// Drives the app's main transitions against the live test Server so they can be re-recorded
/// (`xcrun simctl io <udid> recordVideo`) and measured (Instruments' Animation Hitches, or
/// `XCTHitchMetric` here with `THESEUS_MEASURE_HITCHES=1`). Opt-in: needs THESEUS_INTEGRATION=1
/// and a filled-in .env. See `docs/research/animation-audit.md` for how the numbers were taken.
///
/// The steps pause between transitions so each one is a clean segment of a recording. Every Chat
/// it creates is titled "[theseus-test] …" and deleted at the end.
@MainActor
final class AnimationTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: TourServer?
    private var createdChatIDs: [String] = []
    private var createdProjectIDs: [String] = []

    private var measuresHitches: Bool {
        ProcessInfo.processInfo.environment["THESEUS_MEASURE_HITCHES"] == "1"
    }

    override func setUp() async throws {
        // An async test can't be stopped at a failure: XCTest then hangs in tearDown until the
        // run is killed. The async tours keep going and fail as a whole instead.
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"].flatMap(URL.init(string:)),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The animation tour needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        server = try await TourServer.signIn(url: url, email: email, password: password)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        guard let server else { return }
        for id in createdChatIDs { try? await server.deleteChat(id: id) }
        for id in createdProjectIDs { try? await server.deleteProject(id: id) }
    }

    // MARK: Drawer

    /// The drawer: tap open and tap closed, then the edge swipe (fast and slow) and a drag closed.
    func test1Drawer() throws {
        launchSignedIn()
        settle(1.5)
        if measuresHitches {
            let options = XCTMeasureOptions()
            options.iterationCount = 3
            measure(metrics: [XCTHitchMetric(application: app)], options: options) { drawerRound() }
        } else {
            phase("drawer") {
                drawerRound()
                drawerRound()
            }
        }
    }

    private func drawerRound() {
        // Tap the header button; tap the dimmed content to close.
        app.buttons["drawer.open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["drawer.account"].waitForExistence(timeout: 5))
        settle(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        settle(1)
        // A quick flick from the left edge (velocity carries it open)…
        edge(to: 0.45, velocity: 1800)
        settle(1)
        // …a drag that crosses half way and closes again with a flick.
        drag(from: 0.9, to: 0.25, velocity: 1500)
        settle(1)
        // A slow drag open that's released past half way.
        edge(to: 0.7, velocity: 300)
        settle(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        settle(1)
        // From the middle of the screen: a rightward drag opens it…
        drag(from: 0.3, to: 0.8, velocity: 1200)
        settle(1)
        XCTAssertTrue(drawerIsOpen, "a mid-screen drag opens the drawer")
        // …and a leftward drag on the visible strip closes it.
        drag(from: 0.92, to: 0.3, velocity: 1200)
        settle(1)
        XCTAssertFalse(drawerIsOpen, "dragging the strip left closes the drawer")
    }

    private var drawerIsOpen: Bool {
        let account = app.buttons["drawer.account"]
        return account.exists && account.isHittable
    }

    // MARK: Drawer and horizontal scrollers

    /// A code block that scrolls sideways keeps its drag: scrolled right, a rightward drag scrolls
    /// it back instead of opening the drawer. A rightward drag on prose opens it; a leftward drag
    /// closes it.
    func test5DrawerVersusScrollers() async throws {
        continueAfterFailure = true
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour scrollers", turns: 2)
        createdChatIDs.append(id)
        launchSignedIn()
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        settle(2)
        // A code block on screen: a horizontal scroll view inside the transcript.
        let screen = window.frame.insetBy(dx: 0, dy: 140)
        let blocks = transcript.scrollViews.allElementsBoundByIndex
        let visible = blocks.first { screen.contains($0.frame) }
        let code = try XCTUnwrap(visible, "a code block on screen scrolls sideways")
        phase("scrollers") {
            code.swipeLeft()
            settle(1)
            XCTAssertFalse(drawerIsOpen, "scrolling code left doesn't touch the drawer")
            let start = code.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: code.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)),
                        withVelocity: XCUIGestureVelocity(400), thenHoldForDuration: 0)
            settle(1)
            XCTAssertFalse(drawerIsOpen, "dragging right in scrolled code scrolls it back, not the drawer")
            // Prose (a paragraph of the Response on screen, away from the code) opens it from
            // mid-screen.
            // A finished Response's prose is one text view per run (#175); other text is static.
            let texts = transcript.textViews.allElementsBoundByIndex + transcript.staticTexts.allElementsBoundByIndex
            guard let prose = texts.last(where: {
                screen.contains($0.frame) && !$0.frame.intersects(code.frame) && $0.frame.width > 150
            }) else { return XCTFail("no prose on screen") }
            let from = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 220, dy: 0)),
                       withVelocity: XCUIGestureVelocity(1200), thenHoldForDuration: 0)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "a rightward drag on prose opens the drawer")
            drag(from: 0.92, to: 0.3, velocity: 1200)
            settle(1)
            XCTAssertFalse(drawerIsOpen, "dragging the strip left closes it")
        }
    }

    // MARK: Back swipe

    /// In a pushed screen (a Project's detail) a rightward drag from the edge goes back, and the
    /// drawer stays shut: the navigation stack owns that gesture.
    func test6BackSwipeInPushedScreen() async throws {
        continueAfterFailure = true
        let projectID = try await server!.createProject(name: "[theseus-test] Animation tour \(UUID().uuidString.prefix(6))")
        createdProjectIDs.append(projectID)
        launchSignedIn()
        app.openSidebar()
        let projects = app.buttons["drawer.projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10), "the test Server offers Projects")
        projects.tap()
        let row = app.descendants(matching: .any)["project.row.\(projectID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let detail = app.descendants(matching: .any)["project.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        settle(1)
        phase("backswipe") {
            // From the very edge, held a moment before it moves: the iOS 27 simulator no longer
            // starts the system back swipe for a 0.05 s press 4 pt in (it failed the same way on
            // 72d09bd, where this test was added, and on main).
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.55))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
            from.press(forDuration: 0.2, thenDragTo: to, withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.1)
            settle(1.5)
            XCTAssertFalse(detail.exists && detail.isHittable, "the back swipe left the Project")
            XCTAssertFalse(drawerIsOpen, "the back swipe didn't open the drawer")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "back on the Projects list")
            // At the root of the stack, a mid-screen drag opens the drawer again.
            drag(from: 0.3, to: 0.8, velocity: 1200)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "a mid-screen drag at the root opens the drawer")
        }
    }

    // MARK: Text selection (#176)

    /// Selecting text never moves the drawer: a long press that selects a word and drags on, and a
    /// drag of the selection's handle sideways, both leave it shut. Once the selection is gone, a
    /// rightward drag on prose opens it as before.
    func test7SelectionDragKeepsDrawerShut() async throws {
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour selection", turns: 1)
        createdChatIDs.append(id)
        launchSignedIn()
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        settle(2)
        transcript.swipeDown()
        settle(1)
        let prose = transcript.textViews["response.prose"].firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 10) && prose.isHittable, "the Response's prose is on screen")
        attachScreenshot("selection-start")
        phase("selection") {
            // Long-press a word to select it, then keep dragging sideways: the selection grows.
            let word = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
            word.press(forDuration: 1.2, thenDragTo: word.withOffset(CGVector(dx: 200, dy: 0)),
                       withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.3)
            settle(1)
            attachScreenshot("selection-long-press-drag")
            XCTAssertFalse(drawerIsOpen, "a long press that turns into a selection drag doesn't move the drawer")

            // Clear it, select the paragraph's last word ("connected."), then drag the selection's
            // end handle (its knob hangs under the word's end) sideways to the right.
            prose.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
            settle(1)
            // The run ends with the list's last line, "corridor." (after the marker column).
            let lastWord = prose.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 45, dy: prose.frame.height - 10))
            lastWord.press(forDuration: 1.2)
            settle(1)
            attachScreenshot("selection-word")
            let handle = prose.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 96, dy: prose.frame.height + 4))
            handle.press(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: 200, dy: 0)),
                         withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.5)
            settle(1)
            attachScreenshot("selection-handle-drag")
            XCTAssertFalse(drawerIsOpen, "dragging the selection handle sideways doesn't move the drawer")

            // Clear the selection (a tap on the text), then a rightward drag opens it.
            prose.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.95)).tap()
            settle(1)
            attachScreenshot("selection-cleared")
            let from = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 220, dy: 0)),
                       withVelocity: XCUIGestureVelocity(1200), thenHoldForDuration: 0)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "without a selection, a rightward drag on prose opens the drawer")
        }
    }

    // MARK: Select text (#175)

    /// "Select text" in a Response's overflow opens the whole Response as one text: a selection
    /// runs from the first paragraph across the list, and Select all takes everything.
    func test8SelectTextSheet() async throws {
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour select text", turns: 1)
        createdChatIDs.append(id)
        launchSignedIn()
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let more = app.buttons.matching(identifier: "message.more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let selectText = app.buttons["Select text"].firstMatch
        XCTAssertTrue(selectText.waitForExistence(timeout: 5))
        selectText.tap()
        let text = app.textViews["selectText.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the sheet shows the Response as one text view")
        let value = text.value as? String ?? ""
        XCTAssertTrue(value.contains("Step 1") && value.contains("right whisker") && value.contains("Sense:"), value)
        XCTAssertFalse(value.contains("**") || value.contains("```"), "markdown is rendered, not shown")
        settle(1)
        phase("selecttext") {
            // Long-press a word in the first paragraph, then drag the end handle down across the
            // paragraph and into the list.
            let word = text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12))
            word.press(forDuration: 1.0)
            settle(1)
            attachScreenshot("select-text-word")
            let handle = word.withOffset(CGVector(dx: 24, dy: 12))
            handle.press(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: 60, dy: 250)),
                         withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.6)
            settle(1.5)
            attachScreenshot("select-text-multi-paragraph")
            app.buttons["selectText.selectAll"].tap()
            settle(1.5)
            attachScreenshot("select-text-all")
            app.buttons["selectText.copy"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["message.toast"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(text.exists, "Copy closes the sheet")
    }

    // MARK: The working mouse (#173)

    /// While a Response runs an Open Terminal command, the run card says what runs and the
    /// working mouse stays at the tail without a plaque (#195: one live status); once the
    /// Response finishes, it's gone.
    func test9WorkingMouseDuringTerminalRun() throws {
        launchSignedIn()
        startNewChat()
        app.chooseComposerModel("claude-haiku-5-5")
        settle(1)
        type("[theseus-test] Use the sandbox: run exactly `sleep 8; echo maze-done` with run_command (one call, wait for it), then reply with its output only.")
        phase("terminal") {
            tapSend()
            XCTAssertTrue(waitForRunningCard(timeout: 90), "the run card says Running during the run")
            XCTAssertFalse(liveStatusShownTwice(), "the tail has no RUNNING COMMAND… plaque beside the running card")
            attachScreenshot("working-mouse-running-command")
            settle(2)
            attachScreenshot("working-mouse-running-command-2")
            waitUntilIdle(timeout: 180)
        }
        settle(1)
        attachScreenshot("working-mouse-finished")
        XCTAssertFalse(app.descendants(matching: .any)["response.waiting"].exists, "a finished Response shows no mouse")
        rememberCurrentChat()
    }

    // MARK: A scene per kind of work (#185)

    /// The Response's tail plays the scene for its work: the globe with SEARCHING THE WEB… during a
    /// web search, the keyboard with RUNNING COMMAND… during an Open Terminal command, and the
    /// peek with YOUR TURN above a clarifying question, gone once it's answered. The tail
    /// indicator is captured on its own (`working-mouse-*-tail`) and on screen.
    func test15WorkingMouseScenePerWork() throws {
        launchSignedIn()
        startNewChat()
        app.chooseComposerModel("claude-haiku-5-5")
        // Web search on for this Chat (CONN-01), so the model gets `search_web`.
        app.buttons["composer.add"].tap()
        let webSearch = app.switches["addToChat.toggle.web_search"]
        XCTAssertTrue(webSearch.waitForExistence(timeout: 5))
        if (webSearch.value as? String) != "1" {
            webSearch.switches.firstMatch.exists ? webSearch.switches.firstMatch.tap() : webSearch.tap()
        }
        app.buttons["addToChat.close"].firstMatch.tap()
        settle(1)
        phase("working-mouse-thinking") {
            // Streamed Thinking is a quiet "Thinking" row; the Response's one mouse ponders at the
            // tail (THINKING…, #190). Finished, the row reads "Thought…" at the same height.
            type("[theseus-test] Think it through step by step first, then answer with the number only: 17 × 23.")
            tapSend()
            let header = app.buttons.matching(identifier: "response.thinking").firstMatch
            let streaming = app.buttons.matching(NSPredicate(format: "identifier == 'response.thinking' AND label == 'Thinking'")).firstMatch
            let start = Date()
            while !streaming.exists, Date().timeIntervalSince(start) < 60, !(header.exists && !app.buttons["composer.stop"].exists) {
                usleep(100_000)
            }
            if streaming.exists {
                let mice = app.descendants(matching: .any).matching(identifier: "response.waiting")
                XCTAssertLessThanOrEqual(mice.count, 1, "one mouse: the tail's, not one in the Thinking header too")
            }
            if header.exists {
                attachElementScreenshot(header, name: "working-mouse-thinking-streaming")
                attachScreenshot("working-mouse-thinking-streaming-screen")
                let streamingFrame = header.frame
                waitUntilIdle(timeout: 180)
                if header.exists {
                    attachElementScreenshot(header, name: "working-mouse-thinking-finished")
                    XCTAssertEqual(header.frame.height, streamingFrame.height, accuracy: 0.5, "finishing doesn't change the header's height")
                }
            } else {
                print("TOUR-NOTE no visible Thinking streamed")
                waitUntilIdle(timeout: 180)
            }
        }
        phase("working-mouse-web-search") {
            // A search can be over in a second; ask again (up to three times) until the tail is caught.
            let prompts = [
                "[theseus-test] Call search_web once for: Shannon Theseus mouse 1950. Then answer in one sentence.",
                "[theseus-test] You must call search_web for: Open WebUI release notes this month. Then answer in one sentence.",
                "[theseus-test] Call search_web twice, for: maze-solving robot history, then: micromouse competition rules. Then answer in one sentence.",
            ]
            var seen = false
            for prompt in prompts where !seen {
                type(prompt)
                tapSend()
                seen = captureTail(label: "Searching the web", name: "working-mouse-web-search", timeout: 60)
                waitUntilIdle(timeout: 180)
            }
            XCTAssertTrue(seen, "the tail shows SEARCHING THE WEB… during a web search")
        }
        phase("working-mouse-terminal") {
            // #195: the run card says what runs; the tail mouse keeps working without a plaque.
            type("[theseus-test] Use the sandbox: run exactly `sleep 8; echo maze-done` with run_command (one call, wait for it), then reply with its output only.")
            tapSend()
            XCTAssertTrue(waitForRunningCard(timeout: 90), "the run card says Running")
            XCTAssertFalse(liveStatusShownTwice(), "no RUNNING COMMAND… plaque beside the card")
            for take in 1...2 {
                attachScreenshot("working-mouse-terminal-\(take)")
                usleep(350_000)
            }
            waitUntilIdle(timeout: 180)
        }
        phase("working-mouse-your-turn") {
            type("[theseus-test] Before answering, you MUST call the ask_user tool with exactly one question (cheese or crumbs), with 2 options. Do not answer before calling it.")
            tapSend()
            let card = app.descendants(matching: .any)["question.card"]
            if card.waitForExistence(timeout: 90) {
                XCTAssertTrue(captureTail(label: "Your turn", name: "working-mouse-your-turn", timeout: 10, stopsWhenFinished: false), "the tail shows YOUR TURN above the card")
                app.buttons["question.option.0"].firstMatch.tap()
                settle(1)
                if card.exists { app.buttons["question.option.0"].firstMatch.tap() }
                let yourTurn = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'response.waiting' AND label == 'Your turn'")).firstMatch
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: yourTurn)
                XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "answering hands back to the working mouse")
                waitUntilIdle(timeout: 180)
            } else {
                print("TOUR-NOTE the model answered without ask_user; YOUR TURN not captured")
            }
        }
        settle(1)
        XCTAssertFalse(app.descendants(matching: .any)["response.waiting"].exists, "a finished Response shows no mouse")
        attachScreenshot("working-mouse-finished-all")
        rememberCurrentChat()
    }

    // MARK: One mouse per Response (#190), never hidden (#194), one live status (#195), Sources clear (#191)

    /// A reasoning model (Opus 5.5) at high effort with web search and Open Terminal interleaves Thinking,
    /// tool steps and a terminal run (reasoning → search → reasoning → fetch → reasoning → run →
    /// reasoning). Sampled about ten times a second while it runs (one accessibility snapshot and
    /// one screenshot per sample):
    /// - never more than one working mouse (`response.waiting`) and at most one live Thinking (#190);
    /// - whenever the tail's plaque is drawn, its mouse is drawn too (pixels of the indicator's
    ///   left part against the background, #194);
    /// - a live status never shows twice: the plaque and a step row or card saying the same (#195);
    /// - the Sources row never intersects the tail or a step row, and is never empty (#191).
    /// With `THESEUS_EVIDENCE_DIR` set, every fifth sample is written as `one-mouse-NNN.png`, plus
    /// every failing one, and each sample prints a `TOUR-SAMPLE` line (the strips in
    /// `.scratch/tail-fixes/`).
    func test16OneMouseOnAMultiStepSearch() throws {
        launchSignedIn()
        startNewChat()
        app.chooseComposerModel("claude-opus-5-5")
        // Effort High, so the model reasons between its tool calls.
        app.buttons["composer.model"].tap()
        let effort = app.buttons["modelPicker.effort"]
        if effort.waitForExistence(timeout: 3) {
            effort.tap()
            let high = app.buttons["effort.level.high"]
            if high.waitForExistence(timeout: 3) { high.tap() }
            settle(0.5)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle(0.5)
        } else {
            print("TOUR-NOTE no Effort control for claude-opus-5-5")
        }
        app.buttons["modelPicker.close"].firstMatch.tap()
        settle(0.5)
        app.buttons["composer.add"].tap()
        let webSearch = app.switches["addToChat.toggle.web_search"]
        XCTAssertTrue(webSearch.waitForExistence(timeout: 5))
        if (webSearch.value as? String) != "1" {
            webSearch.switches.firstMatch.exists ? webSearch.switches.firstMatch.tap() : webSearch.tap()
        }
        app.buttons["addToChat.close"].firstMatch.tap()
        settle(1)
        type("[theseus-test] Research this in steps, thinking between each step: first search the web for the latest Open WebUI release, then fetch its release notes page, then search the web for the latest Swift release, then use the sandbox to run exactly `sleep 3; echo maze-done` with run_command (wait for it), and finally give me a two-sentence comparison citing your sources. Keep the answer short.")
        tapSend()
        let stop = app.buttons["composer.stop"]
        var tally = SampleTally()
        phase("one-mouse") {
            let deadline = Date().addingTimeInterval(300)
            var running = true
            var lastStopCheck = Date()
            while running, Date() < deadline {
                let started = Date()
                sample(&tally)
                // `stop.exists` is a query of its own: once a second is enough.
                if Date().timeIntervalSince(lastStopCheck) > 1 {
                    running = stop.exists
                    lastStopCheck = Date()
                }
                let spent = Date().timeIntervalSince(started)
                if spent < 0.1 { usleep(useconds_t((0.1 - spent) * 1_000_000)) }
            }
        }
        settle(1)
        saveEvidence("one-mouse-finished")
        let mice = app.descendants(matching: .any).matching(identifier: "response.waiting")
        let liveThinking = app.buttons.matching(NSPredicate(format: "identifier == 'response.thinking' AND label == 'Thinking'"))
        let thoughts = app.buttons.matching(identifier: "response.thinking").count
        let mouseAfter = mice.count
        let thinkingAfter = liveThinking.count
        let seconds = tally.elapsed > 0 ? tally.elapsed : 1
        print("TOUR-NOTE one-mouse samples:\(tally.samples) (\(String(format: "%.1f", Double(tally.samples) / seconds)) fps) mouse checks:\(tally.mouseChecks) most mice:\(tally.mostMice) most live Thinking:\(tally.mostLiveThinking) Thinking parts:\(thoughts) sources seen:\(tally.sourcesSeen) runs seen:\(tally.runsSeen)")
        for failure in tally.failures.prefix(20) { print("TOUR-FAIL \(failure)") }
        // Asserted after sampling and cleanup, so a failing run still records its whole strip and
        // leaves no Chat behind.
        rememberCurrentChat()
        XCTAssertGreaterThan(tally.samples, 30, "the Response ran long enough to sample")
        XCTAssertGreaterThan(tally.mouseChecks, 10, "the tail's mouse was checked while it showed")
        XCTAssertLessThanOrEqual(tally.mostMice, 1, "one working mouse at most, at every sample")
        XCTAssertLessThanOrEqual(tally.mostLiveThinking, 1, "only the live tail's Thinking is still thinking")
        XCTAssertEqual(tally.hiddenMouse, 0, "the tail's plaque is never drawn without its mouse (#194)")
        XCTAssertEqual(tally.statusTwice, 0, "a live status never shows twice (#195)")
        XCTAssertEqual(tally.sourcesOverlap, 0, "the Sources row never intersects the tail or a step row (#191)")
        XCTAssertEqual(tally.emptySources, 0, "the Sources row is never empty (#191)")
        XCTAssertEqual(mouseAfter, 0, "a finished Response shows no mouse")
        XCTAssertEqual(thinkingAfter, 0, "every finished Thinking part reads Thought")
        if thoughts < 2 { print("TOUR-NOTE the model interleaved fewer than two Thinking parts") }
        if tally.runsSeen == 0 { print("TOUR-NOTE the model didn't run the terminal command") }
    }

    private struct SampleTally {
        var samples = 0
        var started: Date?
        var elapsed: TimeInterval = 0
        var mouseChecks = 0
        var mostMice = 0
        var mostLiveThinking = 0
        var hiddenMouse = 0
        var statusTwice = 0
        var sourcesOverlap = 0
        var emptySources = 0
        var sourcesSeen = 0
        var runsSeen = 0
        var failures: [String] = []
    }

    /// The step rows and cards the Sources row must keep clear of.
    private static let stepIdentifiers: Set<String> = [
        "response.waiting", "response.tools", "response.thinking", "response.status", "response.code",
        "sandbox.run", "sandbox.fileStep",
    ]

    /// One sample of test16: the accessibility tree and the screen, at the same moment.
    private func sample(_ tally: inout SampleTally) {
        guard let tree = try? app.snapshot() else { return }
        let shot = XCUIScreen.main.screenshot()
        let now = Date()
        if tally.started == nil { tally.started = now }
        tally.elapsed = now.timeIntervalSince(tally.started ?? now)
        let index = tally.samples
        tally.samples += 1
        var elements: [(id: String, label: String, frame: CGRect)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if !node.identifier.isEmpty { elements.append((node.identifier, node.label, node.frame)) }
            for child in node.children { walk(child) }
        }
        walk(tree)
        let tails = elements.filter { $0.id == "response.waiting" }
        let liveThinking = elements.filter { $0.id == "response.thinking" && $0.label == "Thinking" }
        tally.mostMice = max(tally.mostMice, tails.count)
        tally.mostLiveThinking = max(tally.mostLiveThinking, liveThinking.count)
        var notes: [String] = []

        // #194: the mouse is drawn whenever the plaque is.
        let pixels = ScreenPixels(shot)
        var mouseNote = "no-tail"
        if let tail = tails.first, tail.frame.width > 80, let pixels {
            let mouse = CGRect(x: tail.frame.minX, y: tail.frame.midY - 14, width: 68, height: 28)
            let plaque = CGRect(x: tail.frame.minX + 80, y: tail.frame.midY - 10, width: min(tail.frame.width - 80, 200), height: 20)
            // The empty end of the tail's row, right of the plaque.
            let backgroundX = min(tail.frame.maxX + 24, tree.frame.maxX - 8)
            let background = pixels.background(near: CGRect(x: backgroundX - 30, y: tail.frame.minY, width: 36, height: tail.frame.height))
            let mouseInk = pixels.inkCount(in: mouse, against: background)
            let plaqueInk = pixels.inkCount(in: plaque, against: background)
            mouseNote = "m\(mouseInk)-p\(plaqueInk)"
            if plaqueInk > 40 {
                tally.mouseChecks += 1
                if mouseInk < 60 {
                    tally.hiddenMouse += 1
                    notes.append("HIDDEN")
                    tally.failures.append("sample \(index): plaque '\(tail.label)' drawn (\(plaqueInk)) but its mouse isn't (\(mouseInk))")
                }
            }
        }

        // #195: one live status.
        if let tail = tails.first, !tail.label.isEmpty {
            let twice = !liveThinking.isEmpty
                || elements.contains { ($0.id == "response.tools" || $0.id == "response.status") && $0.label == tail.label }
                || elements.contains { $0.id == "sandbox.run" && $0.label.hasPrefix("Running") }
            if twice {
                tally.statusTwice += 1
                notes.append("TWICE")
                tally.failures.append("sample \(index): '\(tail.label)' shows twice")
            }
        }
        if elements.contains(where: { $0.id == "sandbox.run" && $0.label.hasPrefix("Running") }) { tally.runsSeen += 1 }

        // #191: the Sources row keeps clear of the tail and the step rows, and says something.
        for sources in elements where sources.id == "response.sources" {
            tally.sourcesSeen += 1
            if sources.label.trimmingCharacters(in: .whitespaces).isEmpty {
                tally.emptySources += 1
                notes.append("EMPTY")
                tally.failures.append("sample \(index): an empty Sources row")
            }
            let row = sources.frame.insetBy(dx: 0, dy: 1)
            for other in elements where Self.stepIdentifiers.contains(other.id) && other.frame.intersects(row) {
                // A row that's arriving is laid out before it fades in (once the rows below have
                // moved, #191): it only overlaps if it's drawn. Look at its part clear of the pill.
                guard let pixels else { continue }
                var clear = other.frame
                if other.frame.midY < row.midY { clear.size.height = max(0, row.minY - other.frame.minY) } else {
                    clear = CGRect(x: other.frame.minX, y: row.maxY, width: other.frame.width, height: max(0, other.frame.maxY - row.maxY))
                }
                if clear.height < 4 { clear = other.frame }
                let background = pixels.background(near: sources.frame.insetBy(dx: -40, dy: 0))
                let ink = pixels.inkCount(in: clear, against: background)
                guard ink > 40 else { continue }
                tally.sourcesOverlap += 1
                notes.append("OVERLAP")
                tally.failures.append("sample \(index): Sources \(sources.frame) intersects \(other.id) \(other.frame), drawn (\(ink))")
            }
        }
        print("TOUR-SAMPLE \(index) t:\(String(format: "%.2f", tally.elapsed)) mice:\(tails.count) tail:'\(tails.first?.label ?? "")' \(mouseNote) liveThinking:\(liveThinking.count) \(notes.joined(separator: ","))")
        if index.isMultiple(of: 5) || !notes.isEmpty {
            let suffix = notes.isEmpty ? "" : "-" + notes.joined(separator: "-")
            saveEvidence(String(format: "one-mouse-%03d", index) + "-\(mouseNote)\(suffix)", shot: shot)
        }
    }

    /// Writes a screenshot to `THESEUS_EVIDENCE_DIR` only (no attachment), for sampled strips.
    private func saveEvidence(_ name: String, shot: XCUIScreenshot) {
        guard let directory = ProcessInfo.processInfo.environment["THESEUS_EVIDENCE_DIR"], !directory.isEmpty else { return }
        try? shot.pngRepresentation.write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }

    /// Waits (polling every 0.1 s) for an Open Terminal run card that says Running.
    private func waitForRunningCard(timeout: TimeInterval) -> Bool {
        let card = app.buttons.matching(NSPredicate(format: "identifier == 'sandbox.run' AND label BEGINSWITH 'Running'")).firstMatch
        let start = Date()
        while !card.exists {
            if Date().timeIntervalSince(start) > timeout { return false }
            usleep(100_000)
        }
        return true
    }

    /// #195: whether a live status shows twice right now: the tail's plaque and a step row or
    /// card saying the same (a live "Thinking" row, a tool row titled like the plaque, a running
    /// run card beside a plaque).
    private func liveStatusShownTwice() -> Bool {
        let tail = app.descendants(matching: .any).matching(identifier: "response.waiting").firstMatch
        guard tail.exists else { return false }
        let plaque = tail.label
        guard !plaque.isEmpty else { return false }
        if app.buttons.matching(NSPredicate(format: "identifier == 'response.thinking' AND label == 'Thinking'")).firstMatch.exists { return true }
        if app.buttons.matching(NSPredicate(format: "identifier == 'response.tools' AND label == %@", plaque)).firstMatch.exists { return true }
        if app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'response.status' AND label == %@", plaque)).firstMatch.exists { return true }
        if app.buttons.matching(NSPredicate(format: "identifier == 'sandbox.run' AND label BEGINSWITH 'Running'")).firstMatch.exists { return true }
        return false
    }

    /// Writes a screenshot to `THESEUS_EVIDENCE_DIR` only (no attachment), for sampled strips.
    private func saveEvidence(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["THESEUS_EVIDENCE_DIR"], !directory.isEmpty else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }

    /// Waits for the tail indicator labelled `label`, polling every 0.1 s (a tool call can be
    /// over in a second, and `waitForExistence` looks once a second), then captures the screen
    /// and the tail alone, twice a few frames apart. Returns whether it was seen.
    @discardableResult
    private func captureTail(label: String, name: String, timeout: TimeInterval, stopsWhenFinished: Bool = true) -> Bool {
        let tail = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'response.waiting' AND label == %@", label)).firstMatch
        let start = Date()
        while !tail.exists {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > timeout { return false }
            // After a grace period, a finished Response (no stop button) won't show it any more.
            if stopsWhenFinished, elapsed > 5, !app.buttons["composer.stop"].exists { return false }
            usleep(100_000)
        }
        for take in 1...2 {
            attachScreenshot("\(name)-\(take)")
            if tail.exists { attachElementScreenshot(tail, name: "\(name)-tail-\(take)") }
            usleep(350_000)
        }
        return true
    }

    /// Attaches the part of a screenshot that `element` covers. Cropped from one app screenshot
    /// (rather than `element.screenshot()`), so an indicator that fades out mid-capture doesn't fail
    /// the walkthrough.
    private func attachElementScreenshot(_ element: XCUIElement, name: String) {
        guard element.exists else { return }
        let frame = element.frame
        let image = app.screenshot().image
        let scale = image.scale
        let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let cropped = image.cgImage?.cropping(to: pixels) else { return }
        let tile = UIImage(cgImage: cropped, scale: scale, orientation: .up)
        let attachment = XCTAttachment(image: tile)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["THESEUS_EVIDENCE_DIR"], !directory.isEmpty, let png = tile.pngData() {
            try? png.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }

    // MARK: Petting the mouse (#174)

    /// Tapping the mouse on the home and under a Response never navigates or opens anything.
    func test10PettingTheMouse() async throws {
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour petting", turns: 1)
        createdChatIDs.append(id)
        launchSignedIn()
        startNewChat()
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        // The sitting mouse is the greeting's top-left corner (decorative: no element of its own).
        let sit = greeting.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 20))
        phase("petting") {
            for tap in 0..<4 {
                sit.tap()
                // A few quick screenshots catch the reaction's frames (8 fps).
                for frame in 0..<4 { attachScreenshot("petting-home-tap\(tap)-\(frame)") }
                usleep(600_000)
            }
            for _ in 0..<7 { sit.tap() }
            for frame in 0..<4 { attachScreenshot("petting-home-surprise-\(frame)") }
            settle(2)
            sit.press(forDuration: 0.8)
            attachScreenshot("petting-home-curl")
            settle(2.5)
            XCTAssertTrue(greeting.exists, "petting stays on the home")
            app.openSidebar()
            let row = app.buttons["drawer.chat.\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            let footer = app.descendants(matching: .any)["conversation.disclaimer"]
            XCTAssertTrue(footer.waitForExistence(timeout: 15))
            let head = footer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 13, dy: 0))
            for _ in 0..<4 {
                head.tap()
                usleep(900_000)
            }
            XCTAssertFalse(app.descendants(matching: .any)["selectText.sheet"].exists, "no message actions open")
            XCTAssertTrue(footer.isHittable)
        }
    }

    /// #175: in a finished Response, a selection made in place runs across blocks: from a word in
    /// the first paragraph, the end handle dragged down into the list selects the paragraph and
    /// two list items, and Copy puts all of it on the pasteboard.
    func test12SelectionSpansParagraphs() async throws {
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour selection span", turns: 1)
        createdChatIDs.append(id)
        launchSignedIn()
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        settle(2)
        transcript.swipeDown()
        settle(1)
        let prose = transcript.textViews["response.prose"].firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 10), "a finished Response's prose is one text view")
        let value = prose.value as? String ?? ""
        XCTAssertTrue(value.contains("Step 1") && value.contains("right whisker") && value.contains("Move:"),
                      "the heading, the paragraph and the list are one text: \(value)")
        phase("selection-span") {
            // "keeps" on the paragraph's first line (under the heading).
            let word = prose.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 130, dy: 46))
            word.press(forDuration: 1.2)
            settle(1)
            attachScreenshot("span-word")
            let handle = word.withOffset(CGVector(dx: 22, dy: 14))
            handle.press(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: 60, dy: 280)),
                         withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.6)
            settle(1.5)
            attachScreenshot("span-three-paragraphs")
            XCTAssertFalse(drawerIsOpen)
            let copy = app.menuItems["Copy"].firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 5), "the edit menu offers Copy")
            copy.tap()
            settle(1)
            // Paste into the composer to read what was copied (the runner can't read the
            // pasteboard without a permission prompt).
            let field = composerField
            field.tap()
            settle(0.5)
            field.press(forDuration: 1.0)
            let paste = app.menuItems["Paste"].firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5), "the composer offers Paste")
            paste.tap()
            settle(1)
            let copied = field.value as? String ?? ""
            XCTAssertTrue(copied.contains("whisker") && copied.contains("Sense:") && copied.contains("Decide:"),
                          "one selection spans the paragraph and two list items: \(copied)")
            attachScreenshot("span-pasted")
            clearDraft()
        }
    }

    /// #178: on the home's Today card, the painting opens the work full screen (pinch to zoom, its
    /// plaque, the museum link) and leaves the composer alone; only "Ask about it ›" fills it.
    func test13TodayArtworkOpensFullScreen() throws {
        launchSignedIn()
        startNewChat()
        let painting = app.buttons["home.today.artwork"]
        XCTAssertTrue(painting.waitForExistence(timeout: 10))
        phase("today-artwork") {
            painting.tap()
            let viewer = app.descendants(matching: .any)["artwork.viewer"]
            XCTAssertTrue(viewer.waitForExistence(timeout: 5), "the painting opens full screen")
            XCTAssertTrue(app.buttons["artwork.viewer.museum"].exists, "with a link to the museum")
            let image = app.descendants(matching: .any)["artwork.viewer.image"]
            settle(1)
            attachScreenshot("today-artwork-viewer")
            image.pinch(withScale: 2.5, velocity: 2)
            settle(1)
            attachScreenshot("today-artwork-zoomed")
            app.buttons["artwork.viewer.close"].tap()
            XCTAssertTrue(painting.waitForExistence(timeout: 5))
            settle(1)
            XCTAssertEqual((composerField.value as? String).map { $0.hasPrefix("Tell me about") }, false,
                           "the painting never fills the composer")
            app.buttons["home.today"].tap()
            settle(1)
            XCTAssertTrue((composerField.value as? String ?? "").hasPrefix("Tell me about "), "Ask about it fills the composer")
            attachScreenshot("today-asked")
            clearDraft()
        }
    }

    /// #177 as the owner hit it: on the home, type in the composer, let "Ask about it" fill it (the
    /// composer stays first responder with text and a caret), pet the mouse, then swipe from the
    /// left edge, with the keyboard up and down: the drawer opens every time.
    func test14ComposerFocusedKeepsTheDrawerSwipe() throws {
        launchSignedIn()
        startNewChat()
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        let sit = greeting.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 20))
        phase("composer-drawer") {
            type("[theseus-test] draft")
            settle(0.5)
            // A word selected in the draft doesn't hold the drawer either.
            composerField.doubleTap()
            settle(1)
            edge(to: 0.7, velocity: 600)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "a selection in the composer doesn't stop the edge swipe")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            composerField.tap()
            settle(0.5)
            app.buttons["home.today"].tap()
            settle(1)
            for _ in 0..<4 {
                sit.tap()
                usleep(400_000)
            }
            settle(1)
            attachScreenshot("composer-focused-before-swipe")
            for (index, height) in [0.3, 0.55].enumerated() {
                let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: height))
                from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: height)),
                           withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0)
                settle(1)
                XCTAssertTrue(drawerIsOpen, "with the keyboard up, the edge swipe at \(height) opens the drawer")
                attachScreenshot("composer-swipe-\(index)")
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                settle(1)
                composerField.tap()
                settle(1)
            }
            // The keyboard down, the draft kept: the edge swipe opens it too.
            greeting.swipeDown()
            settle(1)
            edge(to: 0.7, velocity: 600)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "with the keyboard down and a draft, the edge swipe opens the drawer")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            composerField.tap()
            clearDraft()
        }
    }

    /// #177: petting the home mouse (taps, the seven-tap surprise, a long press) never stops the
    /// drawer's swipe: the edge swipe and a mid-screen drag both still open it.
    func test11PettingKeepsTheDrawerSwipe() async throws {
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour petting drawer", turns: 1)
        createdChatIDs.append(id)
        launchSignedIn()
        // Leave a selection behind in a Chat, then go to the home (as on the device).
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let prose = app.scrollViews["conversation.transcript"].firstMatch.textViews["response.prose"].firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 15))
        settle(1)
        prose.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)
        settle(1)
        attachScreenshot("petting-drawer-selection-left-behind")
        app.buttons["chat.new"].firstMatch.tap()
        startNewChat()
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        let sit = greeting.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 20))
        phase("petting-drawer") {
            for _ in 0..<8 {
                sit.tap()
                usleep(150_000)
            }
            sit.press(forDuration: 0.8)
            settle(2.5)
            edge(to: 0.7, velocity: 600)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "after petting, the edge swipe opens the drawer")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            XCTAssertFalse(drawerIsOpen)
            for _ in 0..<3 {
                sit.tap()
                usleep(700_000)
            }
            settle(1)
            drag(from: 0.3, to: 0.8, velocity: 1200)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "after petting, a mid-screen drag opens the drawer")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            // A drag that starts on the mouse itself.
            sit.press(forDuration: 0.05, thenDragTo: sit.withOffset(CGVector(dx: 220, dy: 0)),
                      withVelocity: XCUIGestureVelocity(1200), thenHoldForDuration: 0)
            settle(1)
            XCTAssertTrue(drawerIsOpen, "a drag that starts on the mouse opens the drawer")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            // "Ask about it" fills the composer; the drawer still opens with a swipe.
            let today = app.descendants(matching: .any)["home.today"]
            if today.waitForExistence(timeout: 3) {
                today.tap()
                settle(1.5)
                attachScreenshot("petting-after-ask")
                edge(to: 0.7, velocity: 600)
                settle(1)
                XCTAssertTrue(drawerIsOpen, "with a filled composer, the edge swipe opens the drawer")
            }
        }
    }

    /// Attaches a screenshot; with `THESEUS_EVIDENCE_DIR` set it's also written there as a PNG.
    private func attachScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["THESEUS_EVIDENCE_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(filePath: directory).appending(path: "\(name).png"))
        }
    }

    // MARK: Streaming

    /// A new Chat: the home greeting, the user Message flying in, the waiting mark, a long streamed
    /// Response, the footer, then Thinking expand/collapse on a second turn.
    func test2Streaming() throws {
        launchSignedIn()
        startNewChat()
        app.chooseComposerModel("claude-haiku-5-5")
        settle(1)
        let prompt = "[theseus-test] Animation tour: write about 500 words on how a mouse finds the centre of a maze, in four sections with level-2 headings, one bullet list and one short table."
        if measuresHitches {
            let options = XCTMeasureOptions()
            options.iterationCount = 1
            options.invocationOptions = [.manuallyStart, .manuallyStop]
            measure(metrics: [XCTHitchMetric(application: app)], options: options) {
                type(prompt)
                startMeasuring()
                tapSend()
                waitUntilIdle(timeout: 180)
                stopMeasuring()
            }
        } else {
            type(prompt)
            phase("streaming") {
                tapSend()
                waitUntilIdle(timeout: 180)
            }
        }
        settle(2)
        // Composer growth: a multi-line draft, then cleared by sending.
        type("[theseus-test] Begin your reply with the literal tag <think>, reason briefly inside it, close it with </think>, then answer in one line: what is 17 × 23?\nThanks!")
        settle(1)
        tapSend()
        waitUntilIdle()
        let thinking = app.buttons.matching(identifier: "response.thinking").firstMatch
        if thinking.waitForExistence(timeout: 5) {
            thinking.tap()
            settle(1.2)
            thinking.tap()
            settle(1.2)
        }
        // The copy check and the "Message copied" toast.
        let copy = app.buttons.matching(identifier: "message.copy").firstMatch
        if copy.waitForExistence(timeout: 3) {
            copy.tap()
            settle(2.5)
        }
        rememberCurrentChat()
    }

    // MARK: Scrolling

    /// A long Chat (made through the API, so it's the same every run): fling up and down, the
    /// jump-to-bottom button, then the drawer over a long transcript.
    func test3Scrolling() async throws {
        continueAfterFailure = true
        let id = try await server!.createLongChat(title: "[theseus-test] Animation tour scrolling", turns: 14)
        createdChatIDs.append(id)
        launchSignedIn()
        app.openSidebar()
        let row = app.buttons["drawer.chat.\(id)"]
        if !row.waitForExistence(timeout: 10) {
            // The drawer refreshes on open; reopen once so the new Chat is listed.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            settle(1)
            app.openSidebar()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["message.response"].firstMatch.waitForExistence(timeout: 15))
        settle(2)
        if measuresHitches {
            let options = XCTMeasureOptions()
            options.iterationCount = 3
            measure(metrics: [XCTHitchMetric(application: app)], options: options) { scrollRound() }
        } else {
            phase("scrolling") {
                scrollRound()
                scrollRound()
            }
        }
        let jump = app.buttons["conversation.scrollToBottom"]
        app.swipeDown(velocity: .fast)
        settle(1)
        if jump.waitForExistence(timeout: 3) {
            jump.tap()
            settle(1.5)
        }
        app.buttons["drawer.open"].firstMatch.tap()
        settle(1)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        settle(1)
    }

    private func scrollRound() {
        let transcript = app.scrollViews["conversation.transcript"].firstMatch
        for _ in 0..<3 { transcript.swipeDown(velocity: .fast) }
        settle(0.8)
        for _ in 0..<3 { transcript.swipeUp(velocity: .fast) }
        settle(0.8)
    }

    // MARK: Composer and sheets

    /// The composer's sheets and chips: Add to Chat, Select model, the send ↔ voice morph.
    func test4Composer() throws {
        launchSignedIn()
        startNewChat()
        settle(1)
        phase("composer") { composerRound() }
    }

    private func composerRound() {
        type("Hello")
        settle(0.8)
        clearDraft()
        settle(0.8)
        let add = app.buttons["composer.add"]
        if add.waitForExistence(timeout: 5) {
            add.tap()
            settle(1.2)
            let addToChat = app.descendants(matching: .any)["addToChat"]
            if addToChat.exists { app.swipeDown(velocity: .fast) }
            settle(1)
        }
        app.buttons["composer.model"].tap()
        settle(1.2)
        app.buttons["modelPicker.close"].firstMatch.tap()
        settle(1)
    }

    /// Marks a phase in the test log (wall-clock seconds), so `scripts/animation-metrics
    /// --phases` can measure just that part of an Instruments trace.
    private func phase(_ name: String, _ body: () -> Void) {
        print("TOUR-PHASE \(name) begin \(Date().timeIntervalSince1970)")
        body()
        print("TOUR-PHASE \(name) end \(Date().timeIntervalSince1970)")
    }

    // MARK: Helpers

    private var window: XCUIElement { app.windows.firstMatch }

    private func launchSignedIn() {
        app.launchSkippingWelcome()
        let environment = ProcessInfo.processInfo.environment
        let field = app.descendants(matching: .any)["composer.field"]
        let address = app.textFields["server.address"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !field.exists, !address.exists, !app.textFields["signin.email"].exists {
            usleep(200_000)
        }
        if address.exists {
            address.tap()
            address.typeText(environment["THESEUS_OWUI_URL"] ?? "")
            app.buttons["server.continue"].tap()
        }
        let email = app.textFields["signin.email"]
        if !field.exists, email.waitForExistence(timeout: 15) {
            email.tap()
            email.typeText((environment["THESEUS_OWUI_EMAIL"] ?? "") + "\n")
            let password = app.secureTextFields["signin.password"]
            XCTAssertTrue(password.waitForExistence(timeout: 10))
            password.tap()
            password.typeText(environment["THESEUS_OWUI_PASSWORD"] ?? "")
            app.buttons["signin.submit"].tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The signed-in app has no composer")
    }

    private func startNewChat() {
        let greeting = app.descendants(matching: .any)["conversation.greeting"]
        if !greeting.waitForExistence(timeout: 5) {
            app.buttons["chat.new"].firstMatch.tap()
        }
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
    }

    private var composerField: XCUIElement {
        app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
    }

    private func type(_ text: String) {
        let field = composerField
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
    }

    private func clearDraft() {
        let field = composerField
        guard let value = field.value as? String, !value.isEmpty else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }

    private func tapSend() {
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let responses = app.responseCount
        send.tap()
        XCTAssertTrue(app.sendWentThrough(responsesBefore: responses))
    }

    private func waitUntilIdle(timeout: TimeInterval = 120) {
        let stop = app.buttons["composer.stop"]
        let deadline = Date().addingTimeInterval(timeout)
        while stop.exists, Date() < deadline { usleep(300_000) }
        settle(1)
    }

    /// The Chat on screen, so tearDown deletes it (its id is in the drawer row's identifier).
    private func rememberCurrentChat() {
        app.openSidebar()
        let current = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.' AND isSelected == true")).firstMatch
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.'")).firstMatch
        let row = current.waitForExistence(timeout: 3) ? current : first
        if row.exists { createdChatIDs.append(String(row.identifier.dropFirst("drawer.chat.".count))) }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Drags from the left edge to `fraction` of the width, released at `velocity` (pt/s).
    private func edge(to fraction: CGFloat, velocity: CGFloat) {
        drag(from: 0.005, to: fraction, velocity: velocity)
    }

    private func drag(from start: CGFloat, to end: CGFloat, velocity: CGFloat) {
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.55))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.55))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
    }

    private func settle(_ seconds: Double) {
        usleep(UInt32(seconds * 1_000_000))
    }
}

/// REST access for the tour: a long, fixed Chat to scroll, and cleanup. Only "[theseus-test]" Chats.
private struct TourServer: Sendable {
    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> TourServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return TourServer(url: url, token: token)
    }

    /// A Chat of `turns` question/answer pairs with markdown answers (headings, lists, code).
    func createLongChat(title: String, turns: Int) async throws -> String {
        var messages: [String: Any] = [:]
        var ordered: [[String: Any]] = []
        var parent: String?
        let now = Int(Date().timeIntervalSince1970)
        for turn in 0..<turns {
            for role in ["user", "assistant"] {
                let id = UUID().uuidString.lowercased()
                let content = role == "user"
                    ? "Question \(turn + 1): how does step \(turn + 1) of the maze walk work?"
                    : Self.answer(turn)
                var message: [String: Any] = [
                    "id": id, "parentId": parent.map { $0 as Any } ?? NSNull(), "childrenIds": [String](), "role": role,
                    "content": content, "timestamp": now - (turns - turn) * 60,
                ]
                if role == "assistant" {
                    message["model"] = "claude-haiku-5-5"
                    message["done"] = true
                } else {
                    message["models"] = ["claude-haiku-5-5"]
                }
                if let parent, var previous = messages[parent] as? [String: Any] {
                    previous["childrenIds"] = [id]
                    messages[parent] = previous
                    if let index = ordered.firstIndex(where: { $0["id"] as? String == parent }) { ordered[index] = previous }
                }
                messages[id] = message
                ordered.append(message)
                parent = id
            }
        }
        let chat: [String: Any] = [
            "chat": [
                "title": title, "models": ["claude-haiku-5-5"],
                "history": ["messages": messages, "currentId": parent.map { $0 as Any } ?? NSNull()], "messages": ordered,
            ],
        ]
        let json = try await Self.request(
            url.appending(path: "api/v1/chats/new"), method: "POST",
            body: try JSONSerialization.data(withJSONObject: chat), token: token
        )
        guard let id = (json as? [String: Any])?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    private static func answer(_ turn: Int) -> String {
        """
        ## Step \(turn + 1)

        The mouse keeps its **right whisker** on the wall and follows it. At every junction it notes \
        which corridors it already walked, so it never loops. This is *Trémaux's method*, and it \
        always finds the centre of a maze whose walls are connected.

        - **Sense:** read the walls around the current cell.
        - **Decide:** prefer unvisited corridors, then the least-visited one.
        - **Move:** advance one cell and mark the corridor.

        ```swift
        func next(from cell: Cell) -> Direction {
            cell.open.min { visits[$0, default: 0] < visits[$1, default: 0] } ?? .back
        }
        ```

        After step \(turn + 1) the mouse has mapped about \(min(100, (turn + 1) * 7)) % of the maze.
        """
    }

    /// A "[theseus-test]" Project (server: folder).
    func createProject(name: String) async throws -> String {
        let json = try await Self.request(
            url.appending(path: "api/v1/folders/"), method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["name": name]), token: token
        )
        guard let id = (json as? [String: Any])?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    func deleteProject(id: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/folders/\(id)"), method: "DELETE", body: nil, token: token)
    }

    func deleteChat(id: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(id)"), method: "DELETE", body: nil, token: token)
    }

    private static func request(_ url: URL, method: String, body: Data?, token: String?) async throws -> Any {
        // A deadline, so a cleanup call can't hold up the run.
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

/// A screenshot's pixels in points, for test16's checks (#194, #191). Reads only the regions it's
/// asked about, so a sample stays quick.
private struct ScreenPixels {
    private let image: CGImage
    private let scale: CGFloat

    init?(_ shot: XCUIScreenshot) {
        let ui = shot.image
        guard let cg = ui.cgImage else { return nil }
        image = cg
        scale = CGFloat(cg.width) / ui.size.width
    }

    /// The RGB bytes of `rect` (points), row by row.
    private func region(_ rect: CGRect) -> (bytes: [UInt8], width: Int, height: Int)? {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        let width = crop.width, height = crop.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    /// The most common colour in a thin column at `rect`'s right end (the empty end of a row).
    func background(near rect: CGRect) -> (Int, Int, Int) {
        guard let column = region(CGRect(x: rect.maxX - 6, y: rect.minY, width: 2, height: rect.height)) else { return (0, 0, 0) }
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: column.bytes.count, by: 4) {
            counts[(Int(column.bytes[index]) << 16) | (Int(column.bytes[index + 1]) << 8) | Int(column.bytes[index + 2]), default: 0] += 1
        }
        let key = counts.max { $0.value < $1.value }?.key ?? 0
        return ((key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF)
    }

    /// Pixels in `rect` (points) that differ clearly from `background`.
    func inkCount(in rect: CGRect, against background: (Int, Int, Int)) -> Int {
        guard let area = region(rect) else { return 0 }
        var count = 0
        for index in stride(from: 0, to: area.bytes.count, by: 4) {
            let r = Int(area.bytes[index]), g = Int(area.bytes[index + 1]), b = Int(area.bytes[index + 2])
            if max(abs(r - background.0), abs(g - background.1), abs(b - background.2)) > 40 { count += 1 }
        }
        return count
    }
}
