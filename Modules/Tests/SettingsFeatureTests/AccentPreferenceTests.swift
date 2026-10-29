import DesignSystem
import Foundation
@testable import SettingsFeature
import Testing

/// #179: Settings › Appearance › Accent colour (`AccountPreferences.accent`).
@MainActor
@Suite("Accent colour preference (#179)")
struct AccentPreferenceTests {
    @Test func verdigrisByDefaultAndForPreferencesSavedBeforeTheKeyExisted() throws {
        #expect(AccountPreferences().accent == .verdigris)
        let saved = Data(#"{"appearance":"dark","hapticFeedback":false,"responseNotifications":false,"hasSeenNotificationOffer":true,"showsTodayArtwork":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountPreferences.self, from: saved)
        #expect(decoded.accent == .verdigris)
        #expect(decoded.appearance == .dark)
        #expect(!decoded.showsTodayArtwork)
    }

    /// A pigment this build doesn't know (saved by a newer one) falls back to Verdigris and keeps
    /// the rest of the preferences.
    @Test func anUnknownAccentFallsBackToTheDefault() throws {
        let saved = Data(#"{"appearance":"light","accent":"malachite","hapticFeedback":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountPreferences.self, from: saved)
        #expect(decoded.accent == .verdigris)
        #expect(decoded.appearance == .light)
        #expect(!decoded.hapticFeedback)
    }

    @Test(arguments: AccentChoice.allCases)
    func theChoicePersistsPerAccount(choice: AccentChoice) {
        let defaults = makeDefaults()
        AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.accent = choice
        #expect(AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.accent == choice)
        #expect(AccountPreferencesStore(accountID: "b", defaults: defaults).preferences.accent == .verdigris)
    }

    @Test func itIsStoredByItsRawValue() throws {
        let data = try JSONEncoder().encode(AccountPreferences(accent: .oxblood))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["accent"] as? String == "oxblood")
    }
}
