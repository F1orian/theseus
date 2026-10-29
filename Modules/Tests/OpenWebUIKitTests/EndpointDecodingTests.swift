import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Decodes every recorded fixture through its typed endpoint.
@Suite("Endpoint decoding (recorded fixtures)")
struct EndpointDecodingTests {
    private func decode<R>(_ endpoint: Endpoint<R>, fixture: String) throws -> R {
        try endpoint.decode(Fixture.data(fixture))
    }

    @Test func publicConfigHasOnlySignInFlags() throws {
        let config = try decode(.config, fixture: "config.public.json")
        #expect(config.version == "0.12.3")
        #expect(config.name == "Open WebUI")
        #expect(config.isOnboarding == false)
        #expect(config.oauthProviders.isEmpty)
        #expect(config.features.requiresAuth)
        #expect(config.features.allowsPasswordSignIn)
        #expect(config.features.allowsSignUp == false)
        #expect(config.features.supportsWebSocket)
        // Feature flags are only sent to authenticated callers.
        #expect(config.features.isEnabled("enable_web_search") == false)
        #expect(config.defaultModelIDs.isEmpty)
    }

    @Test func authenticatedConfigHasFeatureFlagsAndDefaults() throws {
        let config = try decode(.config, fixture: "config.json")
        #expect(config.features.isEnabled("enable_web_search"))
        #expect(config.features.isEnabled("enable_folders"))
        #expect(config.features.isEnabled("enable_image_generation") == false)
        #expect(config.features.raw["web_search_confirmation_content"]?.stringValue != nil)
        #expect(config.defaultModelIDs.count == 1)
    }

    @Test func version() throws {
        let version = try decode(.version, fixture: "version.json")
        #expect(version.version == "0.12.3")
        #expect(version.components == [0, 12, 3])
        #expect(version.isAtLeast("0.12.0"))
        #expect(version.isAtLeast("0.12.3"))
        #expect(version.isAtLeast("0.12.4") == false)
        #expect(version.isAtLeast("1") == false)
        #expect(ServerVersion(version: "0.13.0-dev").components == [0, 13, 0])
    }

    @Test func signInSession() throws {
        let result = try decode(.signIn(email: "a@b.c", password: "x"), fixture: "signin.json")
        guard case .session(let user) = result else {
            Issue.record("Expected a session, got \(result)")
            return
        }
        #expect(user.role == .admin)
        #expect(user.email == "user@example.com")
        #expect(user.token?.isEmpty == false)
        #expect(user.expiresAt != nil)
        #expect(user.profileImagePath?.hasPrefix("/api/v1/users/") == true)
        #expect(user.permissions.allows("chat.file_upload"))
        #expect(user.permissions.allows("features.api_keys") == false)
        #expect(user.permissions.allows("does.not.exist") == false)
    }

    @Test(arguments: [
        ("synthetic/signin.mfa-verify.json", MFAChallenge.Step.verify, 300.0),
        ("synthetic/signin.mfa-enroll.json", .enroll, 600),
        ("synthetic/signin.mfa-recover.json", .recover, 300),
    ])
    func signInMFAChallenge(fixture: String, step: MFAChallenge.Step, expiresIn: Double) throws {
        let result = try decode(.signIn(email: "a@b.c", password: "x"), fixture: fixture)
        guard case .mfaRequired(let challenge) = result else {
            Issue.record("Expected an MFA challenge, got \(result)")
            return
        }
        #expect(challenge.step == step)
        #expect(challenge.expiresIn == expiresIn)
        #expect(challenge.challengeToken.count >= 20)
    }

    @Test func signInPendingApproval() throws {
        let result = try decode(.signIn(email: "a@b.c", password: "x"), fixture: "synthetic/signin.pending.json")
        #expect(result == .pendingApproval)
    }

    @Test func signInRejectsUnknownNextStep() {
        let body = Data(#"{"next_step":"teleport","challenge_token":"x","expires_in":1}"#.utf8)
        #expect(throws: DecodingError.self) { try Endpoint.signIn(email: "", password: "").decode(body) }
    }

    @Test func signInRejectsSessionWithoutToken() {
        let body = Data(#"{"id":"1","name":"n","email":"e","role":"user"}"#.utf8)
        #expect(throws: DecodingError.self) { try Endpoint.signIn(email: "", password: "").decode(body) }
    }

    @Test func sessionUser() throws {
        let user = try decode(.sessionUser, fixture: "auths.json")
        #expect(user.id == "00000000-0000-4000-8000-000000000001")
        #expect(user.name == "Test User")
        #expect(user.role == .admin)
        #expect(user.permissions.allows("chat.temporary"))
    }

    @Test func models() throws {
        let models = try decode(.models, fixture: "models.json")
        #expect(models.count == 5)
        #expect(models.map(\.id).contains("claude-opus-5-5"))
        let first = try #require(models.first)
        #expect(first.name.isEmpty == false)
        #expect(first.tags == ["Anthropic"])
        #expect(first.capabilities.supports("vision"))
        #expect(first.capabilities.supports("an_unknown_capability"), "missing keys count as supported")
        #expect(first.defaultFeatureIDs == ["web_search"])
        #expect(models.allSatisfy { !$0.isHidden })
    }

    @Test func chatsPage() throws {
        let chats = try decode(.chats(page: 1), fixture: "chats.page-1.json")
        #expect(chats.count == Endpoint<[ChatSummary]>.chatsPageSize)
        let first = try #require(chats.first)
        #expect(first.title == "Chat 1")
        #expect(first.isArchived == false)
        #expect(first.updatedAt >= first.createdAt)
        #expect(chats.map(\.updatedAt) == chats.map(\.updatedAt).sorted(by: >), "newest first")
    }

    @Test func jsonValueRoundTripsAndResolvesPaths() throws {
        let data = Data(#"{"a":{"b":[1,true,null,"s"]},"c":1.5}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value[path: "a.b"] == .array([.number(1), .bool(true), .null, .string("s")]))
        #expect(value[path: "c"] == .number(1.5))
        #expect(value[path: "a.missing"] == nil)
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(reencoded == value)
    }
}
