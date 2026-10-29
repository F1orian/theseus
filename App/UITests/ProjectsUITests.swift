import XCTest

/// Live walkthrough of Projects (PROJ-01…08) against the test Server. Opt-in like the sign-in
/// test: needs THESEUS_INTEGRATION=1 and a filled-in .env. It only touches Projects and Chats it
/// creates itself (named "[theseus-test] …") and deletes them, with their Knowledge files,
/// afterwards. Screenshots are kept as attachments of the result bundle.
final class ProjectsUITests: XCTestCase {
    private var server: ProjectsLiveServer?
    private var chatID: String?

    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["THESEUS_OWUI_URL"].flatMap(URL.init(string:)),
              let email = environment["THESEUS_OWUI_EMAIL"], !email.isEmpty,
              let password = environment["THESEUS_OWUI_PASSWORD"], !password.isEmpty
        else { throw XCTSkip("The Projects walkthrough needs THESEUS_INTEGRATION=1 and a filled-in .env") }
        let server = try await ProjectsLiveServer.signIn(url: url, email: email, password: password)
        try await server.cleanUp()
        chatID = try await server.createChat(title: "\(ProjectsLiveServer.testPrefix) Weekly groceries")
        self.server = server
    }

    override func tearDown() async throws {
        guard let server else { return }
        if let chatID { try? await server.deleteChat(id: chatID) }
        try? await server.cleanUp()
    }

    @MainActor
    func testProjectsWalkthrough() throws {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-theseus-reset"]
        app.launchSkippingWelcome()
        signIn(app, url: environment["THESEUS_OWUI_URL"] ?? "", email: environment["THESEUS_OWUI_EMAIL"] ?? "",
               password: environment["THESEUS_OWUI_PASSWORD"] ?? "")
        let name = "\(ProjectsLiveServer.testPrefix) Meal plan"

        // PROJ-01: Projects from the drawer.
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.projects"].waitForExistence(timeout: 10))
        app.buttons["drawer.projects"].tap()
        XCTAssertTrue(app.buttons["projects.new"].waitForExistence(timeout: 10))
        snapshot("01-projects-list")

        // PROJ-02: create with a name and a description.
        app.buttons["projects.new"].tap()
        let nameField = app.textFields["createProject.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText(name)
        app.textFields["createProject.description"].tap()
        app.textFields["createProject.description"].typeText("Eat healthier on weekdays")
        snapshot("02-create-project")
        app.buttons["createProject.confirm"].tap()

        // PROJ-03: the new Project's detail with its info card and empty Chats.
        XCTAssertTrue(app.descendants(matching: .any)["project.description"].waitForExistence(timeout: 10))
        snapshot("03-project-detail")

        // #127: a new Chat from the Project shows its chip and is filed in it on the first send.
        app.buttons["project.newChat"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.project"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat.incognito"].exists, "Incognito chats can't start in a Project")
        snapshot("03b-new-chat-in-project")
        let field = app.textFields["composer.field"].exists ? app.textFields["composer.field"] : app.textViews["composer.field"]
        field.tap()
        field.typeText("\(ProjectsLiveServer.testPrefix) Name one weekday dinner. One line.")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.buttons["composer.stop"].waitForNonExistence(timeout: 90))
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.projects"].waitForExistence(timeout: 5))
        app.buttons["drawer.projects"].tap()
        let mealPlan = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'project.row.' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(mealPlan.waitForExistence(timeout: 10))
        mealPlan.tap()
        let projectChat = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.chat.'")).firstMatch
        XCTAssertTrue(projectChat.waitForExistence(timeout: 15), "the new Chat landed in the Project")
        snapshot("03c-project-with-new-chat")

        // PROJ-04: Instructions.
        app.buttons["project.instructions"].tap()
        let instructions = app.textFields["instructions.field"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.typeText("Suggest simple recipes with seasonal vegetables.")
        snapshot("04-instructions")
        app.buttons["instructions.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.instructionsSummary"].waitForExistence(timeout: 10))

        // PROJ-05: Knowledge through "Add text".
        app.buttons["project.files"].tap()
        XCTAssertTrue(app.buttons["files.add"].waitForExistence(timeout: 5))
        snapshot("05-files-empty")
        app.buttons["files.add"].tap()
        XCTAssertTrue(app.buttons["files.addText"].waitForExistence(timeout: 5))
        app.buttons["files.addText"].tap()
        let title = app.textFields["addText.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("theseus-test pantry")
        app.textFields["addText.content"].tap()
        app.textFields["addText.content"].typeText("Oats, lentils, rice, tinned tomatoes.")
        snapshot("06-add-text")
        app.buttons["addText.confirm"].tap()
        XCTAssertTrue(app.buttons["files.remove"].waitForExistence(timeout: 60))
        snapshot("07-files")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["project.files"].waitForLabel("1 file", timeout: 10))

        // PROJ-07: star.
        app.buttons["project.star"].firstMatch.tap()
        XCTAssertTrue(app.buttons["project.star"].firstMatch.waitForLabel("Unstar project", timeout: 10))
        snapshot("08-starred")

        // PROJ-08: the menu and Archive.
        app.buttons["project.menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["project.menu.archive"].waitForExistence(timeout: 5))
        snapshot("09-project-menu")
        app.buttons["project.menu.archive"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.archived"].waitForExistence(timeout: 10))
        snapshot("10-archived")

        // PROJ-08: rename.
        app.buttons["project.menu"].firstMatch.tap()
        app.buttons["project.menu.rename"].tap()
        let renameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(renameField.waitForExistence(timeout: 5))
        renameField.clearAndType("\(name) 2026")
        app.alerts.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["\(name) 2026"].waitForExistence(timeout: 10))

        // PROJ-01 + PROJ-08: archived Projects only show under the Archived filter.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["projects.filter"].waitForExistence(timeout: 5))
        app.buttons["projects.filter"].firstMatch.tap()
        app.buttons["Archived"].firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        snapshot("11-filter-archived")

        // PROJ-06: Add to project from the Chat menu.
        app.openSidebar()
        let chatRow = app.buttons["drawer.chat.\(chatID ?? "")"]
        XCTAssertTrue(chatRow.waitForExistence(timeout: 10))
        chatRow.tap()
        app.buttons["chat.menu"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.menu.addToProject"].waitForExistence(timeout: 5))
        snapshot("12-chat-menu")
        app.buttons["chat.menu.addToProject"].tap()
        XCTAssertTrue(app.buttons["addToProject.new"].waitForExistence(timeout: 5))
        // Archived Projects aren't offered, so create a fresh one from "+"; the Chat moves there.
        snapshot("13-add-to-project")
        app.buttons["addToProject.new"].tap()
        let pickerName = app.textFields["createProject.name"]
        XCTAssertTrue(pickerName.waitForExistence(timeout: 5))
        pickerName.typeText("\(ProjectsLiveServer.testPrefix) Groceries")
        app.buttons["createProject.confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["projects.notice"].waitForExistence(timeout: 10))
        snapshot("14-chat-moved")
        XCTAssertTrue(app.buttons["addToProject.new"].waitForNonExistence(timeout: 10))
        // The toast covers the header until it times out.
        XCTAssertTrue(app.descendants(matching: .any)["projects.notice"].waitForNonExistence(timeout: 10))

        // PROJ-03: the moved Chat in its Project, then delete it but keep its Chats (PROJ-08).
        app.openSidebar()
        XCTAssertTrue(app.buttons["drawer.projects"].waitForExistence(timeout: 5))
        app.buttons["drawer.projects"].tap()
        let groceries = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.row.'")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        groceries.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.chat.\(chatID ?? "")"].waitForExistence(timeout: 10))
        snapshot("15-project-with-chat")
        app.buttons["project.menu"].firstMatch.tap()
        app.buttons["project.menu.delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["project.delete.keepChats"].waitForExistence(timeout: 5))
        snapshot("16-delete-confirm")
        app.buttons["project.delete.keepChats"].firstMatch.tap()
        XCTAssertTrue(app.buttons["projects.new"].waitForExistence(timeout: 10))
        snapshot("17-after-delete")
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
        // Wait for the new-chat home, not just the drawer button: the model list shows one too
        // while the Account loads, and a tap there can be lost when the home replaces it.
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 30))
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

/// Minimal REST access for test setup and cleanup. Only creates and deletes "[theseus-test]"
/// Projects, Chats and "theseus-test" Knowledge files.
private struct ProjectsLiveServer: Sendable {
    static let testPrefix = "[theseus-test]"

    let url: URL
    let token: String

    static func signIn(url: URL, email: String, password: String) async throws -> ProjectsLiveServer {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let json = try await request(url.appending(path: "api/v1/auths/signin"), method: "POST", body: body, token: nil)
        guard let token = (json as? [String: Any])?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
        return ProjectsLiveServer(url: url, token: token)
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

    func deleteChat(id: String) async throws {
        _ = try await Self.request(url.appending(path: "api/v1/chats/\(id)"), method: "DELETE", body: nil, token: token)
    }

    /// Deletes leftover "[theseus-test]" Projects (with their Chats) and "theseus-test" files.
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
        var search = URLComponents(url: url.appending(path: "api/v1/files/search"), resolvingAgainstBaseURL: false)
        search?.queryItems = [URLQueryItem(name: "filename", value: "theseus-test*")]
        guard let searchURL = search?.url else { return }
        let files = (try? await Self.request(searchURL, method: "GET", body: nil, token: token)) as? [[String: Any]] ?? []
        for file in files {
            guard let id = file["id"] as? String, (file["filename"] as? String)?.hasPrefix("theseus-test") == true else { continue }
            _ = try? await Self.request(url.appending(path: "api/v1/files/\(id)"), method: "DELETE", body: nil, token: token)
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
