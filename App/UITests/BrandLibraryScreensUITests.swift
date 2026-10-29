import XCTest

/// BRAND-04 (#169): walks the branded library, Projects, Memory and Settings surfaces and keeps a
/// screenshot of each: the drawer, Projects and Memory empty, search without results, the Projects
/// grid with covers, a Project's detail, Change cover, the Memory summary, Settings › About and
/// The Collection, the App Icon picker, and the same screens at an accessibility text size; against
/// `scripts/stub-server`, the empty Chats list. Run it once per appearance
/// (`xcrun simctl ui <udid> appearance light|dark`).
///
/// Opt-in twice over: it needs the live-Server credentials and `THESEUS_BRAND_SCREENS=1` (pass it
/// to the runner as `TEST_RUNNER_THESEUS_BRAND_SCREENS=1`), so `scripts/test.sh` skips it. The
/// Projects and Memory entries it creates are `[theseus-test]`-marked and deleted at the end.
@MainActor
final class BrandLibraryScreensUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: BrandLibraryLiveServer?
    private let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        if let server { _ = try? blocking { try await server.cleanUp() } }
    }

    /// Runs REST setup off the main actor and waits for it, so the test itself stays synchronous
    /// (an async UI test that failed hung in its async tear-down).
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }

    /// Dismisses an active search field (Cancel, or the iOS 26 close button).
    private func endSearch() {
        for label in ["Cancel", "Close", "close"] where app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
            return
        }
        app.typeText("\n")
    }

    private func liveCredentials() throws -> (url: URL, email: String, password: String) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_BRAND_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_BRAND_SCREENS=1 for the brand screenshots") }
        guard let url = environment["THESEUS_OWUI_URL"].flatMap(URL.init(string:)),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The brand walkthrough needs a filled-in .env") }
        return (url, email, password)
    }

    func testBrandedLibrarySurfaces() throws {
        let credentials = try liveCredentials()
        let server = try blocking { try await BrandLibraryLiveServer.signIn(url: credentials.url, email: credentials.email, password: credentials.password) }
        self.server = server
        try blocking { try await server.cleanUp() }

        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome"] + english
        app.launchAsPro()
        signIn(url: credentials.url.absoluteString, email: credentials.email, password: credentials.password)

        // The drawer: the lockup, the selected row in accentSoft, the verdigris New chat pill.
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.chats"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("01-drawer")

        // Search without results: Yi Taek-gyun's shelves and the sleeping mouse.
        app.buttons["drawer.chats"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("zzqx no such chat")
        XCTAssertTrue(app.descendants(matching: .any)["chats.empty.search"].waitForExistence(timeout: 20))
        sleep(2)
        snapshot("02-search-empty")
        endSearch()

        // Projects, still empty: Lorrain and the sleeping mouse.
        app.openSidebar()
        sleep(1)
        snapshot("01b-drawer-chats-selected")
        app.buttons["drawer.projects"].tap()
        if app.descendants(matching: .any)["projects.empty"].waitForExistence(timeout: 15) {
            sleep(2)
            snapshot("03-projects-empty")
        }

        // Memory, empty: Dürer's study and the reading mouse.
        openSettings()
        openMemory()
        if app.buttons["memory.empty.add"].waitForExistence(timeout: 10) {
            sleep(2)
            snapshot("08-memory-empty")
        }

        // Projects and Memory entries to show, then a fresh launch (still signed in) loads them.
        for name in ["Thesis", "Incident review", "Sailing trip", "Reading list", "Hard problems"] {
            _ = try blocking { try await server.createProject(name: "\(BrandLibraryLiveServer.testPrefix) \(name)") }
        }
        for content in ["Prefers metric units and 24-hour time.", "Building Theseus, a Swift client for Open WebUI.",
                        "Loves 19th-century landscape painting."] {
            try blocking { try await server.addMemory("\(BrandLibraryLiveServer.testPrefix) \(content)") }
        }
        app.terminate()
        app.launchArguments = ["-theseus-skip-welcome"] + english
        app.launchAsPro()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))

        // The grid with covers.
        app.openSidebar()
        app.buttons["drawer.projects"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        sleep(3)
        snapshot("04-projects-grid")

        // A Project's detail: the cover as a short hero.
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.detail"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("05-project-detail")

        // Change cover.
        app.buttons["project.menu"].firstMatch.tap()
        let change = app.buttons["project.menu.changeCover"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.cover.sheet"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("06-change-cover")
        let unselected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'project.cover.'"))
            .allElementsBoundByIndex.first { !$0.isSelected && $0.isHittable }
        if let unselected {
            unselected.tap()
            XCTAssertTrue(app.descendants(matching: .any)["project.cover.sheet"].waitForNonExistence(timeout: 5))
            sleep(2)
            snapshot("07-project-new-cover")
        }
        app.tapBack()

        // Memory with entries: cards with ADDED plaques under the reading mouse.
        openSettings()
        openMemory()
        XCTAssertTrue(app.buttons["memory.edit"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("09-memory")
        app.buttons["memory.close"].firstMatch.tap()
        app.tapBack()

        // Settings home (Appearance: the palette thumbnails and Show today's artwork).
        let toggle = app.descendants(matching: .any)["settings.showTodayArtwork"].firstMatch
        app.revealInSettings(toggle)
        sleep(1)
        snapshot("10-settings-appearance")

        // About and The Collection.
        app.buttons["settings.info"].firstMatch.tap()
        app.buttons["About Theseus"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.about"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("11-about")
        app.buttons["about.collection"].tap()
        let collection = app.descendants(matching: .any)["settings.collection"].firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        sleep(2)
        snapshot("12-collection")
        collection.swipeUp()
        sleep(1)
        snapshot("12b-collection-scrolled")
        for _ in 0..<12 { collection.swipeUp(velocity: .fast) }
        sleep(1)
        snapshot("12c-collection-icons-typeface")
        app.tapBack()
        app.tapBack()

        // Settings › App Icon still works.
        let iconRow = app.buttons["settings.row.appIcon"]
        app.revealInSettings(iconRow)
        if iconRow.waitForExistence(timeout: 5) {
            iconRow.tap()
            XCTAssertTrue(app.buttons["appIcon.AppIcon"].waitForExistence(timeout: 5))
            sleep(2)
            snapshot("13-app-icon")
        }
    }

    /// The drawer, the Projects grid, a Project and The Collection at an accessibility text size.
    func testAccessibilitySize() throws {
        let credentials = try liveCredentials()
        let server = try blocking { try await BrandLibraryLiveServer.signIn(url: credentials.url, email: credentials.email, password: credentials.password) }
        self.server = server
        try blocking { try await server.cleanUp() }
        for name in ["Thesis", "Sailing trip"] {
            _ = try blocking { try await server.createProject(name: "\(BrandLibraryLiveServer.testPrefix) \(name)") }
        }

        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityL"] + english
        app.launchAsPro()
        signIn(url: credentials.url.absoluteString, email: credentials.email, password: credentials.password)
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.projects"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("20-ax-drawer")
        app.buttons["drawer.projects"].tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(3)
        snapshot("21-ax-projects")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.detail"].waitForExistence(timeout: 10))
        sleep(2)
        snapshot("22-ax-project-detail")

        app.tapBack()
        openSettings()
        app.buttons["settings.info"].firstMatch.tap()
        app.buttons["The Collection"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.collection"].waitForExistence(timeout: 5))
        sleep(2)
        snapshot("24-ax-collection")
    }

    /// The empty Chats list ("The library is quiet."), against `scripts/stub-server`'s Account
    /// without Chats. Start the stub first and pass its address as `THESEUS_STUB_URL`.
    func testChatsEmpty() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THESEUS_BRAND_SCREENS"] == "1" else { throw XCTSkip("Set THESEUS_BRAND_SCREENS=1 for the brand screenshots") }
        guard let stub = environment["THESEUS_STUB_URL"], !stub.isEmpty else { throw XCTSkip("Start scripts/stub-server and set THESEUS_STUB_URL") }
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome"] + english
        app.launchAsPro()
        signIn(url: stub, email: "empty@example.com", password: "theseus")
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.chats"].waitForExistence(timeout: 10))
        sleep(1)
        snapshot("30-drawer-empty")
        app.buttons["drawer.chats"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["chats.empty"].waitForExistence(timeout: 15))
        sleep(2)
        snapshot("31-chats-empty")

        // Forget the stub Account: walkthroughs that launch without a reset reuse the signed-in
        // Account, and the stub won't be running for them.
        app.terminate()
        app.launchArguments = ["-theseus-reset", "-theseus-skip-welcome"] + english
        app.launchAsPro()
        _ = app.textFields["server.address"].waitForExistence(timeout: 15)
        app.terminate()
    }

    // MARK: Helpers

    private func signIn(url: String, email: String, password: String) {
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))
        address.tap()
        address.typeText(url)
        app.buttons["server.continue"].tap()
        let emailField = app.textFields["signin.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email + "\n")
        let passwordField = app.secureTextFields["signin.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
    }

    /// Settings › Capabilities › View your memory, scrolling to it if needed.
    private func openMemory() {
        let capabilities = app.buttons["settings.row.capabilities"]
        app.revealInSettings(capabilities)
        capabilities.tap()
        let view = app.buttons["memory.view"]
        _ = view.waitForExistence(timeout: 10)
        app.revealInSettings(view)
        view.tap()
    }

    private func openSettings() {
        app.openSidebar()
        let avatar = app.buttons["drawer.account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        let open = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: avatar)
        _ = XCTWaiter().wait(for: [open], timeout: 5)
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

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// REST setup and cleanup: "[theseus-test]" Projects and Memory entries.
private struct BrandLibraryLiveServer: Sendable {
    static let testPrefix = "[theseus-test]"

    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> BrandLibraryLiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return BrandLibraryLiveServer(url: url, token: token)
    }

    func createProject(name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let json = try await Self.request(url.appending(path: "api/v1/folders/"), method: "POST", body: body, token: token)
        guard let id = (json as? [String: Any])?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    func addMemory(_ content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["content": content])
        _ = try await Self.request(url.appending(path: "api/v1/memories/add"), method: "POST", body: body, token: token)
    }

    /// Deletes "[theseus-test]" Projects (with their Chats) and Memory entries.
    func cleanUp() async throws {
        let folders = try await Self.request(url.appending(path: "api/v1/folders/"), method: "GET", body: nil, token: token)
        for folder in folders as? [[String: Any]] ?? [] {
            guard let id = folder["id"] as? String, (folder["name"] as? String)?.hasPrefix(Self.testPrefix) == true else { continue }
            var delete = URLComponents(url: url.appending(path: "api/v1/folders/\(id)"), resolvingAgainstBaseURL: false)
            delete?.queryItems = [URLQueryItem(name: "delete_contents", value: "true")]
            if let target = delete?.url {
                _ = try? await Self.request(target, method: "DELETE", body: nil, token: token)
            }
        }
        let memories = try await Self.request(url.appending(path: "api/v1/memories/"), method: "GET", body: nil, token: token)
        for entry in memories as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, (entry["content"] as? String)?.hasPrefix(Self.testPrefix) == true else { continue }
            _ = try? await Self.request(url.appending(path: "api/v1/memories/\(id)"), method: "DELETE", body: nil, token: token)
        }
    }

    private static func request(_ url: URL, method: String, body: Data?, token: String?) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
