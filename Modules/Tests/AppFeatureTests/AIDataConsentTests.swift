import AppIntentsFeature
@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// App Review 5.1.2(i), ADR 0171: before an Account sends anything to its Server (and the AI
/// providers behind it), the user agrees once on this device. Declining signs out.
@MainActor
@Suite("AI data consent")
struct AIDataConsentTests {
    let transport = StubTransport()
    let environment: AppEnvironment
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    init() throws {
        environment = .ephemeral(transport: transport)
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        transport.stub("POST", "api/v1/auths/signout", body: Data(#"{"status":true}"#.utf8))
        try environment.credentials.save(Credential(sessionToken: "stored-jwt"), for: account.id)
        try environment.registry.activate(account)
    }

    func launchedApp() async -> AppModel {
        let app = AppModel(environment: environment)
        app.consentRecord = AIDataConsentRecord(defaults: environment.preferences, arguments: [])
        await app.start()
        return app
    }

    @Test func aNewAccountIsAskedBeforeAnythingLoads() async throws {
        let app = await launchedApp()
        guard case .aiDataConsent(let shell) = app.route else {
            Issue.record("Expected the consent, got \(app.route)")
            return
        }
        #expect(shell.account.id == account.id)
        #expect(transport.requests.isEmpty, "nothing is sent before the user agrees")
    }

    @Test func agreeingOpensTheShellAndIsRemembered() async throws {
        let app = await launchedApp()
        await app.agreeToAIDataSharing()
        guard case .main(let shell) = app.route else {
            Issue.record("Expected the shell, got \(app.route)")
            return
        }
        #expect(shell.state == .loaded)
        await shell.tearDown()

        let relaunched = await launchedApp()
        guard case .main(let again) = relaunched.route else {
            Issue.record("Asked again after agreeing")
            return
        }
        await again.tearDown()
    }

    @Test func aDeepLinkWaitsForTheAnswer() async throws {
        let app = AppModel(environment: environment)
        app.consentRecord = AIDataConsentRecord(defaults: environment.preferences, arguments: [])
        app.open(.newChat(DeepLink.NewChat(prompt: "Hello", sendsImmediately: true)))
        await app.start()
        guard case .aiDataConsent = app.route else {
            Issue.record("Expected the consent, got \(app.route)")
            return
        }
        #expect(transport.requests.allSatisfy { $0.url?.path().contains("completions") != true })
        await app.declineAIDataSharing()
        // Declining signs out: the stored session is gone and the link was dropped.
        await settle { (try? environment.credentials.credential(for: account.id)) == nil }
        #expect((try? environment.credentials.credential(for: account.id)) == nil)
        guard case .onboarding = app.route else {
            Issue.record("Expected sign-in, got \(app.route)")
            return
        }
        #expect(transport.requests.allSatisfy { $0.url?.path().contains("completions") != true })
    }

    @Test func removingTheAccountForgetsTheAnswer() async throws {
        let record = AIDataConsentRecord(defaults: environment.preferences, arguments: [])
        record.record(accountID: account.id)
        #expect(!record.isNeeded(accountID: account.id))
        let app = AppModel(environment: environment)
        await app.removeAccount(account)
        #expect(record.isNeeded(accountID: account.id))
    }

    @Test func uiTestsCanSkipIt() {
        let defaults = environment.preferences
        #expect(!AIDataConsentRecord(defaults: defaults, arguments: [AIDataConsentRecord.skipArgument]).isNeeded(accountID: "a"))
        #expect(!AIDataConsentRecord(defaults: defaults, arguments: [WelcomeRecord.skipArgument]).isNeeded(accountID: "a"))
        #expect(AIDataConsentRecord(defaults: defaults, arguments: []).isNeeded(accountID: "a"))
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
