import Foundation
@testable import SettingsFeature
import Testing

/// BRAND-03: Settings › "Show today's artwork" (`AccountPreferences.showsTodayArtwork`).
@MainActor
@Suite("Show today's artwork (BRAND-03)")
struct TodayArtworkPreferenceTests {
    @Test func onByDefaultAndForPreferencesSavedBeforeTheKeyExisted() throws {
        #expect(AccountPreferences().showsTodayArtwork)
        let saved = Data(#"{"appearance":"dark","hapticFeedback":false,"responseNotifications":false,"hasSeenNotificationOffer":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AccountPreferences.self, from: saved)
        #expect(decoded.showsTodayArtwork)
        #expect(decoded.appearance == .dark)
    }

    @Test func turningItOffPersists() {
        let defaults = makeDefaults()
        AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.showsTodayArtwork = false
        #expect(!AccountPreferencesStore(accountID: "a", defaults: defaults).preferences.showsTodayArtwork)
    }
}
