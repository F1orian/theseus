import XCTest

/// Live walkthrough of the Chats library (CHATS-01…10) against the test Server. Opt-in like the
/// sign-in test: needs THESEUS_INTEGRATION=1 and a filled-in .env. It only touches Chats it
/// creates itself (titled "[theseus-test] …") and deletes them afterwards. Screenshots are kept
/// as attachments of the result bundle.
final class ChatsLibraryUITests: XCTestCase {
    private var server: LiveServer?
    private var createdChatIDs: [String] = []
    /// #146: the first Chat on page 4 of the Server's list (60 per page), if the Account has one.
    private var pageFourChatID: String?

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"].flatMap(URL.init(string:)),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The Chats library walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        let server = try await LiveServer.signIn(url: url, email: email, password: password)
        try await server.deleteChats(titledWithPrefix: LiveServer.testPrefix)
        createdChatIDs = [
            try await server.createChat(title: "\(LiveServer.testPrefix) Trip notes"),
            try await server.createChat(title: "\(LiveServer.testPrefix) Weekly dinner planning"),
            try await server.createChat(title: "\(LiveServer.testPrefix) Drawer menu"),
        ]
        self.server = server
        pageFourChatID = try? await server.firstChatID(onPage: 4)
    }

    override func tearDown() async throws {
        guard let server else { return }
        for id in createdChatIDs {
            try? await server.deleteChat(id: id)
        }
        try? await server.deleteChats(titledWithPrefix: LiveServer.testPrefix)
    }

    @MainActor
    func testChatsLibraryWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: environment["THESEUS_OWUI_URL"] ?? "", email: environment["THESEUS_OWUI_EMAIL"] ?? "",
               password: environment["THESEUS_OWUI_PASSWORD"] ?? "")

        // CHATS-01: the drawer lists the new test Chats under Recents.
        let dinnerID = createdChatIDs[1]
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.chat.\(dinnerID)"].waitForExistence(timeout: 15))
        snapshot("01-drawer")

        // #171 (CHATS-09 in the drawer): a row's long-press menu stars it (it moves to Starred)
        // and deletes it after the confirmation.
        let menuRow = app.buttons["drawer.chat.\(createdChatIDs[2])"]
        XCTAssertTrue(menuRow.waitForExistence(timeout: 10))
        menuRow.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Star"].waitForExistence(timeout: 5))
        snapshot("171-01-drawer-row-menu")
        app.buttons["Star"].tap()
        let recentsHeader = app.staticTexts["Recents"]
        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 5))
        XCTAssertTrue(recentsHeader.waitForExistence(timeout: 5))
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in menuRow.frame.minY < recentsHeader.frame.minY }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "the starred row moved above Recents")
        snapshot("171-02-drawer-starred")
        menuRow.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Unstar"].waitForExistence(timeout: 5))
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["delete.confirm"].firstMatch.waitForExistence(timeout: 5))
        snapshot("171-03-drawer-delete-confirm")
        app.buttons["delete.confirm"].firstMatch.tap()
        XCTAssertTrue(menuRow.waitForNonExistence(timeout: 10), "the deleted row left the drawer")
        snapshot("171-04-drawer-deleted")

        // #172: the drawer's search. The header's magnifying glass gives the drawer the whole
        // screen with the field focused; the recent Chats show until something's typed.
        app.buttons["drawer.search"].tap()
        let searchField = app.textFields["drawer.search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard comes up with the search")
        XCTAssertTrue(app.staticTexts["Recent chats"].waitForExistence(timeout: 5))
        snapshot("172-01-drawer-search")
        // Every recent Chat can be scrolled above the keyboard.
        let lastRecent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.search.result.'")).allElementsBoundByIndex.last
        app.scrollViews["drawer.searchResults"].firstMatch.swipeUp()
        if let lastRecent {
            XCTAssertLessThanOrEqual(lastRecent.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "the last recent Chat scrolls above the keyboard")
        }
        searchField.typeText("dinner")
        let match = app.buttons["drawer.search.result.\(dinnerID)"]
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        snapshot("172-02-drawer-search-results")
        match.tap()
        XCTAssertTrue(app.staticTexts["chat.title"].waitForExistence(timeout: 10), "a match opens its Chat")
        XCTAssertFalse(app.buttons["drawer.account"].exists && app.buttons["drawer.account"].isHittable, "and closes the drawer")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        snapshot("172-03-match-opened")

        // #172: Recents stop after about a screen; "See all" opens the Chats list. No paging.
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.seeAll"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["drawer.loadingMore"].exists, "the drawer doesn't page")
        snapshot("172-04-drawer-see-all")

        // CHATS-02: the Chats list.
        app.buttons["drawer.chats"].tap()
        let dinnerRow = app.descendants(matching: .any)["chat.row.\(dinnerID)"]
        XCTAssertTrue(dinnerRow.waitForExistence(timeout: 10))
        snapshot("02-chats-list")

        // CHATS-09 + CHATS-05: long-press → Star.
        dinnerRow.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Star"].waitForExistence(timeout: 5))
        snapshot("03-row-menu")
        app.buttons["Star"].tap()

        // CHATS-04: the Starred filter.
        app.buttons["chats.filter"].firstMatch.tap()
        snapshot("04-filter-menu")
        app.buttons["Starred"].firstMatch.tap()
        XCTAssertTrue(dinnerRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["chat.row.\(createdChatIDs[0])"].exists)
        snapshot("05-filter-starred")
        app.buttons["chats.filter"].firstMatch.tap()
        app.buttons["All chats"].firstMatch.tap()

        // CHATS-01 + CHATS-05: Starred section in the drawer.
        app.openSidebar()
        XCTAssertTrue(app.staticTexts["Starred"].waitForExistence(timeout: 5))
        snapshot("06-drawer-starred")
        app.buttons["drawer.chats"].tap()

        // CHATS-03: search with the match in bold.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("dinner")
        XCTAssertTrue(dinnerRow.waitForExistence(timeout: 10))
        snapshot("07-search")
        dinnerRow.tap()

        // CHATS-08: the overflow menu in the Chat header.
        XCTAssertTrue(app.staticTexts["chat.title"].waitForExistence(timeout: 5))
        snapshot("08-chat-placeholder")
        app.buttons["chat.menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.menu.rename"].waitForExistence(timeout: 5))
        snapshot("09-overflow-menu")

        // CHATS-06: rename through the system alert.
        app.buttons["chat.menu.rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        snapshot("10-rename-alert")
        field.clearAndType("\(LiveServer.testPrefix) Dinner ideas")
        app.alerts.buttons["OK"].firstMatch.tap()
        let title = app.staticTexts["chat.title"]
        let renamed = title.waitForLabel("\(LiveServer.testPrefix) Dinner ideas", timeout: 10)
        snapshot("10-renamed")
        XCTAssertTrue(renamed, "title is \(title.label)")

        // CHATS-07: delete morphs the popover into a confirmation, then returns home.
        app.buttons["chat.menu"].firstMatch.tap()
        app.buttons["chat.menu.delete"].tap()
        XCTAssertTrue(app.buttons["chat.menu.deleteConfirm"].waitForExistence(timeout: 5))
        snapshot("11-delete-confirm")
        app.buttons["chat.menu.deleteConfirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation.greeting"].waitForExistence(timeout: 10))

        // CHATS-10: the Chats list pill starts a new chat.
        app.openSidebar()
        XCTAssertFalse(app.buttons["drawer.chat.\(dinnerID)"].waitForExistence(timeout: 2), "deleted")
        app.buttons["drawer.chats"].tap()
        XCTAssertTrue(app.buttons["chats.newChat"].waitForExistence(timeout: 5))
        app.buttons["chats.newChat"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation.greeting"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor
    private func signIn(_ app: XCUIApplication, url: String, email: String, password: String) {
        let address = app.textFields["server.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
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
        // The new-chat home, not just a drawer button: the model list has one too while the
        // Account loads, and a tap there can be lost when the home replaces it.
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
    }

    /// #146: the Chats list pages on scroll until it reaches a Chat older than page 3.
    @MainActor
    func testInfiniteScrollReachesChatsOlderThanPageThree() throws {
        guard let target = pageFourChatID else { throw XCTSkip("The test Account has no 4th page of Chats") }
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: environment["THESEUS_OWUI_URL"] ?? "", email: environment["THESEUS_OWUI_EMAIL"] ?? "",
               password: environment["THESEUS_OWUI_PASSWORD"] ?? "")
        app.openSidebar()
        // #172: the drawer lists about a screen of Recents and no more; its "See all" opens the
        // full-screen Chats list, which pages through every Chat.
        let seeAll = app.buttons["drawer.seeAll"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 15))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.'")).count
        let starredCount = app.staticTexts["Starred"].exists ? starredRowCount(app) : 0
        XCTAssertLessThanOrEqual(rows - starredCount, 20, "Recents are capped")
        let drawer = app.scrollViews["drawer"].firstMatch
        for _ in 0..<4 { drawer.swipeUp(velocity: .fast) }
        XCTAssertFalse(app.descendants(matching: .any)["drawer.loadingMore"].exists, "the drawer doesn't page")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.'")).count, rows, "no more rows load")
        seeAll.tap()
        let list = app.descendants(matching: .any)["chats.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let row = app.descendants(matching: .any)["chat.row.\(target)"]
        var swipes = 0
        while !row.exists, swipes < 80 {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "page 4's first Chat never appeared after \(swipes) swipes")
        snapshot("12-page-four-reached")
    }

    /// #170: with the composer's keyboard up, opening the drawer (header button, a drag from the
    /// content, or a drag that's cancelled) dismisses the keyboard, lays the drawer out against the
    /// full screen, and leaves the composer resting at the bottom once the drawer closes.
    @MainActor
    func testKeyboardGoesAwayWhenTheDrawerOpens() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: environment["THESEUS_OWUI_URL"] ?? "", email: environment["THESEUS_OWUI_EMAIL"] ?? "",
               password: environment["THESEUS_OWUI_PASSWORD"] ?? "")
        let window = app.windows.firstMatch
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        let field = app.descendants(matching: .any)["composer.field"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let restingBottom = composer.frame.maxY
        let account = app.buttons["drawer.account"]

        // The header button.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the composer's keyboard is up")
        Thread.sleep(forTimeInterval: 0.5)
        snapshot("170-01-keyboard-up")
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "the composer rides above the keyboard")
        app.buttons["drawer.open"].firstMatch.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        snapshot("170-02-drawer-open")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "opening the drawer dismisses the keyboard")
        XCTAssertGreaterThan(account.frame.maxY, window.frame.maxY - 120, "the drawer's footer sits at the bottom of the screen")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        snapshot("170-03-closed")
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 2, "the composer rests at the bottom, no keyboard gap")

        // A drag from the middle of the content.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        drag(window, from: 0.3, to: 0.85, velocity: 1200)
        Thread.sleep(forTimeInterval: 1)
        snapshot("170-04-dragged-open")
        XCTAssertTrue(account.isHittable, "a drag opens the drawer")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "dragging the drawer open dismisses the keyboard")
        XCTAssertGreaterThan(account.frame.maxY, window.frame.maxY - 120)
        drag(window, from: 0.92, to: 0.2, velocity: 1200)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 2)

        // A drag that's released before half way: the drawer settles back, the layout too.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        drag(window, from: 0.3, to: 0.42, velocity: 150)
        Thread.sleep(forTimeInterval: 1)
        snapshot("170-05-cancelled-drag")
        XCTAssertFalse(account.exists && account.isHittable, "a short drag settles closed")
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 2, "no layout jump after a cancelled drag")
    }

    /// The drawer's Starred rows: those above the Recents header.
    @MainActor
    private func starredRowCount(_ app: XCUIApplication) -> Int {
        let recentsTop = app.staticTexts["Recents"].frame.minY
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer.chat.'")).allElementsBoundByIndex
            .filter { $0.frame.minY < recentsTop }.count
    }

    @MainActor
    private func drag(_ window: XCUIElement, from start: CGFloat, to end: CGFloat, velocity: CGFloat) {
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.45))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Replaces the text of an already focused field (the cursor is at the end).
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }

    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

/// Minimal REST access for test setup and cleanup. Only creates and deletes "[theseus-test]" Chats.
private struct LiveServer: Sendable {
    static let testPrefix = "[theseus-test]"

    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> LiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return LiveServer(url: url, token: token)
    }

    func createChat(title: String) async throws -> String {
        let chat: [String: Any] = [
            "chat": ["title": title, "models": [], "history": ["messages": [:], "currentId": NSNull()], "messages": []],
        ]
        let json = try await Self.request(
            url.appending(path: "api/v1/chats/new"),
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: chat),
            token: token
        )
        guard let id = (json as? [String: Any])?["id"] as? String else { throw URLError(.cannotParseResponse) }
        return id
    }

    /// The id of the first Chat on `page` of the Chat list (starred and Project Chats included).
    func firstChatID(onPage page: Int) async throws -> String? {
        var components = URLComponents(url: url.appending(path: "api/v1/chats/"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "include_pinned", value: "true"),
            URLQueryItem(name: "include_folders", value: "true"),
        ]
        guard let pageURL = components?.url else { return nil }
        let rows = try await Self.request(pageURL, method: "GET", body: nil, token: token) as? [[String: Any]] ?? []
        return rows.first?["id"] as? String
    }

    func deleteChat(id: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(id)"), method: "DELETE", body: nil, token: token)
    }

    /// Removes leftovers from earlier, interrupted runs. Only Chats whose title starts with `prefix`.
    func deleteChats(titledWithPrefix prefix: String) async throws {
        var components = URLComponents(url: url.appending(path: "api/v1/chats/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "text", value: prefix)]
        guard let searchURL = components?.url else { return }
        let hits = try await Self.request(searchURL, method: "GET", body: nil, token: token) as? [[String: Any]] ?? []
        for hit in hits {
            guard let id = hit["id"] as? String, let title = hit["title"] as? String, title.hasPrefix(prefix) else { continue }
            try await deleteChat(id: id)
        }
    }

    private static func request(_ url: URL, method: String, body: Data?, token: String?) async throws -> Any {
        var request = URLRequest(url: url)
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
