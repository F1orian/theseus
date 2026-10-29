import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Memory & personalization endpoints (PERS-*): the profile, Instructions and the Memory switch in
/// the user settings (ADR 0030), Memory entries, and what a Chat needs from all of them.
@Suite("Personalization endpoints")
struct PersonalizationEndpointTests {
    private func decode<R>(_ endpoint: Endpoint<R>, fixture: String) throws -> R {
        try endpoint.decode(Fixture.data(fixture))
    }

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    }

    private func client(_ transport: StubTransport) -> OpenWebUIClient {
        OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: FixedTokenAuthorizer())
    }

    // MARK: Profile (PERS-01)

    @Test func profileDecodesFromTheSessionUser() throws {
        #expect(request(.userProfile).url?.path() == "/api/v1/auths/")
        let profile = try decode(.userProfile, fixture: "auths.json")
        #expect(profile.name == "Test User")
        #expect(profile.profileImageURL == "/user.png")
        #expect(profile.bio == nil && profile.gender == nil && profile.dateOfBirth == nil)
    }

    @Test func profileUpdatesSendEveryFieldSoNothingIsCleared() throws {
        let profile = UserProfile(name: "Ada Lovelace", profileImageURL: "/user.png", bio: "Mathematician", gender: nil, dateOfBirth: "1815-12-10")
        let update = request(.updateProfile(profile))
        #expect(update.httpMethod == "POST")
        #expect(update.url?.path() == "/api/v1/auths/update/profile")
        // The server writes every form field, so omitted optional fields would be reset to null.
        #expect(try body(update) == .object([
            "name": .string("Ada Lovelace"),
            "profile_image_url": .string("/user.png"),
            "bio": .string("Mathematician"),
            "gender": .null,
            "date_of_birth": .string("1815-12-10"),
        ]))
        let stored = try decode(.updateProfile(profile), fixture: "profile.update.json")
        #expect(stored.name == "Test User")
    }

    @Test func renamingKeepsTheRestOfTheProfile() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/auths/", body: Data(#"""
            {"id":"u1","name":"Old","email":"a@b.c","role":"user","profile_image_url":"data:image/png;base64,AAAA",
             "bio":"Hi","gender":"female","date_of_birth":"1990-01-02"}
            """#.utf8))
        transport.stub("POST", "api/v1/auths/update/profile") { request in
            (200, request.httpBody ?? Data())
        }
        let stored = try await client(transport).updateProfileName("  New Name ")
        #expect(stored.name == "New Name")
        let sent = try body(try #require(transport.requests.last))
        #expect(sent[path: "profile_image_url"] == .string("data:image/png;base64,AAAA"))
        #expect(sent[path: "bio"] == .string("Hi"))
        #expect(sent[path: "gender"] == .string("female"))
        #expect(sent[path: "date_of_birth"] == .string("1990-01-02"))
    }

    // MARK: User settings (PERS-01/02/03)

    @Test func instructionsAndTheMemorySwitchAreReadFromTheWebClientKeys() throws {
        let settings = try decode(.userSettings, fixture: "user-settings.json")
        #expect(settings.instructions == "Instructions text")
        #expect(settings.memoryPreference == true)
        #expect(UserSettings(raw: [:]).instructions.isEmpty)
        #expect(UserSettings(raw: [:]).memoryPreference == nil)
    }

    @Test func sharedInterfaceUpdatesPatchOnlyTheNamedUIKeys() throws {
        let update = request(.updateSharedInterfaceSettings([.instructions: .string("Be brief.")]))
        #expect(update.httpMethod == "POST")
        #expect(update.url?.path() == "/api/v1/users/user/settings/update")
        // The server patches `ui` field by field, so the web client's other keys stay as they are.
        #expect(try body(update) == .object(["ui": .object(["system": .string("Be brief.")])]))

        let memory = request(.updateSharedInterfaceSettings([.memory: .bool(false)]))
        #expect(try body(memory) == .object(["ui": .object(["memory": .bool(false)])]))
    }

    @Test func nicknameLivesInTheTheseusNamespace() throws {
        let settings = UserSettings(raw: ["theseus": .object(["profile": .object(["nickname": .string("Ada")])])])
        #expect(settings.profilePreferences.nickname == "Ada")
        #expect(settings.nickname == "Ada")
        #expect(UserSettings(raw: ["theseus": .object(["profile": .object(["nickname": .string("  ")])])]).nickname == nil)
        #expect(UserSettings(raw: ["theseus": .null]).profilePreferences == ProfilePreferences())

        var preferences = ProfilePreferences()
        preferences.nickname = "Lovelace"
        #expect(try preferences.jsonValue() == .object(["nickname": .string("Lovelace")]))
    }

    // MARK: Memory entries (PERS-04)

    @Test func memoriesDecodeWithKindPathAndDates() throws {
        #expect(request(.memories).url?.path() == "/api/v1/memories/")
        let entries = try decode(.memories, fixture: "memories.json")
        #expect(entries.count == 2)
        let fact = try #require(entries.first)
        #expect(fact.kind == .user)
        #expect(fact.path == "preferences/units")
        #expect(fact.content == "[theseus-test] Prefers metric units")
        #expect(fact.updatedAt == Date(timeIntervalSince1970: 1_792_789_049))
        #expect(entries[1].kind == .context)
        #expect(entries[1].path == nil)
    }

    @Test func addingAMemorySendsContentKindAndPath() throws {
        let add = request(.addMemory(content: "Prefers metric units", kind: .user, path: "preferences/units"))
        #expect(add.httpMethod == "POST")
        #expect(add.url?.path() == "/api/v1/memories/add")
        #expect(try body(add) == .object([
            "content": .string("Prefers metric units"), "type": .string("user"), "path": .string("preferences/units"),
        ]))
        let noPath = request(.addMemory(content: "Likes tea", kind: .context, path: nil))
        #expect(try body(noPath) == .object(["content": .string("Likes tea"), "type": .string("context")]))
        let entry = try decode(.addMemory(content: "x", kind: .user, path: nil), fixture: "memory.add.json")
        #expect(entry.id == "00000000-0000-4000-8000-000000000301")
    }

    @Test func editingAMemoryAlwaysSendsThePathSoItCanBeCleared() throws {
        let edit = request(.updateMemory(id: "m1", content: "Prefers metric", path: nil))
        #expect(edit.httpMethod == "POST")
        #expect(edit.url?.path() == "/api/v1/memories/m1/update")
        // An empty path clears it on the server; a missing one would leave it unchanged.
        #expect(try body(edit) == .object(["content": .string("Prefers metric"), "path": .string("")]))
        let entry = try decode(.updateMemory(id: "m1", content: "x", path: nil), fixture: "memory.update.json")
        #expect(entry.content == "[theseus-test] Prefers metric units and 24-hour time")
    }

    @Test func deletingOneOrAllMemories() throws {
        let delete = request(.deleteMemory(id: "m1"))
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path() == "/api/v1/memories/m1")
        #expect(try decode(.deleteMemory(id: "m1"), fixture: "memory.delete.json"))

        let wipe = request(.forgetAllMemories)
        #expect(wipe.httpMethod == "DELETE")
        #expect(wipe.url?.path() == "/api/v1/memories/delete/user")
    }

    // MARK: What a Chat sends (PERS-01/02/03)

    @Test func chatPersonalizationUsesNicknameInstructionsAndMemory() {
        let user = SessionUser(id: "u1", name: "Ada Lovelace", email: "a@b.c", role: .user)
        let settings = UserSettings(raw: [
            "ui": .object(["system": .string("Be brief."), "memory": .bool(true)]),
            "theseus": .object(["profile": .object(["nickname": .string("Ada")])]),
        ])
        let personalization = ChatPersonalization(settings: settings, user: user, capabilities: Capabilities(enabled: [.memory]))
        #expect(personalization.preferredName == "Ada")
        #expect(personalization.instructions == "Be brief.")
        #expect(personalization.usesMemory)
        #expect(personalization.variables == ["{{USER_NAME}}": "Ada"])
    }

    @Test func chatPersonalizationFallsBack() {
        let user = SessionUser(id: "u1", name: "Ada Lovelace", email: "a@b.c", role: .user)
        let blank = UserSettings(raw: ["ui": .object(["system": .string("  ")]), "theseus": .object(["profile": .object(["nickname": .string(" ")])])])
        let withoutMemory = ChatPersonalization(settings: blank, user: user, capabilities: Capabilities(enabled: []))
        #expect(withoutMemory.preferredName == "Ada Lovelace")
        #expect(withoutMemory.instructions == nil)
        #expect(!withoutMemory.usesMemory, "Memory needs its Capability")

        let unset = ChatPersonalization(settings: UserSettings(raw: [:]), user: user, capabilities: Capabilities(enabled: [.memory]))
        #expect(unset.usesMemory, "like the web client, Memory is on until the user turns it off")
        let off = UserSettings(raw: ["ui": .object(["memory": .bool(false)])])
        #expect(!ChatPersonalization(settings: off, user: user, capabilities: Capabilities(enabled: [.memory])).usesMemory)
    }

    @Test func completionRequestsCarryInstructionsMemoryAndTheUserName() throws {
        let personalization = ChatPersonalization(instructions: "Be brief.", preferredName: "Ada", usesMemory: true)
        let request = CompletionRequest(
            chatID: "c1", modelID: "m", prompt: "Hi", features: ["web_search": false],
            history: [.init(role: .user, content: "earlier")], personalization: personalization
        )
        let socket = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.socketBody(request, sessionID: "s"))
        #expect(socket[path: "messages"] == .array([.object(["role": .string("system"), "content": .string("Be brief.")])]))
        #expect(socket[path: "features"] == .object(["web_search": .bool(false), "memory": .bool(true)]))
        #expect(socket[path: "variables"] == .object(["{{USER_NAME}}": .string("Ada")]))

        let sse = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.sseBody(request))
        guard case .array(let messages)? = sse[path: "messages"] else { Issue.record("no messages"); return }
        #expect(messages.map { $0[path: "role"]?.stringValue } == ["system", "user", "user"])
        #expect(sse[path: "features.memory"] == .bool(true))
        #expect(sse[path: "variables"] == .object(["{{USER_NAME}}": .string("Ada")]))
    }

    @Test func withoutPersonalizationTheRequestIsUnchanged() throws {
        let request = CompletionRequest(chatID: nil, modelID: "m", prompt: "Hi", features: ["web_search": true])
        let socket = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.socketBody(request, sessionID: "s"))
        #expect(socket[path: "messages"] == .array([]))
        #expect(socket[path: "features"] == .object(["web_search": .bool(true)]))
        #expect(socket[path: "variables"] == .object([:]))
        let quiet = CompletionRequest(
            chatID: nil, modelID: "m", prompt: "Hi",
            personalization: ChatPersonalization(instructions: nil, preferredName: "Ada", usesMemory: false)
        )
        let body = try JSONDecoder().decode(JSONValue.self, from: CompletionSession.socketBody(quiet, sessionID: "s"))
        #expect(body[path: "features.memory"] == nil, "Memory off sends no memory flag")
        #expect(body[path: "messages"] == .array([]))
    }
}

/// Always hands out the same token.
private struct FixedTokenAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}
