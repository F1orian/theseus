@testable import AppFeature
import AppIntentsFeature
import Auth
import Entitlements
import Fixtures
import Foundation
import OpenWebUIKit
import Persistence
import Testing

/// Theseus Pro in the shell (ADR 0173): widgets, Shortcuts, the Share sheet and links wait for
/// Pro in the free tier; keyboard shortcuts don't; the store reaches the composer, Settings and
/// the extensions' snapshot.
@MainActor
@Suite("Theseus Pro in the shell", .serialized)
struct ProGateShellTests {
    let transport = StubTransport()
    let shared = SharedStateStore(container: .temporary())
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    func makeShell(pro: ProStore) throws -> MainShellModel {
        var user = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("auths.json")).objectValue ?? [:]
        user["role"] = .string("user")
        transport.stub("GET", "api/v1/auths/", body: try JSONEncoder().encode(JSONValue.object(user)))
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        let shell = MainShellModel(
            account: account,
            client: OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: FixedTokenAuthorizer(token: "jwt")),
            database: nil,
            pro: pro,
            onSignOut: {}
        )
        shell.sharedState = shared
        return shell
    }

    @Test func theStoreReachesTheComposerAndSettings() async throws {
        let store = ProStore.free()
        let shell = try makeShell(pro: store)
        await shell.refresh()
        #expect(shell.chat?.composer.pro === store)
        shell.navigate(to: .settings)
        #expect(shell.settings?.pro === store)
        #expect(shell.sharedSnapshot?.isProUnlocked == false)
        await shell.tearDown()
    }

    @Test func aFreeTierLinkOpensThePaywallAndWaits() async throws {
        let backend = InMemoryProBackend()
        let store = ProStore(backend: backend)
        await store.start()
        let shell = try makeShell(pro: store)
        await shell.refresh()
        shell.navigate(to: .chatsList)

        shell.open(.newChat(.init(prompt: "From a widget")))
        #expect(shell.paywallRequest == PaywallRequest(.platform))
        #expect(shell.route == .chatsList)
        #expect(shell.preparedConversation == nil)

        // Unlocking in the paywall opens the link when it closes.
        await store.purchase()
        shell.paywallRequest = nil
        shell.paywallDismissed()
        #expect(shell.route == .newChat())
        #expect(shell.preparedConversation?.draft == "From a widget")
        await shell.tearDown()
    }

    @Test func aDeclinedShareIsDroppedSoThePaywallDoesntReturn() async throws {
        let shell = try makeShell(pro: .free())
        await shell.refresh()
        let entry = try shared.inbox.add([.text("Shared text")])
        shell.open(.sharedItems(entry.id))
        #expect(shell.paywallRequest == PaywallRequest(.platform))
        shell.paywallRequest = nil
        shell.paywallDismissed()
        #expect(shared.inbox.entry(id: entry.id) == nil)
        #expect(shell.preparedConversation == nil)
        // Becoming active again finds nothing to open.
        shell.openWaitingShare()
        #expect(shell.paywallRequest == nil)
        await shell.tearDown()
    }

    @Test func keyboardShortcutsStayFree() async throws {
        let shell = try makeShell(pro: .free())
        await shell.refresh()
        shell.navigate(to: .chatsList)
        shell.perform(.newChat)
        #expect(shell.paywallRequest == nil)
        #expect(shell.route == .newChat())
        await shell.tearDown()
    }

    @Test func theProLinkOpensThePaywallEvenWithPro() async throws {
        let shell = try makeShell(pro: .unlocked())
        await shell.refresh()
        shell.open(.pro)
        #expect(shell.paywallRequest == PaywallRequest())
        await shell.tearDown()
    }

    @Test func proLetsLinksThrough() async throws {
        let shell = try makeShell(pro: .unlocked())
        await shell.refresh()
        shell.open(.newChat(.init(prompt: "Hi")))
        #expect(shell.paywallRequest == nil)
        #expect(shell.preparedConversation?.draft == "Hi")
        #expect(shell.sharedSnapshot?.isProUnlocked == true)
        await shell.tearDown()
    }

    // MARK: What the Server offers (ADR 0173 addendum)

    @Test func aServerWithoutCodeExecutionOrSkillsSaysSo() async throws {
        // The recorded Server runs Pyodide (no server-side interpreter) and lists no terminals here.
        let shell = try makeShell(pro: .free())
        #expect(shell.serverSupport == .unknown, "unknown until loaded")
        transport.stub("GET", "api/v1/skills/", status: 403, body: Data(#"{"detail":"Forbidden"}"#.utf8))
        await shell.refresh()
        await shell.chat?.composer.refresh()
        #expect(shell.serverSupport.codeExecution == ServerSupport.CodeExecution.none)
        #expect(shell.serverSupport.skills == false)
        await shell.tearDown()
    }

    @Test func aServerWithASandboxAndSkillsOffersBoth() async throws {
        let shell = try makeShell(pro: .free())
        try transport.stub("GET", "api/v1/terminals/", fixture: "stream/sandbox.terminals.json")
        try transport.stub("GET", "api/v1/skills/", fixture: "skills.json")
        try transport.stub("GET", "api/v1/tools/", fixture: "synthetic/tools.mixed.json")
        await shell.refresh()
        await shell.chat?.composer.refresh()
        await shell.connectors.loadAccess()
        await shell.connectors.load()
        #expect(shell.serverSupport == ServerSupport(codeExecution: .sandbox, skills: true, connectors: true))
        await shell.tearDown()
    }

    @Test func personalConnectorsGoOutOnlyWithPro() async throws {
        let personal = FakeDirectTools(payload: [.object(["url": .string("https://tools.example")])])
        let free = ProGatedDirectTools(base: personal, pro: .free())
        #expect(await free.toolServersPayload().isEmpty)
        let pro = ProGatedDirectTools(base: personal, pro: .unlocked())
        #expect(await pro.toolServersPayload().count == 1)
    }

    @Test func theProLinkRoundTrips() throws {
        #expect(DeepLink(url: DeepLink.pro.url) == .pro)
        #expect(DeepLink.pro.url.absoluteString == "theseus://pro")
    }
}

private struct FakeDirectTools: DirectToolServers {
    let payload: [JSONValue]
    func toolServersPayload() async -> [JSONValue] { payload }
    func execute(_ call: DirectToolCall) async -> JSONValue { .null }
}
