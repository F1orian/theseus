import Auth
import Fixtures
import Foundation
import OpenWebUIKit
import Security
import Synchronization
import Testing

let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")

@Suite("PasswordSignIn")
struct PasswordSignInTests {
    let transport = StubTransport()

    @Test func signsInAndBuildsTheAccount() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        let outcome = try await PasswordSignIn(server: server, transport: transport)
            .signIn(email: "  user@example.com\n", password: "pw")

        guard case .signedIn(let session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        #expect(session.account.id == "https://owui.example.com|00000000-0000-4000-8000-000000000001")
        #expect(session.account.email == "user@example.com")
        #expect(session.token == session.user.token)
        let body = try JSONDecoder().decode([String: String].self, from: try #require(transport.requests.first?.httpBody))
        #expect(body["email"] == "user@example.com", "email is trimmed")
    }

    @Test(arguments: ["synthetic/signin.mfa-verify.json", "synthetic/signin.mfa-enroll.json"])
    func surfacesMFAChallenges(fixture: String) async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: fixture)
        let outcome = try await PasswordSignIn(server: server, transport: transport).signIn(email: "e", password: "p")
        guard case .mfaRequired = outcome else {
            Issue.record("Expected an MFA challenge, got \(outcome)")
            return
        }
    }

    @Test func pendingApprovalFromNextStep() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "synthetic/signin.pending.json")
        let outcome = try await PasswordSignIn(server: server, transport: transport).signIn(email: "e", password: "p")
        #expect(outcome == .pendingApproval(nil))
    }

    @Test func pendingApprovalFromPendingRole() async throws {
        let body = Data(#"{"id":"u","name":"N","email":"e","role":"pending","token":"jwt","token_type":"Bearer"}"#.utf8)
        transport.stub("POST", "api/v1/auths/signin", body: body)
        let outcome = try await PasswordSignIn(server: server, transport: transport).signIn(email: "e", password: "p")
        guard case .pendingApproval(let session?) = outcome else {
            Issue.record("Expected a pending session, got \(outcome)")
            return
        }
        #expect(session.token == "jwt", "the pending token lets the app ask again later")
    }

    @Test func wrongPasswordSurfacesServerDetail() async throws {
        try transport.stub("POST", "api/v1/auths/signin", status: 400, fixture: "synthetic/error.invalid-credentials.json")
        await #expect {
            try await PasswordSignIn(server: server, transport: transport).signIn(email: "e", password: "bad")
        } throws: { error in
            guard case OpenWebUIError.server(400, let detail?) = error else { return false }
            return detail.contains("incorrect")
        }
    }
}

@Suite("SessionAuthenticator (single-flight 401 handling)")
struct SessionAuthenticatorTests {
    /// A renewal that takes a moment and counts how often it ran.
    final class SlowRenewal: Sendable {
        let calls = Mutex(0)
        let fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        var count: Int { calls.withLock { $0 } }

        func callAsFunction() async throws -> String {
            let call = calls.withLock { calls in
                calls += 1
                return calls
            }
            try await Task.sleep(for: .milliseconds(50))
            if fails { throw OpenWebUIError.unauthorized(detail: "bad password") }
            return "fresh-\(call)"
        }
    }

    @Test func concurrentRejectionsShareOneRenewal() async throws {
        let renewal = SlowRenewal()
        let authenticator = SessionAuthenticator(token: "stale") { try await renewal() }

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await authenticator.renewToken(rejected: "stale") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(renewal.count == 1)
        #expect(Set(tokens) == ["fresh-1"])
        #expect(await authenticator.currentToken() == "fresh-1")
    }

    @Test func lateRejectionOfAnOldTokenReusesTheNewOne() async throws {
        let renewal = SlowRenewal()
        let authenticator = SessionAuthenticator(token: "stale") { try await renewal() }
        _ = try await authenticator.renewToken(rejected: "stale")
        #expect(try await authenticator.renewToken(rejected: "stale") == "fresh-1")
        #expect(renewal.count == 1)
        // A rejection of the *current* token renews again.
        #expect(try await authenticator.renewToken(rejected: "fresh-1") == "fresh-2")
    }

    @Test func failedRenewalExpiresTheSessionAndFailsFast() async throws {
        let renewal = SlowRenewal(fails: true)
        let changes = Mutex<[String?]>([])
        let authenticator = SessionAuthenticator(token: "stale", renew: { try await renewal() }) { token in
            changes.withLock { $0.append(token) }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try? await authenticator.renewToken(rejected: "stale") }
            }
        }
        await #expect(throws: OpenWebUIError.unauthorized(detail: nil)) {
            try await authenticator.renewToken(rejected: "stale")
        }
        #expect(renewal.count == 1)
        #expect(await authenticator.currentToken() == nil)
        #expect(changes.withLock { $0 } == [nil])

        await authenticator.restore(token: "interactive")
        #expect(await authenticator.currentToken() == "interactive")
        #expect(changes.withLock { $0 } == [nil, "interactive"])
    }

    @Test func concurrentRequestsThroughTheClientRenewOnce() async throws {
        let transport = StubTransport()
        let models = try Fixture.data("models.json")
        let unauthorized = try Fixture.data("models.unauthenticated.json")
        transport.stub("GET", "api/models") { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-1" ? (200, models) : (401, unauthorized)
        }
        let renewal = SlowRenewal()
        let client = OpenWebUIClient(
            server: Fixture.serverURL,
            transport: transport,
            authorizer: SessionAuthenticator(token: "stale") { try await renewal() }
        )

        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.send(.models).count }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 5, count: 8))
        #expect(renewal.count == 1)
    }
}

@Suite("Credential stores")
struct CredentialStoreTests {
    static let keychainUsable: Bool = {
        let store = KeychainCredentialStore(service: "dev.unrush.theseus.tests.probe")
        do {
            try store.save(Credential(sessionToken: "probe"), for: "probe")
            try store.deleteCredential(for: "probe")
            return true
        } catch {
            return false // e.g. errSecMissingEntitlement in an unsigned host
        }
    }()

    func exercise(_ store: some CredentialStore) throws {
        let id = "https://owui.example.com|\(UUID().uuidString)"
        #expect(try store.credential(for: id) == nil)

        try store.save(Credential(sessionToken: "one"), for: id)
        #expect(try store.credential(for: id) == Credential(sessionToken: "one"))

        try store.save(Credential(sessionToken: "two", password: "pw"), for: id)
        #expect(try store.credential(for: id) == Credential(sessionToken: "two", password: "pw"), "overwrites")

        try store.deleteCredential(for: id)
        #expect(try store.credential(for: id) == nil)
        try store.deleteCredential(for: id) // idempotent
    }

    @Test func inMemory() throws {
        try exercise(InMemoryCredentialStore())
    }

    @Test(.enabled(if: keychainUsable, "Keychain unavailable in this test host"))
    func keychain() throws {
        try exercise(KeychainCredentialStore(service: "dev.unrush.theseus.tests.\(UUID().uuidString)"))
    }
}

@Suite("AccountRegistry")
struct AccountRegistryTests {
    let alice = Account(server: server, userID: "1", name: "Alice", email: "alice@example.com")
    let bob = Account(server: server, userID: "2", name: "Bob", email: "bob@example.com")

    @Test func activatesAndPersistsAcrossInstances() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "registry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let registry = AccountRegistry(fileURL: file)
        try registry.activate(alice)
        try registry.activate(bob)
        var renamed = alice
        renamed.name = "Alice B."
        try registry.activate(renamed)

        let reloaded = AccountRegistry(fileURL: file)
        #expect(reloaded.accounts.map(\.name) == ["Alice B.", "Bob"])
        #expect(reloaded.activeAccount?.id == alice.id)
    }

    @Test func updateRenamesWithoutSwitchingTheActiveAccount() throws {
        let registry = AccountRegistry(fileURL: nil)
        try registry.activate(alice)
        try registry.activate(bob)
        var renamed = alice
        renamed.name = "Alice B."
        try registry.update(renamed)
        try registry.update(Account(server: server, userID: "3", name: "Carol", email: "carol@example.com"))
        #expect(registry.accounts.map(\.name) == ["Alice B.", "Bob"])
        #expect(registry.activeAccount?.id == bob.id)
    }

    @Test func deactivateKeepsAccountRemoveForgetsIt() throws {
        let registry = AccountRegistry(fileURL: nil)
        try registry.activate(alice)
        try registry.deactivate()
        #expect(registry.activeAccount == nil)
        #expect(registry.accounts == [alice])

        try registry.activate(alice)
        try registry.remove(alice.id)
        #expect(registry.accounts.isEmpty)
        #expect(registry.activeAccount == nil)
    }
}

/// Builds an unsigned JWT-shaped token with the given claims (signature is irrelevant client-side).
func makeJWT(_ claims: String) -> String {
    func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(claims)).c2ln"
}

@Suite("SessionToken")
struct SessionTokenTests {
    @Test func readsTheExpiryClaim() {
        let token = makeJWT(#"{"id":"u","exp":1795196776}"#)
        #expect(SessionToken.expiry(of: token) == Date(timeIntervalSince1970: 1_795_196_776))
        #expect(!SessionToken.isExpired(token, at: Date(timeIntervalSince1970: 1_795_196_000)))
        #expect(SessionToken.isExpired(token, at: Date(timeIntervalSince1970: 1_795_197_000)))
    }

    @Test(arguments: ["sk-0123456789abcdef", "eyJhbGciOiJIUzI1NiJ9.c2NydWJiZWQ.c2NydWJiZWQ", makeJWT(#"{"id":"u"}"#)])
    func unreadableOrOpenEndedTokensAreNotExpired(token: String) {
        #expect(SessionToken.expiry(of: token) == nil)
        #expect(!SessionToken.isExpired(token))
    }
}

@Suite("TokenSignIn")
struct TokenSignInTests {
    let transport = StubTransport()

    @Test func validatesTheTokenAndBuildsTheAccount() async throws {
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        let outcome = try await TokenSignIn(server: server, transport: transport).signIn(token: "cookie-jwt")
        guard case .signedIn(let session) = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        #expect(session.account.id == "https://owui.example.com|00000000-0000-4000-8000-000000000001")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer cookie-jwt")
    }

    @Test func pendingRoleKeepsTheToken() async throws {
        transport.stub("GET", "api/v1/auths/", body: Data(#"{"id":"u","name":"N","email":"e@x","role":"pending"}"#.utf8))
        let outcome = try await TokenSignIn(server: server, transport: transport).signIn(token: "pending-jwt")
        guard case .pendingApproval(let session?) = outcome else {
            Issue.record("Expected pending, got \(outcome)")
            return
        }
        #expect(session.token == "pending-jwt")
    }

    @Test func aRejectedTokenIsUnauthorized() async throws {
        try transport.stub("GET", "api/v1/auths/", status: 401, fixture: "models.unauthenticated.json")
        await #expect(throws: OpenWebUIError.self) {
            try await TokenSignIn(server: server, transport: transport).signIn(token: "revoked")
        }
    }
}

@Suite("MFASignIn (TOTP)")
struct MFASignInTests {
    let transport = StubTransport()
    let verify = MFAChallenge(step: .verify, challengeToken: "challenge-verify-0000000000", expiresIn: 300)
    let enroll = MFAChallenge(step: .enroll, challengeToken: "challenge-enroll-0000000000", expiresIn: 600)

    func body(_ index: Int = 0) throws -> [String: JSONValue] {
        let data = try #require(transport.requests[index].httpBody)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    @Test func verifiesATOTPCode() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", fixture: "signin.json")
        let session = try await MFASignIn(server: server, transport: transport).verify(verify, code: " 123456 ")
        #expect(session.account.email == "user@example.com")
        #expect(try body() == [
            "challenge_token": .string("challenge-verify-0000000000"),
            "code": .string("123456"),
            "recovery": .bool(false),
        ])
    }

    @Test func verifiesARecoveryCode() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", fixture: "signin.json")
        _ = try await MFASignIn(server: server, transport: transport).verify(verify, code: "3f9a-1c2e", recovery: true)
        #expect(try body()["recovery"] == .bool(true))
    }

    @Test func aWrongCodeSurfacesTheServerMessage() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", status: 401, fixture: "synthetic/error.mfa-invalid-code.json")
        await #expect(throws: OpenWebUIError.unauthorized(detail: "Invalid or already used code.")) {
            try await MFASignIn(server: server, transport: transport).verify(verify, code: "000000")
        }
    }

    @Test func enrolsANewAuthenticator() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/enroll/start", fixture: "synthetic/mfa.enroll-start.json")
        try transport.stub("POST", "api/v1/auths/mfa/enroll/confirm", fixture: "synthetic/mfa.enroll-confirm.json")
        let mfa = MFASignIn(server: server, transport: transport)

        let setup = try await mfa.startEnrollment(enroll)
        #expect(setup.manualKey == "JBSWY3DPEHPK3PXP")
        #expect(try body(0) == ["challenge_token": .string("challenge-enroll-0000000000")], "no unknown keys (extra=forbid)")

        let (session, codes) = try await mfa.confirmEnrollment(enroll, code: "123456")
        #expect(session.token.isEmpty == false)
        #expect(codes.count == 10)
        #expect(codes.first == "3f9a-1c2e")
    }

    @Test func redeemsAnAdminResetTokenForANewEnrolment() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/recover", fixture: "synthetic/signin.mfa-enroll.json")
        let recover = MFAChallenge(step: .recover, challengeToken: "challenge-recover-000000000", expiresIn: 300)
        let next = try await MFASignIn(server: server, transport: transport).recover(recover, resetToken: " reset-token ")
        #expect(next.step == .enroll)
        #expect(try body()["reset_token"] == .string("reset-token"))
    }

    @Test func buildsTheProvisioningURIForAuthenticatorApps() throws {
        let uri = try #require(MFAChallenge.provisioningURI(secret: "JBSWY3DPEHPK3PXP", account: "user@example.com", issuer: "Open WebUI"))
        #expect(uri.absoluteString == "otpauth://totp/Open%20WebUI:user@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Open%20WebUI")
    }
}

@Suite("WebSignIn (SSO cookie capture)")
struct WebSignInTests {
    let base = Fixture.serverURL

    func cookie(_ name: String, _ value: String, domain: String = "owui.example.com") throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"]))
    }

    @Test func startsAtTheProvidersLoginRoute() {
        #expect(WebSignIn.oauth(server: base, provider: "oidc").startURL.absoluteString == "https://owui.example.com/oauth/oidc/login")
        let subPath = URL(string: "https://example.com/owui") ?? base
        #expect(WebSignIn.oauth(server: subPath, provider: "google").startURL.absoluteString == "https://example.com/owui/oauth/google/login")
        #expect(WebSignIn.webPage(server: subPath).startURL.absoluteString == "https://example.com/owui/auth")
    }

    @Test func theTokenCookieFinishesSignInWhereverItAppears() throws {
        let sso = WebSignIn.oauth(server: base, provider: "oidc")
        let idp = URL(string: "https://login.example-idp.com/authorize")
        #expect(sso.event(at: idp, cookies: []) == .continue)
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth"), cookies: [try cookie("oauth_session_id", "x")]) == .continue)
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth"), cookies: [try cookie("token", "jwt-1")]) == .token("jwt-1"))
        // After the Server's own MFA page the browser lands on "/" with the cookie.
        #expect(sso.event(at: URL(string: "https://owui.example.com/"), cookies: [try cookie("token", "jwt-2", domain: ".owui.example.com")]) == .token("jwt-2"))
    }

    @Test func cookiesFromOtherHostsAreIgnored() throws {
        let sso = WebSignIn.oauth(server: base, provider: "oidc")
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth"), cookies: [try cookie("token", "idp", domain: "example-idp.com")]) == .continue)
        #expect(sso.event(at: nil, cookies: [try cookie("token", "", domain: "owui.example.com")]) == .continue)
    }

    @Test func authPageOutcomes() {
        let sso = WebSignIn.oauth(server: base, provider: "oidc")
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth?error=User%20not%20allowed"), cookies: []) == .failed("User not allowed"))
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth?pending=1"), cookies: []) == .pendingApproval)
        #expect(sso.event(at: URL(string: "https://owui.example.com/auth?mfa=1"), cookies: []) == .continue)
        #expect(sso.event(at: URL(string: "https://elsewhere.example.com/auth?error=x"), cookies: []) == .continue)
    }

    @Test func subPathDeploymentsCheckTheirOwnAuthPage() {
        let sso = WebSignIn.oauth(server: URL(string: "https://example.com/owui") ?? base, provider: "oidc")
        #expect(sso.event(at: URL(string: "https://example.com/owui/auth/?pending=1"), cookies: []) == .pendingApproval)
        #expect(sso.event(at: URL(string: "https://example.com/auth?pending=1"), cookies: []) == .continue)
    }

    @Test func tokenExchangeTradesAnIdPTokenWhenEnabled() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/auths/oauth/oidc/token/exchange", fixture: "signin.json")
        let outcome = try await OAuthTokenExchange(server: server, transport: transport).signIn(provider: "oidc", accessToken: "idp-access")
        guard case .signedIn = outcome else {
            Issue.record("Expected a session, got \(outcome)")
            return
        }
        let body = try JSONDecoder().decode([String: String].self, from: try #require(transport.requests.first?.httpBody))
        #expect(body == ["token": "idp-access"])
    }

    @Test func tokenExchangeIsOffByDefault() async throws {
        let transport = StubTransport()
        transport.stub("POST", "api/v1/auths/oauth/oidc/token/exchange", status: 403, body: Data(#"{"detail":"Token exchange is disabled"}"#.utf8))
        await #expect(throws: OpenWebUIError.forbidden(detail: "Token exchange is disabled")) {
            try await OAuthTokenExchange(server: server, transport: transport).signIn(provider: "oidc", accessToken: "t")
        }
    }
}
