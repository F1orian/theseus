@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OnboardingFeature
import OpenWebUIKit
import Testing

/// Drives the root flow end to end against recorded fixtures.
@MainActor
@Suite("AppModel flow")
struct AppModelTests {
    let transport = StubTransport()
    let environment: AppEnvironment

    init() throws {
        var environment = AppEnvironment.ephemeral(transport: transport)
        // AIDataConsentTests covers the consent; here sign-in leads straight to the shell.
        environment.asksForAIDataConsent = false
        self.environment = environment
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("POST", "api/v1/auths/signin", fixture: "signin.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        transport.stub("POST", "api/v1/auths/signout", body: Data(#"{"status":true}"#.utf8))
    }

    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    // MARK: Helpers

    func onboarding(_ app: AppModel) throws -> OnboardingFlow {
        guard case .onboarding(let flow) = app.route else { throw Unexpected.route("\(app.route)") }
        return flow
    }

    func serverEntry(_ app: AppModel) throws -> ServerEntryModel {
        guard case .serverEntry(let model) = try onboarding(app).step else { throw Unexpected.route("\(app.route)") }
        return model
    }

    func signIn(_ app: AppModel) throws -> SignInModel {
        guard case .signIn(let model) = try onboarding(app).step else { throw Unexpected.route("\(app.route)") }
        return model
    }

    func shell(_ app: AppModel) throws -> MainShellModel {
        guard case .main(let model) = app.route else { throw Unexpected.route("\(app.route)") }
        return model
    }

    enum Unexpected: Error { case route(String) }

    func makeJWT(_ claims: String) -> String {
        func encode(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"HS256"}"#)).\(encode(claims)).c2ln"
    }

    /// Waits for main-actor hops (e.g. the session-expired callback) to land.
    func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Tests

    @Test func freshInstallStartsAtServerEntry() async throws {
        let app = AppModel(environment: environment)
        await app.start()
        #expect(try serverEntry(app).address == "")
    }

    @Test func invalidAddressShowsAnError() async throws {
        let app = AppModel(environment: environment)
        await app.start()
        let entry = try serverEntry(app)
        entry.address = "ftp://nope"
        await entry.connect()
        #expect(entry.errorMessage == OpenWebUIError.invalidServerURL("").message)
        #expect(transport.requests.isEmpty)
    }

    @Test func nonOpenWebUIHostIsRejected() async throws {
        transport.stub("GET", "api/config", body: Data("<html>hello</html>".utf8))
        let app = AppModel(environment: environment)
        await app.start()
        let entry = try serverEntry(app)
        entry.address = "owui.example.com"
        await entry.connect()
        #expect(entry.errorMessage == OpenWebUIError.notOpenWebUI.message)
        _ = try serverEntry(app)
    }

    @Test func fullOnboardingFlowEndsOnTheModelList() async throws {
        let app = AppModel(environment: environment)
        await app.start()

        let entry = try serverEntry(app)
        entry.address = "owui.example.com/"
        await entry.connect()

        let signInModel = try signIn(app)
        #expect(signInModel.server.url == Fixture.serverURL)
        #expect(signInModel.server.name == "Open WebUI")
        #expect(!signInModel.canSubmit)
        signInModel.email = "user@example.com"
        signInModel.password = "secret"
        await signInModel.signIn()

        let main = try shell(app)
        #expect(main.state == .loaded)
        #expect(main.models.count == 5)
        #expect(main.library.chats.count == 61, "first chat page and the Starred chats are mirrored")
        let first = try #require(main.models.first)
        #expect(main.capabilities(for: first).contains(.webSearch))

        // The Session token went to the credential store, the Account to the registry.
        let stored = try environment.credentials.credential(for: main.account.id)
        #expect(stored?.sessionToken.isEmpty == false)
        #expect(stored?.password == nil, "passwords are not stored by default")
        #expect(environment.registry.activeAccount?.id == main.account.id)

        // Authenticated calls carried the token.
        let modelsRequest = try #require(transport.requests.first { $0.url?.path() == "/api/models" })
        #expect(modelsRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(stored?.sessionToken ?? "")")
    }

    @Test(arguments: [
        ("synthetic/error.invalid-credentials.json", "incorrect"),
    ])
    func signInProblemsStayOnTheForm(fixture: String, message: String) async throws {
        let status = fixture.contains("error.") ? 400 : 200
        try transport.stub("POST", "api/v1/auths/signin", status: status, fixture: fixture)
        let app = AppModel(environment: environment)
        app.showSignIn(server: account.server, config: nil)
        let form = try signIn(app)
        form.email = "user@example.com"
        form.password = "pw"
        await form.signIn()
        #expect(form.errorMessage?.contains(message) == true)
        _ = try signIn(app)
    }

    @Test func relaunchRestoresTheSessionFromTheCredentialStore() async throws {
        try environment.credentials.save(Credential(sessionToken: "stored-jwt"), for: account.id)
        try environment.registry.activate(account)

        let app = AppModel(environment: environment)
        await app.start()

        let main = try shell(app)
        #expect(main.models.count == 5)
        #expect(transport.requests.allSatisfy { $0.url?.path() != "/api/v1/auths/signin" }, "no password prompt")
    }

    @Test func expiredSessionReturnsToSignInWithEmailPrefilled() async throws {
        try transport.stub("GET", "api/models", status: 401, fixture: "models.unauthenticated.json")
        try transport.stub("GET", "api/v1/auths/", status: 401, fixture: "models.unauthenticated.json")
        try environment.credentials.save(Credential(sessionToken: "expired-jwt"), for: account.id)
        try environment.registry.activate(account)

        let app = AppModel(environment: environment)
        await app.start()
        await settle { (try? signIn(app)) != nil }

        let form = try signIn(app)
        #expect(form.email == "user@example.com")
        #expect(form.notice?.contains("expired") == true)
        #expect(try environment.credentials.credential(for: account.id) == nil)
    }

    @Test func storedPasswordRenewsSilently() async throws {
        transport.stub("GET", "api/models") { request in
            let fresh = request.value(forHTTPHeaderField: "Authorization") != "Bearer expired-jwt"
            return fresh
                ? (200, (try? Fixture.data("models.json")) ?? Data())
                : (401, Data(#"{"detail":"Not authenticated"}"#.utf8))
        }
        try environment.credentials.save(Credential(sessionToken: "expired-jwt", password: "pw"), for: account.id)
        try environment.registry.activate(account)

        let app = AppModel(environment: environment)
        await app.start()

        #expect(try shell(app).models.count == 5)
        let renewed = try environment.credentials.credential(for: account.id)
        #expect(renewed?.sessionToken != "expired-jwt")
        #expect(renewed?.password == "pw")
    }

    @Test func signOutForgetsTheCredentialAndRevokesTheToken() async throws {
        try environment.credentials.save(Credential(sessionToken: "stored-jwt"), for: account.id)
        try environment.registry.activate(account)
        let app = AppModel(environment: environment)
        await app.start()

        try await shell(app).signOut()

        #expect(try signIn(app).email == account.email)
        #expect(try environment.credentials.credential(for: account.id) == nil)
        #expect(environment.registry.activeAccount == nil)
        #expect(transport.requests.contains { $0.url?.path() == "/api/v1/auths/signout" })
    }

    @Test func twoStepVerificationEndsOnTheMainShell() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "synthetic/signin.mfa-verify.json")
        try transport.stub("POST", "api/v1/auths/mfa/verify", fixture: "signin.json")
        let app = AppModel(environment: environment)
        app.showSignIn(server: account.server, config: nil, email: "user@example.com")
        let form = try signIn(app)
        form.password = "pw"
        await form.signIn()
        guard case .verification(let card) = try onboarding(app).step else { throw Unexpected.route("\(app.route)") }
        card.code = "123456"
        await card.submit()
        #expect(try shell(app).models.count == 5)
    }

    // MARK: Session lifecycle (AUTH-06)

    func pendingApproval(_ app: AppModel) throws -> PendingApprovalModel {
        guard case .pendingApproval(let model) = try onboarding(app).step else { throw Unexpected.route("\(app.route)") }
        return model
    }

    @Test func pendingSignInShowsTheApprovalScreen() async throws {
        try transport.stub("POST", "api/v1/auths/signin", fixture: "synthetic/signin.pending.json")
        let app = AppModel(environment: environment)
        app.showSignIn(server: account.server, config: nil, email: "user@example.com")
        let form = try signIn(app)
        form.password = "pw"
        await form.signIn()
        let pending = try pendingApproval(app)
        #expect(pending.email == nil, "MFA servers answer pending without a session")
        #expect(!pending.canCheckAgain)
        #expect(environment.registry.activeAccount == nil, "pending Accounts aren't activated")
    }

    @Test func aTokenPastItsExpiryAsksToSignInWithoutTouchingTheNetwork() async throws {
        let expired = makeJWT(#"{"id":"u","exp":1000}"#)
        try environment.credentials.save(Credential(sessionToken: expired), for: account.id)
        try environment.registry.activate(account)

        let app = AppModel(environment: environment)
        await app.start()

        let form = try signIn(app)
        #expect(form.email == account.email)
        #expect(form.notice == AppModel.expiredNotice)
        #expect(transport.requests.isEmpty)
        #expect(try environment.credentials.credential(for: account.id) == nil)
    }

    @Test func anAccountMovedBackToPendingShowsTheApprovalScreen() async throws {
        try transport.stub("GET", "api/models", status: 401, fixture: "models.unauthenticated.json")
        transport.stub("GET", "api/v1/auths/", body: Data(
            #"{"id":"00000000-0000-4000-8000-000000000001","name":"Test User","email":"user@example.com","role":"pending"}"#.utf8
        ))
        try environment.credentials.save(Credential(sessionToken: "pending-jwt"), for: account.id)
        try environment.registry.activate(account)

        let app = AppModel(environment: environment)
        await app.start()
        await settle { (try? pendingApproval(app)) != nil }

        let pending = try pendingApproval(app)
        #expect(pending.canCheckAgain)
        #expect(pending.email == account.email)
    }

    @Test func approvalOnCheckAgainOpensTheMainShell() async throws {
        transport.stub("POST", "api/v1/auths/signin", body: Data(
            #"{"id":"00000000-0000-4000-8000-000000000001","name":"Test User","email":"user@example.com","role":"pending","token":"pending-jwt"}"#.utf8
        ))
        let app = AppModel(environment: environment)
        app.showSignIn(server: account.server, config: nil, email: "user@example.com")
        let form = try signIn(app)
        form.password = "pw"
        await form.signIn()

        let pending = try pendingApproval(app)
        await pending.checkAgain()
        #expect(try shell(app).account.id == account.id, "auths.json now says role admin")
        #expect(try environment.credentials.credential(for: account.id)?.sessionToken.isEmpty == false)
    }

    @Test func returningToTheForegroundWithAnExpiredTokenEndsTheSession() async throws {
        let soon = makeJWT(#"{"id":"u","exp":\#(Int(Date.now.timeIntervalSince1970) + 3600)}"#)
        try environment.credentials.save(Credential(sessionToken: soon), for: account.id)
        try environment.registry.activate(account)
        let app = AppModel(environment: environment)
        await app.start()
        _ = try shell(app)

        await app.sceneDidBecomeActive()
        _ = try shell(app)

        try environment.credentials.save(Credential(sessionToken: makeJWT(#"{"exp":1000}"#)), for: account.id)
        await app.sceneDidBecomeActive()
        #expect(try signIn(app).notice == AppModel.expiredNotice)
    }

    // MARK: Multiple Accounts (AUTH-07)

    /// The same fixture user on a second Server is a distinct Account.
    var secondAccount: Account {
        Account(
            server: ServerProfile(url: URL(string: "https://second.example.com") ?? Fixture.serverURL, name: "Open WebUI"),
            userID: account.userID,
            name: "Test User",
            email: "user@example.com"
        )
    }

    func signedInApp() async throws -> AppModel {
        try environment.credentials.save(Credential(sessionToken: "first-jwt"), for: account.id)
        try environment.registry.activate(account)
        let app = AppModel(environment: environment)
        await app.start()
        _ = try shell(app)
        return app
    }

    @Test func addingAnAccountCanBeCancelled() async throws {
        let app = try await signedInApp()
        let first = try shell(app)
        app.addAccount()
        let flow = try onboarding(app)
        #expect(flow.onCancel != nil)
        #expect(flow.accountShortcuts.isEmpty, "the current Account isn't offered as a shortcut")
        flow.cancel()
        #expect(try shell(app) === first, "the same shell comes back")
    }

    @Test func aSecondAccountIsAddedNextToTheFirst() async throws {
        let app = try await signedInApp()
        app.addAccount()
        let entry = try serverEntry(app)
        entry.address = "second.example.com"
        await entry.connect()
        let form = try signIn(app)
        form.email = "user@example.com"
        form.password = "pw"
        await form.signIn()

        #expect(try shell(app).account.id == secondAccount.id)
        #expect(environment.registry.accounts.map(\.id) == [account.id, secondAccount.id])
        #expect(try environment.credentials.credential(for: account.id)?.sessionToken == "first-jwt", "the first Account stays signed in")
    }

    @Test func switchingToASignedInAccountNeedsNoPassword() async throws {
        try environment.credentials.save(Credential(sessionToken: "second-jwt"), for: secondAccount.id)
        try environment.registry.activate(secondAccount)
        let app = try await signedInApp()
        #expect(try shell(app).account.id == account.id)

        app.showAccountSwitcher()
        let switcher = try #require(app.accountSwitcher)
        #expect(switcher.groups.map { $0.server.url.host() } == ["second.example.com", "owui.example.com"])
        let row = try #require(switcher.groups.first?.rows.first)
        #expect(row.isSignedIn && !row.isActive)

        let first = try shell(app)
        #expect(first.chat != nil)
        await switcher.select(row)
        #expect(try shell(app).account.id == secondAccount.id)
        await settle { first.chat == nil }
        #expect(first.chat == nil, "the previous Account's socket and Chat services are torn down")
        #expect(environment.registry.activeAccount?.id == secondAccount.id)
        let lastModels = try #require(transport.requests.last { $0.url?.path() == "/api/models" })
        #expect(lastModels.value(forHTTPHeaderField: "Authorization") == "Bearer second-jwt", "each Account uses its own token")
        #expect(!transport.requests.contains { $0.url?.path() == "/api/v1/auths/signin" })
    }

    @Test func switchingToASignedOutAccountAsksForItsPassword() async throws {
        try environment.registry.activate(secondAccount)
        let app = try await signedInApp()
        await app.switchAccount(to: secondAccount)
        let form = try signIn(app)
        #expect(form.server.url.host() == "second.example.com")
        #expect(form.email == "user@example.com")
        #expect(try onboarding(app).onCancel != nil)
    }

    @Test func removingTheActiveAccountMovesToAnotherSignedInOne() async throws {
        try environment.credentials.save(Credential(sessionToken: "second-jwt"), for: secondAccount.id)
        try environment.registry.activate(secondAccount)
        let app = try await signedInApp()

        await app.removeAccount(account)
        #expect(try shell(app).account.id == secondAccount.id)
        #expect(environment.registry.accounts.map(\.id) == [secondAccount.id])
        #expect(try environment.credentials.credential(for: account.id) == nil)
        let signOut = try #require(transport.requests.first { $0.url?.path() == "/api/v1/auths/signout" })
        #expect(signOut.value(forHTTPHeaderField: "Authorization") == "Bearer first-jwt", "the removed token is revoked")
    }

    @Test func removingTheLastAccountReturnsToServerEntry() async throws {
        let app = try await signedInApp()
        await app.removeAccount(account)
        #expect(try serverEntry(app).accountShortcuts.isEmpty)
        #expect(environment.registry.accounts.isEmpty)
    }

    @Test func signedOutDevicesOfferKnownAccountsOnServerEntry() async throws {
        try environment.registry.activate(account)
        try environment.registry.deactivate()
        let app = AppModel(environment: environment)
        await app.start()
        let entry = try serverEntry(app)
        #expect(entry.accountShortcuts == [account])
        await entry.pick(account)
        #expect(try signIn(app).email == account.email, "no stored token, so it asks for the password")
    }

    @Test func changeServerGoesBackToEntryWithHostPrefilled() throws {
        let app = AppModel(environment: environment)
        app.showSignIn(server: account.server, config: nil)
        try signIn(app).changeServer()
        #expect(try serverEntry(app).address == "owui.example.com")
    }
}
