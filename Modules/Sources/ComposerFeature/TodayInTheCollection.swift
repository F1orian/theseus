public import ArtCollection
public import Foundation
public import SwiftUI

/// "Today in the collection" on the new-chat home (brand.md §4, BRAND-03): one framed work a day
/// from The Collection's `today` rotation, with its plaque and "Ask about it ›", which puts a
/// question about the work in the composer.
public enum TodayInTheCollection {
    /// The work for `date` (the same on every device on the same local date).
    public static func artwork(for date: Date, calendar: Calendar = .current) -> Artwork {
        Artwork.today(for: date, calendar: calendar)
    }

    /// What "Ask about it ›" puts in the composer: "Tell me about St. Jerome in his Study by
    /// Albrecht Dürer (1514)." Plain text, because the user's bubble shows the draft as typed.
    public static func prompt(for artwork: Artwork) -> String {
        "Tell me about \(artwork.title) by \(artwork.artist) (\(artwork.date))."
    }
}

extension EnvironmentValues {
    /// Settings › "Show today's artwork" (`AccountPreferences.showsTodayArtwork`, on by default):
    /// whether the new-chat home shows the "Today in the collection" card. The app shell sets it.
    @Entry public var showsTodayArtwork = true
}
