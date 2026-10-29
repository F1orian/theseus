import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import SwiftUI
import Testing

@MainActor
@Suite("Account preferences (SET-02, SET-03)")
struct AccountPreferencesTests {
    @Test func newAccountsFollowTheSystemWithHapticsOn() {
        let store = AccountPreferencesStore(accountID: "a", defaults: makeDefaults())
        #expect(store.preferences.appearance == .system)
        #expect(store.preferences.hapticFeedback)
        #expect(!store.preferences.responseNotifications)
    }

    @Test func choicesPersistPerAccount() {
        let defaults = makeDefaults()
        let first = AccountPreferencesStore(accountID: "a", defaults: defaults)
        first.preferences.appearance = .dark
        first.preferences.hapticFeedback = false

        let reopened = AccountPreferencesStore(accountID: "a", defaults: defaults)
        #expect(reopened.preferences.appearance == .dark)
        #expect(!reopened.preferences.hapticFeedback)

        let other = AccountPreferencesStore(accountID: "b", defaults: defaults)
        #expect(other.preferences.appearance == .system, "Accounts don't share preferences")
    }

    @Test func removingAnAccountForgetsItsPreferences() {
        let defaults = makeDefaults()
        AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.appearance = .light
        AccountPreferencesStore.remove(accountID: "a", defaults: defaults)
        #expect(AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.appearance == .system)
    }

    @Test func appearanceMapsToAColorScheme() {
        #expect(Appearance.light.colorScheme == .light)
        #expect(Appearance.dark.colorScheme == .dark)
        #expect(Appearance.system.colorScheme == nil)
    }
}

@MainActor
@Suite("Settings sheet (SET-01, SET-04)")
struct SettingsModelTests {
    let transport = StubTransport()
    let log = ActionLog()

    func makeModel(_ enabled: Capabilities, extensions: SettingsExtensions = SettingsExtensions()) -> SettingsModel {
        let model = SettingsModel(
            account: testAccount,
            client: makeClient(transport),
            preferences: AccountPreferencesStore(accountID: testAccount.id, defaults: makeDefaults()),
            capabilities: enabled,
            actions: log.actions
        )
        model.extensions = extensions
        return model
    }

    @Test func accountGroupShowsWhatTheServerAllows() {
        let model = makeModel(capabilities(.instructions, .shareChat, .memory))
        #expect(model.accountRows == [.profile, .instructions, .serverUsage, .notifications, .dataPrivacy, .sharedLinks])
        #expect(model.appRows == [.capabilities, .skills, .hapticFeedback])
    }

    @Test func rowsWithoutTheirCapabilityAreHidden() {
        let model = makeModel(capabilities())
        #expect(!model.accountRows.contains(.instructions))
        #expect(!model.accountRows.contains(.sharedLinks))
        #expect(model.accountRows.contains(.profile))
    }

    @Test func otherFeatureAreasPlugInRows() {
        var extensions = SettingsExtensions()
        extensions.register(.styles) { Text("Styles") }
        extensions.register(.connectors) { Text("Connectors") }
        let model = makeModel(capabilities(), extensions: extensions)
        #expect(model.appRows == [.capabilities, .skills, .connectors, .styles, .hapticFeedback])
        #expect(model.extensions.destination(for: .styles) != nil)
        #expect(model.extensions.destination(for: .voice) == nil)
    }

    @Test func loadingResolvesCapabilitiesAndRoleFromTheServer() async throws {
        try transport.stub("GET", "api/config", fixture: "config.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        let model = makeModel(capabilities())
        await model.load()
        #expect(model.capabilities.contains(.shareChat))
        #expect(model.capabilities.contains(.memory))
        #expect(model.user?.role == .admin)
        #expect(model.serverVersion == "0.12.3")
        #expect(model.accountRows.contains(.sharedLinks))
    }

    @Test func loadingOfflineKeepsTheSeededCapabilities() async {
        let model = makeModel(capabilities(.shareChat))
        await model.load()
        #expect(model.accountRows.contains(.sharedLinks))
    }

    @Test func logOutAsksTheAppToSignOut() async {
        let model = makeModel(capabilities())
        await model.logOut()
        #expect(log.events == ["signOut"])
    }

    @Test func accountSwitcherSlotOnlyWhenTheAppProvidesIt() {
        let model = makeModel(capabilities())
        #expect(!model.canSwitchAccount)
        model.switchAccount = {}
        #expect(model.canSwitchAccount)
    }
}
