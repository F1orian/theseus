@testable import LibraryFeature
import Testing

/// BRAND-04: the hint under "Nothing on these shelves.".
@Suite("Library copy")
struct LibraryCopyTests {
    @Test func noResultsQuotesTheQuery() {
        #expect(LibraryCopy.noResults(for: "  tapas ", localOnly: false) == "No chats match \u{201C}tapas\u{201D}.")
    }

    @Test func localOnlySearchesSayWhatWasSearched() {
        #expect(LibraryCopy.noResults(for: "tapas", localOnly: true)
            == "No chats match \u{201C}tapas\u{201D}. Only chat titles on this device were searched.")
    }
}
