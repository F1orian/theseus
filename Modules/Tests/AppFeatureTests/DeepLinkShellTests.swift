@testable import AppFeature
import AppIntentsFeature
import Auth
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Persistence
import Testing

/// Deep links into the signed-in shell (PLAT-03), shared content (PLAT-04) and the snapshot the
/// widgets and Shortcuts read (PLAT-01, ADR 0100).
@MainActor
@Suite("Deep links in the shell", .serialized)
struct DeepLinkShellTests {
    let transport = StubTransport()
    let shared = SharedStateStore(container: .temporary())
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    /// A shell for the recorded Account as a regular user with `chat` permissions. Call
    /// `refresh()` to sign it in.
    func makeShell(chat permissions: [String: Bool] = ["temporary": true]) throws -> MainShellModel {
        var user = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("auths.json")).objectValue ?? [:]
        user["role"] = .string("user")
        var tree = user["permissions"]?.objectValue ?? [:]
        var chat = tree["chat"]?.objectValue ?? [:]
        for (key, value) in permissions { chat[key] = .bool(value) }
        tree["chat"] = .object(chat)
        user["permissions"] = .object(tree)
        transport.stub("GET", "api/v1/auths/", body: try JSONEncoder().encode(JSONValue.object(user)))
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        let shell = MainShellModel(
            account: account,
            client: OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: FixedTokenAuthorizer(token: "jwt")),
            database: nil,
            onSignOut: {}
        )
        shell.sharedState = shared
        return shell
    }

    @Test func aNewChatLinkPreparesTheComposer() async throws {
        let shell = try makeShell()
        await shell.refresh()
        shell.navigate(to: .chatsList)
        shell.isSettingsPresented = true
        let generation = shell.launchGeneration

        shell.open(.newChat(.init(prompt: "Plan a trip", start: .camera)))
        #expect(shell.route == .newChat())
        #expect(!shell.isSettingsPresented)
        #expect(shell.launchGeneration == generation + 1)
        let prepared = try #require(shell.preparedConversation)
        #expect(prepared.draft == "Plan a trip")
        #expect(prepared.composer.launchAction == .camera)
        #expect(!prepared.isIncognito)

        // Any other navigation drops the prepared Chat.
        shell.navigate(to: .newChat())
        #expect(shell.preparedConversation == nil)
        await shell.tearDown()
    }

    @Test func linksBeforeTheModelsLoadWaitForThem() async throws {
        let shell = try makeShell()
        shell.open(.newChat(.init(start: .voiceMode)))
        #expect(shell.preparedConversation == nil)
        await shell.refresh()
        #expect(shell.preparedConversation?.composer.launchAction == .voiceMode)
        await shell.tearDown()
    }

    @Test func chatAndListLinksNavigate() async throws {
        let shell = try makeShell()
        await shell.refresh()
        shell.open(.chat(id: "c-1"))
        #expect(shell.route == .chat(id: "c-1"))
        shell.open(.chatsList)
        #expect(shell.route == .chatsList)
        await shell.tearDown()
    }

    @Test func incognitoLinksRespectThePolicy() async throws {
        let allowed = try makeShell(chat: ["temporary": true])
        await allowed.refresh()
        allowed.open(.incognitoChat(prompt: "psst"))
        #expect(allowed.route == .incognitoChat)
        #expect(allowed.preparedConversation?.isIncognito == true)
        #expect(allowed.preparedConversation?.draft == "psst")
        await allowed.tearDown()

        let denied = try makeShell(chat: ["temporary": false])
        await denied.refresh()
        denied.open(.incognitoChat(prompt: nil))
        #expect(denied.route == .newChat(), "no Incognito chats on this Server: a regular new Chat")
        #expect(denied.preparedConversation?.isIncognito == false)
        await denied.tearDown()
    }

    @Test func enforcedIncognitoKeepsHistoryOutOfLinksAndTheSnapshot() async throws {
        let shell = try makeShell(chat: ["temporary": true, "temporary_enforced": true])
        await shell.refresh()
        shell.open(.newChat(.init(prompt: "Hello")))
        #expect(shell.route == .incognitoChat)
        #expect(shell.preparedConversation?.isIncognito == true)
        shell.open(.chatsList)
        #expect(shell.route == .incognitoChat)
        let snapshot = try #require(shell.sharedSnapshot)
        #expect(snapshot.recentChats.isEmpty)
        #expect(snapshot.actions.incognitoChat)
        await shell.tearDown()
    }

    @Test func theSnapshotIsTheActiveAccountsSavedChats() async throws {
        let shell = try makeShell()
        #expect(shell.sharedSnapshot == nil, "nothing to share before the Account loads")
        await shell.refresh()
        let snapshot = try #require(shell.sharedSnapshot)
        #expect(snapshot.accountID == account.id)
        #expect(snapshot.serverHost == Fixture.serverURL.host())
        #expect(!snapshot.recentChats.isEmpty)
        #expect(snapshot.recentChats.map(\.id) == shell.library.chats.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }.prefix(50).map(\.id))

        shell.publishSharedSnapshot()
        #expect(shared.snapshots.read() == snapshot)
        shared.clear()
        #expect(shared.snapshots.read() == nil)
        await shell.tearDown()
    }

    @Test func aShareFillsANewChatAndLeavesTheInbox() async throws {
        let shell = try makeShell()
        await shell.refresh()
        let entry = try shared.inbox.add([.text("Shared text"), .url(Fixture.serverURL)], note: "What is this?")
        shell.open(.sharedItems(entry.id))
        let prepared = try #require(shell.preparedConversation)
        #expect(prepared.draft == "What is this?\n\nShared text\n\n\(Fixture.serverURL.absoluteString)")
        #expect(shared.inbox.entry(id: entry.id) == nil)

        // A share the extension couldn't open Theseus for waits until the app is active.
        let waiting = try shared.inbox.add([.text("Later")])
        shell.navigate(to: .chatsList)
        shell.openWaitingShare()
        #expect(shell.preparedConversation?.draft == "Later")
        #expect(shared.inbox.pending().isEmpty)
        #expect(shared.inbox.entry(id: waiting.id) == nil)

        // Delivered twice (URL and activation): the second time changes nothing.
        let shown = shell.preparedConversation
        shell.open(.sharedItems(waiting.id))
        #expect(shell.preparedConversation === shown)
        await shell.tearDown()
    }

    @Test func sharedFilesBecomeAttachmentsOnceAModelIsChosen() async throws {
        let shell = try makeShell()
        await shell.refresh()
        let entry = try shared.inbox.add([.file(Data("%PDF-1.4".utf8), filename: "Report.pdf", contentType: "application/pdf")])
        shell.open(.sharedItems(entry.id))
        let prepared = try #require(shell.preparedConversation)
        prepared.composer.select(try #require(shell.models.first).id)
        let deadline = ContinuousClock.now + .seconds(5)
        while prepared.composer.attachments.isEmpty, prepared.composer.notice == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Either it's attached (and uploading), or the composer says why this model can't take it.
        #expect(prepared.composer.attachments.map(\.name) == ["Report.pdf"] || prepared.composer.notice != nil)
        #expect(shared.inbox.pending().isEmpty)
        await shell.tearDown()
    }

    @Test func appModelOpensLinksAfterSignIn() async throws {
        var environment = AppEnvironment.ephemeral(transport: transport)
        environment.asksForAIDataConsent = false
        let model = AppModel(environment: environment)
        #expect(model.open(url: try #require(URL(string: "theseus://chat/abc"))))
        #expect(!model.open(url: try #require(URL(string: "https://example.com"))))
    }
}
