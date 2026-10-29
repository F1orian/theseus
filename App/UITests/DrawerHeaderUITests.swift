import XCTest

/// The drawer's lockup and search button stay at the top while its list scrolls under them, over
/// the drawer's own colour. Runs against `scripts/stub-server` (`user@example.com` has 60 Chats).
/// Opt-in: `TEST_RUNNER_THESEUS_STUB_URL=http://localhost:8765`; with `THESEUS_SCREENSHOT_DIR` set,
/// the frames are also written there.
@MainActor
final class DrawerHeaderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testHeaderStaysWhileTheListScrolls() throws {
        guard let url = ProcessInfo.processInfo.environment["THESEUS_STUB_URL"], !url.isEmpty else {
            throw XCTSkip("Needs scripts/stub-server and TEST_RUNNER_THESEUS_STUB_URL")
        }
        app.launchArguments += ["-theseus-ui-testing"]
        app.launchSkippingWelcome()
        signIn(url: url)
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 20))
        app.openSidebar()

        let search = app.buttons["drawer.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let list = app.scrollViews["drawer"].firstMatch
        XCTAssertTrue(app.buttons["drawer.seeAll"].exists || list.exists)
        let top = search.frame.minY
        snapshot("drawer-header-rest")

        // Scroll the list well down: the header stays put and stays tappable.
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<3 { from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.2) }
        sleep(1)
        snapshot("drawer-header-scrolled")
        XCTAssertEqual(search.frame.minY, top, accuracy: 1, "the search button stays at the top")
        XCTAssertTrue(search.isHittable, "the search button still takes taps")
        // The first row has scrolled under the header.
        XCTAssertFalse(app.buttons["drawer.chats"].isHittable, "the list moved under the header")

        search.tap()
        XCTAssertTrue(app.textFields["drawer.search.field"].waitForExistence(timeout: 5))
    }

    private func signIn(url: String) {
        let address = app.textFields["server.address"]
        let home = app.descendants(matching: .any)["composer.field"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !address.exists, !home.exists, !app.textFields["signin.email"].exists {
            usleep(200_000)
        }
        if address.exists {
            address.tap()
            address.typeText(url)
            app.buttons["server.continue"].tap()
        }
        let email = app.textFields["signin.email"]
        guard email.waitForExistence(timeout: home.exists ? 1 : 15) else { return }
        email.tap()
        email.typeText("user@example.com")
        let password = app.secureTextFields["signin.password"]
        if !password.exists { email.typeText("\n") }
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("theseus")
        app.buttons["signin.submit"].tap()
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["THESEUS_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
