@testable import Rendering
import SwiftUI
import Testing

/// Response tables: a long cell wraps inside its 280 pt column and the row grows with it, instead
/// of being measured as one line and drawn over the next row.
@MainActor
@Suite("Table cell layout")
struct TableLayoutTests {
    func size(_ view: some View, width: CGFloat?) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    @Test func aLongCellWrapsAtTheCapAndReportsItsHeight() {
        let long = "Lodging (1 night camping or budget stay with a long description that has to wrap)"
        let oneLine = size(Text("Lodging").font(.callout), width: nil)
        let capped = size(CappedWidth(maxWidth: 280) { Text(long).font(.callout) }, width: nil)
        #expect(capped.width <= 280)
        #expect(capped.height > oneLine.height * 1.5, "wrapped text reports more than one line")
    }

    @Test func aShortCellKeepsItsOwnWidth() {
        let short = size(CappedWidth(maxWidth: 280) { Text("Gas").font(.callout) }, width: nil)
        #expect(short.width < 100)
    }
}
