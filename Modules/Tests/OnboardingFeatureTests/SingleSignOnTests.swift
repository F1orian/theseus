import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// AUTH-04: single sign-on pills and the web sheet's cookie capture (ADR 0014).
@MainActor
@Suite("Single sign-on")
struct SingleSignOnTests {
    let transport = StubTransport()
    let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")

    final class Recorder {
        var sessions: [AuthenticatedSession] = []
        var flow: OnboardingFlow?
    }

    func signIn(providers: String = #"{"oidc":"Company SSO"}"#, features: String = #"{"enable_login_form":true}"#, recorder: Recorder) throws -> SignInModel {
        let json = #"{"name":"Open WebUI","version":"0.12.3","oauth":{"providers":"# + providers + #"},"features":"# + features + "}"
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        let flow = OnboardingFlow(start: .signIn(server: server, config: config), transport: transport) { recorder.sessions.append($0) }
        recorder.flow = flow
        return try #require(flow.signInModel)
    }

    func tokenCookie(_ value: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.name: "token", .value: value, .domain: "owui.example.com", .path: "/"]))
    }

    @Test func aProviderPillOpensItsLoginInTheSheet() throws {
        let model = try signIn(recorder: Recorder())
        let provider = try #require(model.methods.ssoProviders.first)
        model.startSSO(provider)
        let sheet = try #require(model.webSignIn)
        #expect(sheet.title == "Company SSO")
        #expect(sheet.webSignIn.startURL.absoluteString == "https://owui.example.com/oauth/oidc/login")
        #expect(sheet.pageHost == "owui.example.com")
    }

    @Test func theCapturedCookieIsValidatedAndSignsIn() async throws {
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        let recorder = Recorder()
        let model = try signIn(recorder: recorder)
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        let sheet = try #require(model.webSignIn)

        await sheet.observe(url: URL(string: "https://login.idp.example/authorize"), cookies: [])
        #expect(sheet.pageHost == "login.idp.example")
        #expect(recorder.sessions.isEmpty)

        await sheet.observe(url: URL(string: "https://owui.example.com/auth"), cookies: [try tokenCookie("sso-jwt")])
        #expect(recorder.sessions.map(\.token) == ["eyJhbGciOiJIUzI1NiJ9.c2NydWJiZWQ.c2NydWJiZWQ"], "the Server echoes the token it validated")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sso-jwt")
        #expect(model.webSignIn == nil, "the sheet closes")
    }

    @Test func laterReportsAfterCaptureAreIgnored() async throws {
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        let recorder = Recorder()
        let model = try signIn(recorder: recorder)
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        let sheet = try #require(model.webSignIn)
        await sheet.observe(url: nil, cookies: [try tokenCookie("a")])
        await sheet.observe(url: nil, cookies: [try tokenCookie("a")])
        #expect(recorder.sessions.count == 1)
    }

    @Test func serverErrorsCloseTheSheetAndShowTheMessage() async throws {
        let model = try signIn(recorder: Recorder())
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        await model.webSignIn?.observe(url: URL(string: "https://owui.example.com/auth?error=Your%20email%20domain%20isn%27t%20allowed"), cookies: [])
        #expect(model.webSignIn == nil)
        #expect(model.errorMessage == "Your email domain isn't allowed")
    }

    @Test func pendingSSOAccountsSeeTheApprovalScreen() async throws {
        let recorder = Recorder()
        let model = try signIn(recorder: recorder)
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        await model.webSignIn?.observe(url: URL(string: "https://owui.example.com/auth?pending=1"), cookies: [])
        guard case .pendingApproval = recorder.flow?.step else {
            Issue.record("Expected the approval screen")
            return
        }
    }

    @Test func cancellingClosesTheSheetQuietly() async throws {
        let model = try signIn(recorder: Recorder())
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        await model.webSignIn?.cancel()
        #expect(model.webSignIn == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func pageLoadFailuresAreExplained() async throws {
        let model = try signIn(recorder: Recorder())
        model.startSSO(SignInMethods.SSOProvider(id: "oidc", name: "Company SSO"))
        await model.webSignIn?.loadFailed(URLError(.notConnectedToInternet))
        #expect(model.errorMessage == OpenWebUIError.transport(.notConnectedToInternet).message)
    }

    @Test func trustedHeaderServersSignInThroughTheirWebPage() throws {
        let model = try signIn(providers: "{}", features: #"{"enable_login_form":false,"auth_trusted_header":true}"#, recorder: Recorder())
        #expect(model.methods.trustedHeader)
        #expect(!model.showsCredentialForm)
        model.startWebPageSignIn()
        #expect(model.webSignIn?.webSignIn.startURL.absoluteString == "https://owui.example.com/auth")
    }

    @Test func ssoOnlyServersStillOfferSignIn() throws {
        let model = try signIn(features: #"{"enable_login_form":false}"#, recorder: Recorder())
        #expect(model.methods.hasAnyMethod)
        #expect(!model.showsCredentialForm)
    }
}
