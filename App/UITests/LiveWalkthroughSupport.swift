import XCTest

/// Steps the live walkthroughs share.
extension XCUIApplication {
    /// Picks `modelID` in the composer's Select model sheet (MODEL-01, MODEL-03) and waits for the
    /// sheet to close. Rows are matched by identifier, never by label: the composer chip carries
    /// the selected model's name too, so a label query can hit the chip under the sheet.
    @MainActor
    func chooseComposerModel(_ modelID: String) {
        let chip = buttons["composer.model"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "No model chip on the composer")
        chip.tap()
        let picker = descendants(matching: .any)["modelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Select model didn't open")
        let row = buttons["modelPicker.model.\(modelID)"]
        if !row.waitForExistence(timeout: 2), buttons["modelPicker.more"].exists {
            buttons["modelPicker.more"].tap()
        }
        if row.waitForExistence(timeout: 3) {
            row.tap()
        } else {
            XCTFail("\(modelID) isn't offered in Select model")
            buttons["modelPicker.close"].firstMatch.tap()
        }
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Select model didn't close")
    }
}

extension XCUIApplication {
    /// Shows the drawer: slides it in on iPhone, or nothing when the persistent sidebar of the
    /// regular-width layout (iPad, PLAT-05) is already showing.
    @MainActor
    func openSidebar() {
        let account = buttons["drawer.account"]
        if account.exists, account.isHittable { return }
        let open = buttons["drawer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "No drawer button")
        open.tap()
    }

    /// Whether the walkthrough runs in the regular-width layout (the iPad sidebar).
    @MainActor
    var usesSidebarLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}

extension XCUIApplication {
    /// Launches without the one-time welcome sheet (AUTH-08), which would cover what the
    /// walkthrough tests after its first sign-in. `WelcomeUITests` launches with it.
    @MainActor
    func launchSkippingWelcome() {
        if !launchArguments.contains("-theseus-skip-welcome") { launchArguments.append("-theseus-skip-welcome") }
        launchAsPro()
    }

    /// Launches with Theseus Pro unlocked from memory (ADR 0173), so walkthroughs reach every
    /// feature without the App Store, unless the test chose a state itself (`-theseus-pro free`).
    @MainActor
    func launchAsPro() {
        if !launchArguments.contains("-theseus-pro") { launchArguments += ["-theseus-pro", "pro"] }
        launch()
    }
}

extension XCUIApplication {
    /// Taps the back button of the frontmost navigation bar (a sheet's, when one is up). On
    /// iPad the split view's own bars come first in the hierarchy, so `navigationBars` index 0
    /// isn't the sheet's there.
    @MainActor
    func tapBack() {
        for sheet in ["settings.sheet", "addToChat", "modelPicker"] {
            let bar = descendants(matching: .any)[sheet].firstMatch.navigationBars.firstMatch
            if bar.exists {
                bar.buttons.element(boundBy: 0).tap()
                return
            }
        }
        navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
    }
}

extension XCUIApplication {
    /// Scrolls the Settings sheet until `row` is fully between its navigation bar and its bottom
    /// edge (iPad's form sheet is shorter than the iPhone's). Drags inside the list, never down
    /// from the top, so the sheet isn't dismissed.
    @MainActor
    func revealInSettings(_ row: XCUIElement) {
        let sheet = descendants(matching: .any)["settings.sheet"].firstMatch
        guard sheet.waitForExistence(timeout: 5) else { return }
        for _ in 0..<6 {
            let bar = sheet.navigationBars.firstMatch
            let top = bar.exists ? bar.frame.maxY : sheet.frame.minY
            if row.exists, row.frame.minY >= top, row.frame.maxY <= sheet.frame.maxY { return }
            let below = !row.exists || row.frame.minY >= top
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.75 : 0.35))
            let end = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.45 : 0.6))
            start.press(forDuration: 0.05, thenDragTo: end)
            usleep(400_000)
        }
    }
}

extension XCUIApplication {
    /// How many Responses the transcript shows.
    @MainActor
    var responseCount: Int {
        descendants(matching: .any).matching(identifier: "message.response").count
    }

    /// Whether a send went through: the stop button shows, the send button is still there, or a
    /// new Response arrived. The stop button alone can be missed: while a Response streams, its
    /// text keeps animating (ADR 0130), XCUITest waits for the app to idle before it looks, and a
    /// short Response may have finished by then.
    @MainActor
    func sendWentThrough(responsesBefore: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if buttons["composer.stop"].exists || responseCount > responsesBefore { return true }
            usleep(250_000)
        } while Date() < deadline
        return buttons["composer.send"].exists
    }
}
