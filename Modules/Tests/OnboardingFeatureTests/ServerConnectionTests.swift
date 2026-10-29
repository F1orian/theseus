import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// AUTH-01: entering a Server address, validating it and reading its sign-in methods.
@MainActor
@Suite("Server connection")
struct ServerConnectionTests {
    let transport = StubTransport()

    init() throws {
        try transport.stub("GET", "api/config", fixture: "config.public.json")
    }

    func connect(_ address: String, transport: any HTTPTransport) async throws -> (OnboardingFlow, ServerEntryModel) {
        let flow = OnboardingFlow(start: .serverEntry(), transport: transport) { _ in }
        guard case .serverEntry(let entry) = flow.step else { throw FlowError.unexpectedStep }
        entry.address = address
        await entry.connect()
        return (flow, entry)
    }

    @Test func validServerMovesToSignInWithItsNameVersionAndMethods() async throws {
        let (flow, entry) = try await connect("owui.example.com/", transport: transport)
        #expect(entry.errorMessage == nil)
        let signIn = try #require(flow.signInModel)
        #expect(signIn.server == ServerProfile(url: Fixture.serverURL, name: "Open WebUI"))
        #expect(signIn.serverVersion == "0.12.3")
        #expect(signIn.methods == SignInMethods(password: true))
    }

    @Test func serversOlderThan012AreRejectedWithTheirVersion() async throws {
        transport.stub("GET", "api/config", body: Data(#"{"name":"Old WebUI","version":"0.6.41","features":{}}"#.utf8))
        let (flow, entry) = try await connect("owui.example.com", transport: transport)
        #expect(entry.errorMessage?.contains("0.6.41") == true)
        #expect(entry.errorMessage?.contains("0.12") == true)
        #expect(flow.signInModel == nil)
    }

    @Test func plainHTTPIsTriedWhenNoSchemeWasTypedAndHTTPSIsUnreachable() async throws {
        let failing = HTTPSUnreachableTransport(wrapping: transport)
        let (flow, entry) = try await connect("192.168.1.5:8080", transport: failing)
        #expect(entry.errorMessage == nil)
        let signIn = try #require(flow.signInModel)
        #expect(signIn.server.url.absoluteString == "http://192.168.1.5:8080")
    }

    @Test func anExplicitHTTPSAddressNeverFallsBackToHTTP() async throws {
        let failing = HTTPSUnreachableTransport(wrapping: transport)
        let (_, entry) = try await connect("https://192.168.1.5:8080", transport: failing)
        #expect(entry.errorMessage == OpenWebUIError.transport(.cannotConnectToHost).message)
        #expect(transport.requests.isEmpty)
    }

    @Test func certificateProblemsDoNotDowngradeToHTTP() async throws {
        let failing = HTTPSUnreachableTransport(wrapping: transport, error: .serverCertificateUntrusted)
        let (_, entry) = try await connect("owui.example.com", transport: failing)
        #expect(entry.errorMessage == OpenWebUIError.transport(.serverCertificateUntrusted).message)
        #expect(transport.requests.isEmpty)
    }

    @Test func htmlInsteadOfTheAPIIsNotOpenWebUI() async throws {
        transport.stub("GET", "api/config", body: Data("<html>login</html>".utf8))
        let (_, entry) = try await connect("owui.example.com", transport: transport)
        #expect(entry.errorMessage == OpenWebUIError.notOpenWebUI.message)
    }

    @Test(arguments: [
        (#"{"enable_login_form":true,"enable_ldap":true}"#, SignInMethods(password: true, ldap: true)),
        (#"{"enable_login_form":false}"#, SignInMethods()),
        (#"{"auth":false}"#, SignInMethods(requiresAuth: false)),
        (#"{"auth_trusted_header":true,"enable_login_form":false}"#, SignInMethods(trustedHeader: true)),
        (#"{"enable_signup":true}"#, SignInMethods(password: true)),
    ])
    func signInMethodsComeFromTheServerConfig(features: String, expected: SignInMethods) throws {
        let json = #"{"name":"S","version":"0.12.3","features":"# + features + "}"
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        #expect(SignInMethods(config: config) == expected)
    }

    @Test func ssoProvidersAreSortedByDisplayName() throws {
        let json = #"""
        {"name":"S","version":"0.12.3","features":{"enable_login_form":false},
         "oauth":{"providers":{"oidc":"Company SSO","google":"Google","github":"GitHub"}}}
        """#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        let methods = SignInMethods(config: config)
        #expect(methods.ssoProviders.map(\.id) == ["oidc", "github", "google"])
        #expect(methods.ssoProviders.first?.name == "Company SSO")
        #expect(methods.hasAnyMethod)
    }
}

enum FlowError: Error { case unexpectedStep }

extension OnboardingFlow {
    var signInModel: SignInModel? {
        if case .signIn(let model) = step { model } else { nil }
    }
}

/// Fails every https request with a transport error; forwards http to the wrapped stub.
struct HTTPSUnreachableTransport: HTTPTransport {
    let wrapping: StubTransport
    var error: URLError.Code = .cannotConnectToHost

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.scheme == "https" { throw OpenWebUIError.transport(error) }
        return try await wrapping.send(request)
    }
}
