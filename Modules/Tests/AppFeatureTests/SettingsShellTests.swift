@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OnboardingFeature
import OpenWebUIKit
import SettingsFeature
import Testing

/// The shell's side of the Settings sheet: presenting it, logging out and removing the Account
/// from the device (SET-01, SET-04, SET-10).
@MainActor
@Suite("Settings in the shell")
struct SettingsShellTests {
    let transport = StubTransport()
    let environment: AppEnvironment
    let account = Account(
        server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
        userID: "00000000-0000-4000-8000-000000000001",
        name: "Test User",
        email: "user@example.com"
    )

    init() throws {
        var environment = AppEnvironment.ephemeral(transport: transport)
        environment.asksForAIDataConsent = false
        self.environment = environment
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/models", fixture: "models.json")
        try transport.stub("GET", "api/v1/chats/", fixture: "chats.page-1.json")
        try transport.stub("GET", "api/v1/chats/pinned", fixture: "chats.pinned.json")
        transport.stub("POST", "api/v1/auths/signout", body: Data(#"{"status":true}"#.utf8))
        try environment.credentials.save(Credential(sessionToken: "stored-jwt"), for: account.id)
        try environment.registry.activate(account)
    }

    func signedIn() async throws -> (AppModel, MainShellModel) {
        let app = AppModel(environment: environment)
        await app.start()
        guard case .main(let shell) = app.route else { throw Unexpected.route }
        return (app, shell)
    }

    enum Unexpected: Error { case route }

    @Test func openingSettingsBuildsTheSheetForTheAccount() async throws {
        let (_, shell) = try await signedIn()
        shell.navigate(to: .settings)
        let settings = try #require(shell.settings)
        #expect(shell.isSettingsPresented)
        #expect(settings.account == account)
        #expect(settings.accountRows.contains(.sharedLinks), "seeded with the shell's Capabilities")
    }

    @Test func logOutFromSettingsReturnsToSignIn() async throws {
        let (app, shell) = try await signedIn()
        shell.navigate(to: .settings)
        await shell.settings?.logOut()
        guard case .onboarding(let flow) = app.route, case .signIn = flow.step else { throw Unexpected.route }
        #expect(environment.registry.activeAccount == nil)
        #expect(environment.registry.accounts == [account], "log out keeps the Account for quick re-sign-in")
    }

    @Test func removingTheAccountForgetsItOnThisDevice() async throws {
        let (app, shell) = try await signedIn()
        shell.preferences.preferences.appearance = .dark
        shell.navigate(to: .settings)
        await shell.settings?.makeDataPrivacyModel().removeAccountFromDevice()

        guard case .onboarding(let flow) = app.route, case .serverEntry = flow.step else { throw Unexpected.route }
        #expect(environment.registry.accounts.isEmpty)
        #expect(try environment.credentials.credential(for: account.id) == nil)
        #expect(transport.requests.contains { $0.url?.path() == "/api/v1/auths/signout" })
        let preferences = AccountPreferencesStore(accountID: account.id, defaults: environment.preferences)
        #expect(preferences.preferences.appearance == .system, "preferences are forgotten too")
    }

    @Test func settingsOffersTheAccountSwitcher() async throws {
        let (app, shell) = try await signedIn()
        try withExtendedLifetime(app) {
            shell.navigate(to: .settings)
            let settings = try #require(shell.settings)
            #expect(settings.canSwitchAccount)
            settings.switchAccount?()
            #expect(shell.accountSwitcher?.groups.first?.rows.first?.isActive == true)
        }
    }

    /// #128: a Profile rename (PERS-01) reaches the Account card, the drawer and the registry.
    @Test func aProfileRenameRefreshesTheAccountEverywhere() async throws {
        let (app, shell) = try await signedIn()
        try withExtendedLifetime(app) {
            shell.navigate(to: .settings)
            let settings = try #require(shell.settings)
            shell.accountRenamed(to: "Ada Lovelace")
            #expect(settings.account.name == "Ada Lovelace")
            #expect(shell.account.name == "Ada Lovelace")
            #expect(environment.registry.activeAccount?.name == "Ada Lovelace")
            #expect(environment.registry.accounts.count == 1)
            // The next Settings sheet starts from the new name too.
            shell.isSettingsPresented = false
            shell.navigate(to: .settings)
            #expect(shell.settings?.account.name == "Ada Lovelace")
        }
    }

    @Test func preferencesBelongToTheAccount() async throws {
        let (_, shell) = try await signedIn()
        shell.preferences.preferences.hapticFeedback = false
        let (_, again) = try await signedIn()
        #expect(!again.preferences.preferences.hapticFeedback)
    }
}

/// SET-06: the shell's notifier posts only while the app is in the background.
@MainActor
@Suite("Response notifications in the shell")
struct ShellResponseNotificationTests {
    final class RecordingCenter: NotificationScheduling {
        var posted: [ResponseNotification] = []
        func authorizationStatus() async -> NotificationAuthorization { .authorized }
        func requestAuthorization() async -> Bool { true }
        func post(_ notification: ResponseNotification) async { posted.append(notification) }
    }

    @Test func notifiesOnlyWhenTheSceneIsInTheBackground() async {
        let center = RecordingCenter()
        let account = Account(
            server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
            userID: "u", name: "Test User", email: "user@example.com"
        )
        let shell = MainShellModel(
            account: account,
            client: OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport()),
            database: nil,
            preferences: AccountPreferencesStore(
                accountID: account.id,
                defaults: UserDefaults(suiteName: "theseus.tests.\(UUID().uuidString)") ?? .standard
            ),
            notificationCenter: center,
            onSignOut: {}
        )
        await shell.responseNotifier.setEnabled(true)

        await shell.responseNotifier.responseFinished(chatID: "c", chatTitle: "Trip", excerpt: "Ready")
        #expect(center.posted.isEmpty)

        shell.isSceneActive = false
        await shell.responseNotifier.responseFinished(chatID: "c", chatTitle: "Trip", excerpt: "Ready")
        #expect(center.posted.map(\.chatID) == ["c"])
    }
}
