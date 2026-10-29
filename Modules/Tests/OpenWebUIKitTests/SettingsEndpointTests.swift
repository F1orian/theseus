import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Settings endpoints (SET-*): user settings and the `theseus.*` namespace, personal usage, the
/// admin contact and Shared links. Request shape and decoding of recorded fixtures.
@Suite("Settings endpoints")
struct SettingsEndpointTests {
    private func decode<R>(_ endpoint: Endpoint<R>, fixture: String) throws -> R {
        try endpoint.decode(Fixture.data(fixture))
    }

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    }

    // MARK: User settings

    @Test func userSettingsAreReadRawSoServerDefaultsAreNotMixedIn() throws {
        let url = request(.userSettings).url
        #expect(url?.absoluteString == "https://owui.example.com/api/v1/users/user/settings?raw=true")

        let settings = try decode(.userSettings, fixture: "user-settings.json")
        #expect(settings.raw["ui"]?[path: "hapticFeedback"]?.boolValue == true)
        #expect(settings.theseus.isEmpty, "the web client never writes the theseus namespace")
    }

    @Test func usersWithoutSettingsDecodeAsEmpty() throws {
        let settings = try Endpoint<UserSettings>.userSettings.decode(Data("null".utf8))
        #expect(settings.raw.isEmpty)
    }

    @Test func updatesSendOnlyTheTheseusNamespace() throws {
        let update = request(.updateTheseusSettings(["capabilities": .object(["webSearch": .bool(true)])]))
        #expect(update.httpMethod == "POST")
        #expect(update.url?.path() == "/api/v1/users/user/settings/update")
        // The server merges top-level keys, so omitting `ui` leaves the web client's settings alone.
        #expect(try body(update) == .object(["theseus": .object(["capabilities": .object(["webSearch": .bool(true)])])]))
    }

    @Test func capabilityDefaultsRoundTripThroughTheNamespace() throws {
        var defaults = CapabilityDefaults()
        #expect(defaults.artifacts && !defaults.webSearch && !defaults.codeInterpreter && !defaults.imageGeneration)
        defaults.webSearch = true
        defaults.artifacts = false

        var namespace: [String: JSONValue] = ["nickname": .string("Ada")]
        namespace[CapabilityDefaults.namespaceKey] = try defaults.jsonValue()
        let settings = UserSettings(raw: ["theseus": .object(namespace)])
        #expect(settings.capabilityDefaults == defaults)
        #expect(settings.theseus["nickname"] == .string("Ada"))
    }

    @Test func missingOrPartialCapabilityDefaultsFallBackPerKey() throws {
        let settings = UserSettings(raw: ["theseus": .object(["capabilities": .object(["webSearch": .bool(true)])])])
        #expect(settings.capabilityDefaults.webSearch)
        #expect(settings.capabilityDefaults.artifacts, "unset keys keep their defaults")
        #expect(UserSettings(raw: [:]).capabilityDefaults == CapabilityDefaults())
    }

    // MARK: Usage and admin contact

    @Test func usageDecodesTotalsAndTopModels() throws {
        #expect(request(.usage).url?.path() == "/api/v1/users/usage")
        let usage = try decode(.usage, fixture: "users.usage.json")
        #expect(usage.totals.chats == 42)
        #expect(usage.totals.messages == 400)
        #expect(usage.totals.lifetimeTokens == 120_000)
        #expect(usage.totals.activeDays == 30)
        #expect(usage.totals.currentStreak == 3)
        #expect(usage.topModels.first?.modelID == "claude-sonnet-5-5")
        #expect(usage.topModels.first?.messages == 200)
        #expect(usage.periodDays == 730)
    }

    @Test func adminContactDecodes() throws {
        #expect(request(.adminContact).url?.path() == "/api/v1/auths/admin/details")
        let contact = try decode(.adminContact, fixture: "admin-details.json")
        #expect(contact == AdminContact(name: "Server Admin", email: "admin@example.com"))
    }

    // MARK: Shared links

    @Test func sharedChatsListDecodes() throws {
        #expect(request(.sharedChats(page: 2)).url?.absoluteString == "https://owui.example.com/api/v1/chats/shared?page=2")
        let shared = try decode(.sharedChats(page: 1), fixture: "chats.shared.json")
        let link = try #require(shared.first)
        #expect(link.chatID == "00000000-0000-4000-8000-000000000210")
        #expect(link.shareID == "00000000-0000-4000-8000-000000000211")
        #expect(link.title == "[theseus-test] shared")
        #expect(link.updatedAt == Date(timeIntervalSince1970: 1_792_784_079))
    }

    @Test func sharedSnapshotDecodesTheActivePath() throws {
        let path = request(.sharedChatSnapshot(shareID: "abc")).url?.path()
        #expect(path == "/api/v1/chats/share/abc")
        let snapshot = try decode(.sharedChatSnapshot(shareID: "abc"), fixture: "chat.shared-snapshot.json")
        #expect(snapshot.title == "[theseus-test] shared")
        #expect(snapshot.messages.map(\.role) == [.user, .assistant])
        #expect(snapshot.messages.first?.content == "Plan a short walk")
        #expect(snapshot.messages.last?.content == "**Route:** the park loop, about 30 minutes.")
        #expect(snapshot.sharedByName == "Test User")
    }

    @Test func unshareTargetsTheChat() throws {
        let unshare = request(.unshareChat(chatID: "c1"))
        #expect(unshare.httpMethod == "DELETE")
        #expect(unshare.url?.path() == "/api/v1/chats/c1/share")
        #expect(try decode(.unshareChat(chatID: "c1"), fixture: "chat.unshare.json"))

        let all = request(.unshareAllChats)
        #expect(all.httpMethod == "DELETE")
        #expect(all.url?.path() == "/api/v1/chats/share/all")
    }

    @Test func shareURLUsesTheServerWebRoute() {
        let link = SharedChatLink(chatID: "c", shareID: "s1", title: "T", updatedAt: .now, createdAt: .now)
        #expect(link.url(server: Fixture.serverURL).absoluteString == "https://owui.example.com/s/s1")
    }
}

/// The read-modify-write of the `theseus` namespace through a live-like client.
@Suite("User settings read-modify-write")
struct TheseusSettingsUpdateTests {
    struct Token: RequestAuthorizer {
        func currentToken() async -> String? { "jwt" }
        func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
    }

    @Test func otherNamespaceKeysSurviveAnUpdate() async throws {
        let transport = StubTransport()
        let stored = JSONValue.object([
            "ui": .object(["memory": .bool(true)]),
            "theseus": .object(["nickname": .string("Ada")]),
        ])
        transport.stub("GET", "api/v1/users/user/settings", body: try JSONEncoder().encode(stored))
        transport.stub("POST", "api/v1/users/user/settings/update") { request in
            (200, request.httpBody ?? Data())
        }
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: Token())

        _ = try await client.updateTheseusSettings { namespace in
            namespace["capabilities"] = .object(["webSearch": .bool(true)])
        }

        let post = try #require(transport.requests.last)
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(post.httpBody))
        #expect(sent == .object(["theseus": .object([
            "nickname": .string("Ada"),
            "capabilities": .object(["webSearch": .bool(true)]),
        ])]))
        #expect(sent[path: "ui"] == nil, "never re-sends the web client's ui settings")
    }
}

/// Capabilities that gate Settings rows (SET-01).
@Suite("Settings Capabilities")
struct SettingsCapabilityTests {
    func user(_ permissions: [String: [String: Bool]]) -> SessionUser {
        SessionUser(
            id: "u", name: "U", email: "u@example.com", role: .user,
            permissions: UserPermissions(raw: .object(permissions.mapValues { .object($0.mapValues(JSONValue.bool)) }))
        )
    }

    @Test func instructionsNeedChatControlsAndSystemPromptPermissions() throws {
        let features = try Endpoint.config.decode(Fixture.data("config.json")).features
        let both = user(["chat": ["controls": true, "system_prompt": true]])
        let onlyPrompt = user(["chat": ["system_prompt": true]])
        #expect(Capabilities.resolve(features: features, user: both, model: nil).contains(.instructions))
        #expect(!Capabilities.resolve(features: features, user: onlyPrompt, model: nil).contains(.instructions))
        let admin = SessionUser(id: "a", name: "A", email: "a@example.com", role: .admin)
        #expect(Capabilities.resolve(features: features, user: admin, model: nil).contains(.instructions))
    }
}
