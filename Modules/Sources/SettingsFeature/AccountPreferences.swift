public import DesignSystem
public import Foundation
public import Observation
public import SwiftUI

/// The app's colour scheme choice (SET-02).
public enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case light
    case dark
    case system

    public var id: Self { self }

    /// The scheme to force, or `nil` to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

/// Client-only preferences of one Account. They stay on this device (ADR 0012); anything that
/// should roam goes to the user settings' `theseus` namespace instead.
public struct AccountPreferences: Codable, Equatable, Sendable {
    /// Light, dark or system (SET-02).
    public var appearance: Appearance
    /// The accent pigment (#179): Verdigris unless picked otherwise. Blobs saved before it existed
    /// decode to Verdigris.
    public var accent: AccentChoice
    /// App haptics on or off (SET-03, PLAT-02).
    public var hapticFeedback: Bool
    /// Post a local notification when a Response finishes in the background (SET-06).
    public var responseNotifications: Bool
    /// The one-time "notify me" offer after the first Response was shown or answered (SET-06).
    public var hasSeenNotificationOffer: Bool
    /// "Show today's artwork": the "Today in the collection" card on the new-chat home
    /// (BRAND-03, brand.md §4). On by default.
    public var showsTodayArtwork: Bool

    public init(
        appearance: Appearance = .system,
        accent: AccentChoice = .default,
        hapticFeedback: Bool = true,
        responseNotifications: Bool = false,
        hasSeenNotificationOffer: Bool = false,
        showsTodayArtwork: Bool = true
    ) {
        self.appearance = appearance
        self.accent = accent
        self.hapticFeedback = hapticFeedback
        self.responseNotifications = responseNotifications
        self.hasSeenNotificationOffer = hasSeenNotificationOffer
        self.showsTodayArtwork = showsTodayArtwork
    }

    // Keys added later decode to their defaults instead of discarding the stored value.
    public init(from decoder: any Decoder) throws {
        let defaults = AccountPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? container.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? defaults.appearance
        // An unknown pigment (a newer build's) falls back to the default too.
        accent = (try? container.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? defaults.accent
        hapticFeedback = try container.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? defaults.hapticFeedback
        responseNotifications = try container.decodeIfPresent(Bool.self, forKey: .responseNotifications)
            ?? defaults.responseNotifications
        hasSeenNotificationOffer = try container.decodeIfPresent(Bool.self, forKey: .hasSeenNotificationOffer)
            ?? defaults.hasSeenNotificationOffer
        showsTodayArtwork = try container.decodeIfPresent(Bool.self, forKey: .showsTodayArtwork)
            ?? defaults.showsTodayArtwork
    }
}

/// Loads and saves one Account's `AccountPreferences` in `UserDefaults`, keyed by the Account id.
/// Changing `preferences` saves immediately.
@MainActor
@Observable
public final class AccountPreferencesStore {
    public var preferences: AccountPreferences {
        didSet {
            guard preferences != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let key: String
    @ObservationIgnored private let defaults: UserDefaults

    public init(accountID: String, defaults: UserDefaults = .standard) {
        key = Self.key(for: accountID)
        self.defaults = defaults
        preferences = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(AccountPreferences.self, from: $0) }
            ?? AccountPreferences()
    }

    /// Forgets the preferences of `accountID` (when the Account is removed from the device).
    public static func remove(accountID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: accountID))
    }

    private static func key(for accountID: String) -> String {
        "theseus.preferences.\(accountID)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
