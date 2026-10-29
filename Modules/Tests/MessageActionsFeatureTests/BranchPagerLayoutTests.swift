import ChatDomain
@testable import MessageActionsFeature
import SwiftUI
import Testing

/// #147: the Branch pager ("‹ 1 / 2 ›") is one line under every condition: squeezed by a full
/// action row, at the largest accessibility text sizes, and with two-digit counts.
@MainActor
@Suite("Branch pager layout (#147)")
struct BranchPagerLayoutTests {
    /// The rendered size of the pager when its container offers only `width` points.
    func renderedSize(index: Int, count: Int, width: CGFloat, size: DynamicTypeSize) -> CGSize {
        let pager = BranchPager(position: .init(index: index, count: count), isEnabled: true) { _ in }
            .environment(\.dynamicTypeSize, size)
        let renderer = ImageRenderer(content: pager)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    @Test(arguments: [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5])
    func thePagerKeepsOneLineWhenSqueezed(size: DynamicTypeSize) {
        for (index, count) in [(0, 2), (1, 2), (9, 12)] {
            let roomy = renderedSize(index: index, count: count, width: 400, size: size)
            let squeezed = renderedSize(index: index, count: count, width: 20, size: size)
            #expect(squeezed == roomy, "\(index + 1) / \(count) at \(size): squeezed \(squeezed), roomy \(roomy)")
            // The two arrows plus the counter, one 44 pt line tall (taller only if one line of
            // the counter's text is).
            #expect(squeezed.width > BranchPager.arrowWidth * 2)
            #expect(squeezed.height < 44 * 2)
        }
    }
}
