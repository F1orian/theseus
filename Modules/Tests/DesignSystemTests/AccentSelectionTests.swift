@testable import DesignSystem
import Foundation
import Observation
import Testing

@Suite("Accent selection (#179)")
struct AccentSelectionTests {
    @Test func startsAtTheDefault() {
        #expect(AccentSelection().choice == .verdigris)
    }

    /// Reading the choice inside a tracked scope (a SwiftUI `body`) subscribes to it, so views
    /// that read an accent token redraw when the choice changes (ADR 0145).
    @Test func readingTheChoiceIsObserved() {
        let selection = AccentSelection()
        let changed = LockedFlag()
        withObservationTracking {
            _ = selection.choice
        } onChange: {
            changed.set()
        }
        selection.choice = .oxblood
        #expect(changed.value)
        #expect(selection.choice == .oxblood)
    }

    /// Setting the same choice again doesn't invalidate anything.
    @Test func settingTheSameChoiceIsNotAChange() {
        let selection = AccentSelection(.ultramarine)
        let changed = LockedFlag()
        withObservationTracking {
            _ = selection.choice
        } onChange: {
            changed.set()
        }
        selection.choice = .ultramarine
        #expect(!changed.value)
    }

    /// `Palette`'s accent tokens resolve against the shared selection; the other tokens don't move.
    @MainActor
    @Test func paletteFollowsTheSharedSelection() {
        let original = AccentSelection.shared.choice
        defer { AccentSelection.shared.choice = original }
        let background = Palette.background
        for choice in AccentChoice.allCases {
            AccentSelection.shared.choice = choice
            #expect(Palette.accent == choice.tokens.accent)
            #expect(Palette.onAccent == choice.tokens.onAccent)
            #expect(Palette.accentSoft == choice.tokens.accentSoft)
            #expect(Palette.background == background)
        }
    }

    @Test func choicesRoundTripThroughTheirRawValues() throws {
        for choice in AccentChoice.allCases {
            let data = try JSONEncoder().encode(choice)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(choice.rawValue)\"")
            #expect(try JSONDecoder().decode(AccentChoice.self, from: data) == choice)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
