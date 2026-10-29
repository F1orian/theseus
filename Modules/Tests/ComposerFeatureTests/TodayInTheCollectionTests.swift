import ArtCollection
@testable import ComposerFeature
import Fixtures
import Foundation
import Testing

/// BRAND-03: "Today in the collection" on the new-chat home and its "Ask about it ›".
@Suite("Today in the collection (BRAND-03)")
@MainActor
struct TodayInTheCollectionTests {
    @Test func theQuestionNamesTheWorkItsArtistAndDate() throws {
        let durer = try #require(Artwork.all.first { $0.title == "St. Jerome in his Study" })
        #expect(TodayInTheCollection.prompt(for: durer) == "Tell me about St. Jerome in his Study by Albrecht Dürer (1514).")
    }

    @Test func theCardFollowsTheDailyRotation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(TodayInTheCollection.artwork(for: day, calendar: calendar) == Artwork.today(for: day, calendar: calendar))
        #expect(Artwork.todayRotation.contains(TodayInTheCollection.artwork(for: day, calendar: calendar)))
    }

    @Test func askingFillsAnEmptyDraftAndFocusesTheField() {
        let composer = ComposerModel(services: makeServices(StubTransport()))
        composer.text = "  "
        composer.prefill("Tell me about View of Florence by Thomas Cole (1837).")
        #expect(composer.text == "Tell me about View of Florence by Thomas Cole (1837).")
        #expect(composer.focusRequest == 1)
    }

    @Test func askingKeepsWhatTheUserTyped() {
        let composer = ComposerModel(services: makeServices(StubTransport()))
        composer.text = "Briefly:"
        composer.prefill("Tell me about Point Judith by Martin Johnson Heade (1867–68).")
        #expect(composer.text == "Briefly: Tell me about Point Judith by Martin Johnson Heade (1867–68).")
        // Asking twice doesn't repeat the question.
        composer.prefill("Tell me about Point Judith by Martin Johnson Heade (1867–68).")
        #expect(composer.text == "Briefly: Tell me about Point Judith by Martin Johnson Heade (1867–68).")
        #expect(composer.focusRequest == 2)
    }
}
