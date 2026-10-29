@testable import AppFeature
import Auth
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// AUTH-08: the welcome shows once per Account on this device.
@MainActor
@Suite("Welcome (AUTH-08)")
struct WelcomeShellTests {
    let defaults: UserDefaults
    let shell: MainShellModel

    init() throws {
        let suite = "theseus.tests.welcome.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        shell = MainShellModel(
            account: Account(
                server: ServerProfile(url: Fixture.serverURL, name: "Open WebUI"),
                userID: "00000000-0000-4000-8000-000000000001",
                name: "Test User",
                email: "user@example.com"
            ),
            client: OpenWebUIClient(server: Fixture.serverURL, transport: StubTransport()),
            database: nil,
            onSignOut: {}
        )
        shell.welcomeRecord = WelcomeRecord(defaults: defaults, arguments: [])
    }

    @Test func showsOnceThenNeverAgain() async {
        await shell.prepareWelcome(features: ServerFeatures(raw: [:]))
        let welcome = shell.welcome
        #expect(welcome?.host == "owui.example.com")
        // Without Server speech engines, voice is on-device; without folders, Projects explain why.
        #expect(welcome?.items.contains { $0.id == "projects" } == true)

        shell.finishWelcome()
        #expect(shell.welcome == nil)
        await shell.prepareWelcome(features: ServerFeatures(raw: [:]))
        #expect(shell.welcome == nil)
    }

    @Test func notOverSettings() async {
        shell.navigate(to: .settings)
        await shell.prepareWelcome(features: ServerFeatures(raw: [:]))
        #expect(shell.welcome == nil)
    }

    @Test func launchArgumentsSkipOrForceIt() {
        #expect(!WelcomeRecord(defaults: defaults, arguments: [WelcomeRecord.skipArgument]).shouldShow(accountID: "a"))
        let record = WelcomeRecord(defaults: defaults, arguments: [])
        record.markSeen(accountID: "a")
        #expect(!record.shouldShow(accountID: "a"))
        #expect(record.shouldShow(accountID: "b"), "per Account")
        #expect(WelcomeRecord(defaults: defaults, arguments: [WelcomeRecord.showArgument]).shouldShow(accountID: "a"))
    }
}
