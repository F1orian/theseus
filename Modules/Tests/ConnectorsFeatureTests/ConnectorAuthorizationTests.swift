@testable import ConnectorsFeature
import Foundation
import Testing

/// The connect sheet's policy (CONN-03): when the Server's MCP OAuth flow is over.
@Suite("Connector authorization (CONN-03)")
struct ConnectorAuthorizationTests {
    private func authorization(server: String = "https://chat.example.com") -> ConnectorAuthorization {
        let server = URL(string: server) ?? URL(fileURLWithPath: "/")
        return ConnectorAuthorization(
            connectorID: "server:mcp:linear",
            name: "Linear",
            server: server,
            startURL: server.appending(path: "oauth/clients/mcp:linear/authorize"),
            sessionToken: "jwt"
        )
    }

    @Test func providerPagesAndTheServersOwnStepsContinue() {
        let flow = authorization()
        #expect(flow.event(at: flow.startURL) == .continue)
        #expect(flow.event(at: URL(string: "https://linear.app/oauth/authorize?client_id=x")) == .continue)
        #expect(flow.event(at: URL(string: "https://chat.example.com/oauth/clients/mcp:linear/callback?code=abc&state=s")) == .continue)
        #expect(flow.event(at: nil) == .continue)
        // The provider's own error page is just a page.
        #expect(flow.event(at: URL(string: "https://linear.app/?error=denied")) == .continue)
    }

    @Test func theRedirectHomeFinishes() {
        let flow = authorization()
        #expect(flow.event(at: URL(string: "https://chat.example.com/")) == .finished)
        #expect(flow.event(at: URL(string: "https://chat.example.com")) == .finished)
        #expect(flow.event(at: URL(string: "https://CHAT.example.com/")) == .finished)
    }

    @Test func errorsComeBackOnTheRoot() {
        let flow = authorization()
        #expect(flow.event(at: URL(string: "https://chat.example.com/?error=OAuth%20failed")) == .failed("OAuth failed"))
    }

    @Test func subPathDeploymentsFinishAtTheirBase() {
        let flow = authorization(server: "https://example.com/owui")
        #expect(flow.event(at: URL(string: "https://example.com/owui/")) == .finished)
        #expect(flow.event(at: URL(string: "https://example.com/")) == .continue)
        #expect(flow.event(at: URL(string: "https://example.com/owui/oauth/clients/mcp:linear/callback")) == .continue)
    }

    @Test func serverErrorsEndTheFlowButProviderErrorsDoNot() {
        let flow = authorization()
        #expect(flow.event(forResponseFrom: flow.startURL, status: 404) == .failed("The Server doesn't know this connector any more."))
        #expect(flow.event(forResponseFrom: flow.startURL, status: 401) == .failed("Your session has expired. Sign in again and retry."))
        if case .failed = flow.event(forResponseFrom: flow.startURL, status: 500) {} else { Issue.record("500 should fail") }
        #expect(flow.event(forResponseFrom: flow.startURL, status: 200) == .continue)
        #expect(flow.event(forResponseFrom: URL(string: "https://linear.app/login"), status: 401) == .continue)
    }

    @Test func plainHTTPServersGetANonSecureCookie() {
        let flow = authorization(server: "http://localhost:8765")
        #expect(flow.sessionCookie?.isSecure == false)
        #expect(flow.sessionCookie?.domain == "localhost")
        #expect(flow.event(at: URL(string: "http://localhost:8765/")) == .finished)
        #expect(flow.event(at: URL(string: "http://localhost:9999/")) == .continue, "another port is another site")
    }
}
