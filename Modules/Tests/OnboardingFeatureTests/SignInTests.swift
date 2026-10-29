import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// AUTH-02: the sign-in screen, driven by the Server's config.
@MainActor
@Suite("Sign-in screen")
struct SignInTests {
    let transport = StubTransport()
    let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")

    /// Records the sessions the flow hands to the app, and keeps the flow alive like the app does.
    final class Recorder {
        var sessions: [AuthenticatedSession] = []
        var flow: OnboardingFlow?
    }

    func flow(config: ServerConfig?, email: String = "", recorder: Recorder = Recorder()) throws -> SignInModel {
        let flow = OnboardingFlow(start: .signIn(server: server, config: config, email: email), transport: transport) {
            recorder.sessions.append($0)
        }
        recorder.flow = flow
        return try #require(flow.signInModel)
    }

    func config(features: String, providers: String = "{}") throws -> ServerConfig {
        let json = #"{"name":"Open WebUI","version":"0.12.3","oauth":{"providers":"# + providers + #"},"features":"# + features + "}"
        return try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
    }

    @Test func emailStepRevealsThePasswordField() throws {
        let model = try flow(config: nil)
        #expect(!model.showsPasswordField)
        #expect(!model.canSubmitIdentifier)

        model.email = "not an email"
        model.submitIdentifier()
        #expect(model.errorMessage == "Enter a valid email address.")
        #expect(!model.showsPasswordField)

        model.email = "admin@localhost"
        model.submitIdentifier()
        #expect(model.errorMessage == nil)
        #expect(model.showsPasswordField)
    }

    @Test func aPrefilledEmailGoesStraightToThePassword() throws {
        let model = try flow(config: nil, email: "user@example.com")
        #expect(model.showsPasswordField)
    }

    @Test func passwordSignInHandsTheSessionToTheApp() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let recorder = Recorder()
        let model = try flow(config: nil, email: "user@example.com", recorder: recorder)
        model.password = "secret"
        await model.signIn()
        #expect(recorder.sessions.map(\.account.email) == ["user@example.com"])
        #expect(model.password.isEmpty, "the password doesn't linger in memory")
    }

    @Test func ldapModeSignsInWithTheDirectoryUsername() async throws {
        try transport.stub("POST", "api/v1/auths/ldap", fixture: "signin.json")
        let recorder = Recorder()
        let model = try flow(config: config(features: #"{"enable_login_form":true,"enable_ldap":true}"#), recorder: recorder)
        #expect(model.methods.ldap)
        model.setMode(.ldap)
        model.email = " jdoe "
        model.submitIdentifier()
        #expect(model.showsPasswordField, "usernames aren't checked for an @")
        model.password = "pw"
        await model.signIn()

        let body = try JSONDecoder().decode([String: String].self, from: try #require(transport.requests.last?.httpBody))
        #expect(body == ["user": "jdoe", "password": "pw"])
        #expect(recorder.sessions.count == 1)
    }

    @Test func ldapOnlyServersOpenInLDAPMode() async throws {
        transport.stub("GET", "api/config", body: Data(
            #"{"name":"Corp","version":"0.12.3","features":{"enable_login_form":false,"enable_ldap":true}}"#.utf8
        ))
        let model = try flow(config: nil)
        await model.loadConfigIfNeeded()
        #expect(model.mode == .ldap)
        #expect(model.server.name == "Open WebUI")
        #expect(model.serverVersion == "0.12.3")
    }

    @Test func noFormWhenTheAdminTurnedItOff() throws {
        let model = try flow(config: config(features: #"{"enable_login_form":false}"#))
        #expect(!model.showsCredentialForm)
        #expect(!model.methods.hasAnyMethod)
    }

    @Test func serversWithoutAuthenticationSignInWithoutCredentials() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let recorder = Recorder()
        let model = try flow(config: config(features: #"{"auth":false}"#), recorder: recorder)
        #expect(!model.showsCredentialForm)
        await model.continueWithoutAccount()
        #expect(recorder.sessions.count == 1)
    }

    @Test func rateLimitedSignInExplainsItself() async throws {
        transport.stub("POST", "api/v1/auths/signin", status: 429, body: Data(#"{"detail":"Too many"}"#.utf8))
        let model = try flow(config: nil, email: "user@example.com")
        model.password = "pw"
        await model.signIn()
        #expect(model.errorMessage == OpenWebUIError.rateLimited.message)
    }

    @Test func savingTheSessionCanFailVisibly() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let flow = OnboardingFlow(start: .signIn(server: server, email: "user@example.com"), transport: transport) { _ in
            throw CredentialStoreError.keychain(-25_300)
        }
        let model = try #require(flow.signInModel)
        model.password = "pw"
        await model.signIn()
        #expect(model.errorMessage == "Couldn't save your sign-in on this device.")
    }
}
