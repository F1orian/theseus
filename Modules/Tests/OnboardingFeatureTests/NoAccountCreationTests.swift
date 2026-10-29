import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// ADR 0170: Theseus signs in to existing Accounts only. App Store apps that create accounts must
/// also delete them in-app, and Open WebUI only lets admins delete users.
@MainActor
@Suite("No account creation")
struct NoAccountCreationTests {
    let transport = StubTransport()
    let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")

    func form(_ configJSON: String) throws -> SignInModel {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(configJSON.utf8))
        let flow = OnboardingFlow(start: .signIn(server: server, config: config), transport: transport) { _ in }
        return try #require(flow.signInModel)
    }

    @Test func serversThatAllowSignUpStillGetTheSignInForm() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let model = try form(#"{"name":"S","version":"0.12.3","features":{"enable_login_form":true,"enable_signup":true}}"#)
        model.email = "user@example.com"
        model.submitIdentifier()
        model.password = "pw"
        await model.signIn()
        #expect(transport.requests.map { $0.url?.path() } == ["/api/v1/auths/signin"])
    }

    @Test func aBrandNewServerIsNotSetUpFromTheApp() throws {
        let model = try form(#"{"name":"S","version":"0.12.3","onboarding":true,"features":{"enable_login_form":true}}"#)
        #expect(model.methods.isFirstRun)
        #expect(transport.requests.isEmpty)
    }
}
