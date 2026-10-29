import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

/// A fake authorizer that hands out `token-N` and counts renewals.
final class CountingAuthorizer: RequestAuthorizer {
    private let state: Mutex<(token: String?, renewals: Int)>
    private let failsRenewal: Bool

    init(token: String?, failsRenewal: Bool = false) {
        state = Mutex((token, 0))
        self.failsRenewal = failsRenewal
    }

    var renewals: Int { state.withLock { $0.renewals } }

    func currentToken() async -> String? { state.withLock { $0.token } }

    func renewToken(rejected: String) async throws -> String {
        if failsRenewal { throw OpenWebUIError.unauthorized(detail: "expired") }
        return state.withLock { state in
            state.renewals += 1
            state.token = "token-\(state.renewals)"
            return "token-\(state.renewals)"
        }
    }
}

@Suite("OpenWebUIClient")
struct OpenWebUIClientTests {
    let transport = StubTransport()

    func client(_ authorizer: (any RequestAuthorizer)? = nil) -> OpenWebUIClient {
        OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: authorizer)
    }

    @Test func authenticatedRequestCarriesBearerTokenAndQuery() async throws {
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        _ = try await client(CountingAuthorizer(token: "jwt")).send(.chats(page: 2))

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://owui.example.com/api/v1/chats/?page=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @Test func subPathDeploymentsKeepTheirPrefix() async throws {
        let client = OpenWebUIClient(
            server: try ServerURL.normalize("https://example.com/owui/"),
            transport: transport
        )
        _ = try? await client.send(.version)
        #expect(transport.requests.first?.url?.absoluteString == "https://example.com/owui/api/version")
    }

    @Test func signInPostsCredentialsWithoutAuthorization() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let result = try await client(CountingAuthorizer(token: "stale")).send(.signIn(email: "me@x.y", password: "pw"))

        guard case .session = result else {
            Issue.record("Expected a session")
            return
        }
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["email": "me@x.y", "password": "pw"])
    }

    @Test func optionalAuthenticationSendsTokenWhenAvailable() async throws {
        try transport.stub("GET", "api/config", fixture: "config.json")
        _ = try await client(CountingAuthorizer(token: "jwt")).send(.config)
        _ = try await client().send(.config)
        #expect(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer jwt", nil])
    }

    @Test func unauthorizedRenewsOnceAndRetries() async throws {
        let models = try Fixture.data("models.json")
        let unauthorized = try Fixture.data("models.unauthenticated.json")
        transport.stub("GET", "api/models") { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" ? (200, models) : (401, unauthorized)
        }
        let authorizer = CountingAuthorizer(token: "expired")

        let result = try await client(authorizer).send(.models)

        #expect(result.count == 5)
        #expect(authorizer.renewals == 1)
        #expect(transport.requests.count == 2)
    }

    @Test func unauthorizedAfterRenewalSurfacesError() async throws {
        try transport.stub("GET", "api/models", status: 401, fixture: "models.unauthenticated.json")
        let authorizer = CountingAuthorizer(token: "expired")

        await #expect(throws: OpenWebUIError.unauthorized(detail: "Not authenticated")) {
            try await client(authorizer).send(.models)
        }
        #expect(authorizer.renewals == 1, "never loops on renewal")
    }

    @Test func failedRenewalPropagates() async throws {
        try transport.stub("GET", "api/models", status: 401, fixture: "models.unauthenticated.json")
        await #expect(throws: OpenWebUIError.unauthorized(detail: "expired")) {
            try await client(CountingAuthorizer(token: "old", failsRenewal: true)).send(.models)
        }
    }

    @Test func requiredAuthenticationWithoutTokenFailsFast() async {
        await #expect(throws: OpenWebUIError.unauthorized(detail: nil)) {
            try await client(CountingAuthorizer(token: nil)).send(.models)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func errorDetailIsExtracted() async throws {
        try transport.stub("POST", "api/v1/auths/signin", status: 400, fixture: "synthetic/error.invalid-credentials.json")
        await #expect(throws: OpenWebUIError.server(
            status: 400,
            detail: "The email or password provided is incorrect. Please check for typos and try logging in again."
        )) {
            try await client().send(.signIn(email: "a", password: "b"))
        }
    }

    @Test func validationErrorDetailsAreJoined() async throws {
        try transport.stub("POST", "api/v1/auths/signin", status: 422, fixture: "synthetic/error.validation.json")
        await #expect(throws: OpenWebUIError.server(status: 422, detail: "Field required")) {
            try await client().send(.signIn(email: "a", password: "b"))
        }
    }

    @Test(arguments: [(429, OpenWebUIError.rateLimited), (403, .forbidden(detail: nil)), (500, .server(status: 500, detail: nil))])
    func statusCodesMapToErrors(status: Int, expected: OpenWebUIError) async {
        transport.stub("GET", "api/version", status: status, body: Data("oops".utf8))
        await #expect(throws: expected) { try await client().send(.version) }
    }

    @Test func htmlInterstitialIsNotOpenWebUI() async {
        transport.stub("GET", "api/config", body: Data("<html><body>Sign in to your proxy</body></html>".utf8))
        await #expect(throws: OpenWebUIError.notOpenWebUI) { try await client().send(.config) }
    }

    @Test func unexpectedJSONShapeIsADecodingError() async {
        transport.stub("GET", "api/version", body: Data(#"{"nope": true}"#.utf8))
        await #expect {
            try await client().send(.version)
        } throws: { error in
            guard case OpenWebUIError.decoding(let message) = error else { return false }
            return message.contains("version")
        }
    }

    @Test func transportFailuresMapToURLErrorCodes() async {
        struct Offline: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                throw URLError(.notConnectedToInternet)
            }
        }
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: Offline())
        await #expect(throws: OpenWebUIError.transport(.notConnectedToInternet)) { try await client.send(.version) }
        #expect(OpenWebUIError.transport(.notConnectedToInternet).message == "You appear to be offline.")
    }
}

@Suite("ServerURL")
struct ServerURLTests {
    @Test(arguments: [
        ("chat.example.com", "https://chat.example.com"),
        ("  https://Chat.Example.com/  ", "https://chat.example.com"),
        ("http://192.168.1.5:8080/", "http://192.168.1.5:8080"),
        ("https://example.com/owui//", "https://example.com/owui"),
        ("https://example.com/?x=1#frag", "https://example.com"),
        ("localhost:3000", "https://localhost:3000"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerURL.normalize(input).absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com", "https://", "not a host"])
    func rejects(input: String) {
        #expect(throws: OpenWebUIError.invalidServerURL(input)) { try ServerURL.normalize(input) }
    }
}
