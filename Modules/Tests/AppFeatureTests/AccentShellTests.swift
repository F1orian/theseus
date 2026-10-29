@testable import AppFeature
import Auth
import DesignSystem
import Fixtures
import Foundation
import OpenWebUIKit
import SettingsFeature
import Testing

/// #179 (ADR 0145): the app shows the signed-in Account's accent, from launch on.
@MainActor
@Suite("Accent colour in the shell (#179)")
struct AccentShellTests {
    let transport = StubTransport()
    var environment: AppEnvironment
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    init() throws {
        environment = .ephemeral(transport: transport)
        environment.asksForAIDataConsent = false
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
    }

    func signedIn(accent: AccentChoice) throws -> AppModel {
        try environment.credentials.save(Credential(sessionToken: "stored-jwt"), for: account.id)
        try environment.registry.activate(account)
        AccountPreferencesStore(accountID: account.id, defaults: environment.preferences).preferences.accent = accent
        return AppModel(environment: environment)
    }

    /// The stored choice is applied when the model is made, before the splash's first frame.
    @Test func theStoredAccentAppliesAtLaunch() async throws {
        let original = AccentSelection.shared.choice
        defer { AccentSelection.shared.choice = original }
        let app = try signedIn(accent: .ultramarine)
        #expect(AccentSelection.shared.choice == .ultramarine)
        #expect(Palette.accent == AccentChoice.ultramarine.tokens.accent)
        #expect(app.accent == .ultramarine)
    }

    @Test func theShellFollowsTheAccountsPreference() async throws {
        let original = AccentSelection.shared.choice
        defer { AccentSelection.shared.choice = original }
        let app = try signedIn(accent: .oxblood)
        await app.start()
        guard case .main(let shell) = app.route else {
            Issue.record("not signed in: \(app.route)")
            return
        }
        #expect(app.accent == .oxblood)
        shell.preferences.preferences.accent = .ultramarine
        #expect(app.accent == .ultramarine)
    }

    @Test func signedOutIsVerdigris() async throws {
        let original = AccentSelection.shared.choice
        defer { AccentSelection.shared.choice = original }
        let app = AppModel(environment: environment)
        await app.start()
        #expect(app.accent == .verdigris)
    }
}
