import XCTest

/// Settings › App Icon (BRAND-02) on the real home screen. Opt-in like the other live walkthroughs
/// (THESEUS_INTEGRATION=1 and a filled-in .env), because Settings needs a signed-in Account. It
/// switches to Monet and Pixel Mousehole, accepts iOS's "You have changed the icon" alert, shows
/// the home screen after each, and ends back on the primary (Renoir). It changes nothing on the
/// Server. Screenshots: result-bundle attachments, and THESEUS_SCREENSHOT_DIR when set.
@MainActor
final class AppIconUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSwitchingTheAppIcon() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"], !url.isEmpty,
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The App Icon walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchSkippingWelcome()
        signInIfNeeded(url: url, email: email, password: password)
        openSettings()

        // The row sits under Appearance and shows the current icon.
        let row = app.buttons["settings.row.appIcon"]
        app.revealInSettings(row)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No App icon row (supportsAlternateIcons is false?)")
        if !row.label.contains("Renoir") {
            // A previous run left an alternate: start from the primary.
            row.tap()
            choose("AppIcon")
            app.tapBack()
        }
        XCTAssertTrue(row.label.contains("Renoir"), row.label)
        row.tap()
        let renoir = app.buttons["appIcon.AppIcon"]
        XCTAssertTrue(renoir.waitForExistence(timeout: 5))
        XCTAssertEqual(renoir.label, "Renoir, Fruits of the Midi, current icon")
        XCTAssertTrue(renoir.isSelected)
        snapshot("01-picker-light")

        // Monet, then the home screen.
        choose("AppIcon-Monet")
        XCTAssertFalse(renoir.isSelected)
        showHomeScreen("02-home-monet")

        // Pixel Mousehole (the last section, scrolled into view), then the home screen.
        app.activate()
        choose("AppIcon-PixelMousehole")
        snapshot("03-picker-pixel-mousehole")
        showHomeScreen("04-home-pixel-mousehole")

        // Back to Renoir, and the page in the app's dark appearance.
        app.activate()
        choose("AppIcon")
        app.tapBack()
        let dark = app.buttons["settings.appearance.dark"]
        app.revealInSettings(dark)
        dark.tap()
        app.revealInSettings(row)
        row.tap()
        XCTAssertTrue(renoir.waitForExistence(timeout: 5))
        snapshot("05-picker-dark")
        app.tapBack()
        let system = app.buttons["settings.appearance.system"]
        app.revealInSettings(system)
        system.tap()
        showHomeScreen("06-home-renoir")
    }

    // MARK: Helpers

    /// Taps an icon in the picker (scrolling to it first) and accepts iOS's confirmation alert.
    private func choose(_ name: String) {
        let cell = app.buttons["appIcon.\(name)"]
        let page = app.descendants(matching: .any)["appIcon.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        // The grid is lazy: a cell scrolled far away doesn't exist. Cells above come back by
        // dragging down; `revealInSettings` then drags until the cell is fully on screen.
        for _ in 0..<6 where !cell.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            usleep(400_000)
        }
        app.revealInSettings(cell)
        XCTAssertTrue(cell.exists, "\(name) isn't on the page")
        if cell.isHittable {
            cell.tap()
        } else {
            // A section with a single icon makes its whole List row the button, which XCUITest
            // reports as not hittable although it's on screen; tap its thumbnail instead.
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.3)).tap()
        }
        acceptIconAlert()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: cell)
        XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 10), .completed, "\(name) didn't become current")
    }

    /// iOS confirms every switch with "You have changed the icon for “Theseus”." and an OK button.
    private func acceptIconAlert() {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for alert in [app.alerts.firstMatch, springboard.alerts.firstMatch] where alert.exists {
                alert.buttons.firstMatch.tap()
                return
            }
            usleep(250_000)
        }
        XCTFail("No icon-changed alert")
    }

    /// Goes home and pages the home screen until the Theseus icon shows, then snapshots it.
    private func showHomeScreen(_ name: String) {
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["Theseus"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "No Theseus icon on the home screen")
        for _ in 0..<6 where !icon.isHittable {
            springboard.swipeLeft()
            sleep(1)
        }
        sleep(2)  // the icon re-renders after a switch
        snapshot(name)
    }

    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 5), .completed, "the drawer slid in")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sheet"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "Didn't reach the new Chat screen")
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
