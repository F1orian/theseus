import Rendering
import SwiftUI
import Testing
import UIKit

/// #183 (and #175): a finished Response's prose switches from SwiftUI `Text` blocks (streaming) to
/// one text view per run. If the heights differed, a user reading mid-Response would see the
/// text jump when the stream ends, so the two must lay out the same, to a pixel or so.
@MainActor
@Suite("Prose keeps its height when a Response finishes")
struct ProseHeightParityTests {
    nonisolated static let paragraph = "The mouse enters corridor 6 and keeps its right whisker on the wall. Every junction is noted in its little map, so it never walks the same loop twice. The walls are cold stone, the floor is worn smooth by centuries of visitors who came looking for the centre and found only more corridors."
    nonisolated static let list = "- **Sense:** read the walls around the current cell.\n- **Decide:** prefer unvisited corridors, then the least-visited one.\n- **Move:** advance one cell and mark the corridor."
    nonisolated static let section = "## Corridor 6\n\n\(paragraph)\n\n\(list)\n\nAfter corridor 6 the mouse has mapped about 48 % of the labyrinth."

    nonisolated static let samples: [(String, String)] = [
        ("one line", "Hello there."),
        ("paragraph", paragraph),
        ("two paragraphs", paragraph + "\n\n" + paragraph),
        ("heading first", "## Corridor 6\n\n" + paragraph),
        ("heading inside", paragraph + "\n\n### Corridor 7\n\n" + paragraph),
        ("list", list),
        ("quote", "> " + paragraph),
        ("section", section),
        ("five sections", Array(repeating: section, count: 5).joined(separator: "\n\n")),
    ]

    func height(_ markdown: String, width: CGFloat, finished: Bool) -> CGFloat {
        let view = MarkdownView(blocks: MarkdownParser.parse(markdown), selectsAcrossBlocks: finished)
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @Test(arguments: samples.map(\.0), [362.0, 300.0])
    func finishedProseIsAsTallAsStreamingText(sample: String, width: Double) {
        let markdown = Self.samples.first { $0.0 == sample }!.1
        let streaming = height(markdown, width: width, finished: false)
        let finished = height(markdown, width: width, finished: true)
        // Within 2 pt over thousands (sub-pixel rounding); before #183 a long Response grew ~10 %.
        #expect(abs(finished - streaming) <= 2, "\(sample) at \(width) pt: streaming \(streaming), finished \(finished)")
    }
}
