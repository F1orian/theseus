import Foundation
@testable import Rendering
import Testing

private func text(_ string: String, _ style: InlineStyle = [], link: URL? = nil) -> InlineRun {
    .text(string, style, link: link)
}

@Suite("Markdown parser")
struct MarkdownParserTests {
    @Test func headingsBoldLeadInsListsAndRules() {
        let blocks = MarkdownParser.parse("""
        ## Plan

        **Step one:** pack *light* 🎒.

        - first `item`
        - second

        3. three
        4. four

        ---
        """)
        #expect(blocks == [
            .heading(level: 2, InlineContent([text("Plan")])),
            .paragraph(InlineContent([text("Step one:", .strong), text(" pack "), text("light", .emphasis), text(" 🎒.")])),
            .list(ordered: false, start: 1, items: [
                ListItem(blocks: [.paragraph(InlineContent([text("first "), text("item", .code)]))]),
                ListItem(blocks: [.paragraph(InlineContent([text("second")]))]),
            ]),
            .list(ordered: true, start: 3, items: [
                ListItem(blocks: [.paragraph(InlineContent([text("three")]))]),
                ListItem(blocks: [.paragraph(InlineContent([text("four")]))]),
            ]),
            .rule,
        ])
    }

    @Test func codeBlocksKeepLanguageAndWhitespace() {
        let blocks = MarkdownParser.parse("```Swift\nlet x = 1\n  print(x)\n```")
        #expect(blocks == [.code(language: "swift", code: "let x = 1\n  print(x)")])
        #expect(MarkdownParser.parse("```\nplain\n```") == [.code(language: nil, code: "plain")])
    }

    @Test func tablesTaskListsLinksAndStrikethrough() {
        let blocks = MarkdownParser.parse("""
        | A | B |
        |:-:|--:|
        | 1 | ~~2~~ |

        - [x] done
        - [ ] todo [site](https://example.com)
        """)
        guard case .table(let table) = blocks.first, case .list(_, _, let items) = blocks.last else {
            Issue.record("got \(blocks)"); return
        }
        #expect(table.alignments == [.center, .trailing])
        #expect(table.header.map(\.plainText) == ["A", "B"])
        #expect(table.rows.first?.last == InlineContent([text("2", .strikethrough)]))
        #expect(items.map(\.checkbox) == [true, false])
        #expect(items.last?.blocks.first == .paragraph(InlineContent([
            text("todo "), text("site", link: URL(string: "https://example.com")),
        ])))
    }

    @Test func citationsOnlyWhenRequested() {
        let source = "Version 0.12.3 shipped [1][2], see `[3]`."
        #expect(MarkdownParser.parse(source) == [.paragraph(InlineContent([text("Version 0.12.3 shipped [1][2], see "), text("[3]", .code), text(".")]))])
        #expect(MarkdownParser.parse(source, options: .init(citations: true)) == [.paragraph(InlineContent([
            text("Version 0.12.3 shipped "), .citation(1), .citation(2), text(", see "), text("[3]", .code), text("."),
        ]))])
    }
}

@Suite("Math extraction")
struct MathTests {
    @Test func inlineAndDisplayMath() {
        let blocks = MarkdownParser.parse("""
        Euler: $e^{i\\pi} + 1 = 0$ and \\(a^2\\).

        $$
        \\int_0^1 x\\,dx
        $$

        \\[ E = mc^2 \\]
        """)
        #expect(blocks == [
            .paragraph(InlineContent([text("Euler: "), .math("e^{i\\pi} + 1 = 0"), text(" and "), .math("a^2"), text(".")])),
            .math("\\int_0^1 x\\,dx"),
            .math("E = mc^2"),
        ])
    }

    @Test func currencyAndCodeAreNotMath() {
        #expect(MarkdownParser.parse("It costs $5 and $10.") == [.paragraph(InlineContent([text("It costs $5 and $10.")]))])
        #expect(MarkdownParser.parse("Run `echo $HOME$` now") == [.paragraph(InlineContent([text("Run "), text("echo $HOME$", .code), text(" now")]))])
        #expect(MarkdownParser.parse("```sh\necho $PATH $$\n```") == [.code(language: "sh", code: "echo $PATH $$")])
        #expect(MarkdownParser.parse("Escaped \\$x\\$ stays.") == [.paragraph(InlineContent([text("Escaped $x$ stays.")]))])
    }

    @Test func mathFencesAndUnclosedDisplayMath() {
        #expect(MarkdownParser.parse("```math\nx^2\n```") == [.math("x^2")])
        #expect(MarkdownParser.parse("Now:\n\n$$\\frac{a}{b") == [.paragraph(InlineContent([text("Now:")])), .math("\\frac{a}{b")])
    }
}

@Suite("Streaming markdown (frozen prefix + live tail)")
struct StreamingMarkdownTests {
    static let document: String = {
        guard let url = Bundle.module.url(forResource: "Resources/benchmark-response", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }()

    @Test func streamingMatchesAFullParseAtEveryStep() {
        let document = Self.document
        #expect(document.count > 15_000)
        var streaming = StreamingMarkdown()
        var cursor = document.startIndex
        var steps = 0
        while cursor < document.endIndex {
            cursor = document.index(cursor, offsetBy: 97, limitedBy: document.endIndex) ?? document.endIndex
            let prefix = String(document[..<cursor])
            streaming.update(prefix, isComplete: false)
            steps += 1
            // Frozen blocks must already be final: equal to a full parse's leading blocks.
            let full = MarkdownParser.parse(prefix)
            #expect(Array(full.prefix(streaming.frozenCount)) == Array(streaming.blocks.prefix(streaming.frozenCount)), "step \(steps)")
        }
        streaming.update(document, isComplete: true)
        #expect(streaming.blocks == MarkdownParser.parse(document))
        #expect(steps > 100)
    }

    @Test func codeFencesAreNeverSplit() throws {
        var streaming = StreamingMarkdown()
        streaming.update("Intro\n\n```swift\nlet a = 1\n\nlet b = 2", isComplete: false)
        #expect(streaming.frozenCount == 1)
        #expect(streaming.blocks.last == .code(language: "swift", code: "let a = 1\n\nlet b = 2"))
        streaming.update("Intro\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nDone", isComplete: false)
        #expect(streaming.frozenCount == 2)
        #expect(streaming.blocks.count == 3)
    }

    @Test func replacedTextResetsTheCache() {
        var streaming = StreamingMarkdown()
        streaming.update("First para\n\nSecond", isComplete: false)
        #expect(streaming.frozenCount == 1)
        streaming.update("Different\n\nText", isComplete: false)
        #expect(streaming.blocks.first == .paragraph(InlineContent([text("Different")])))
    }

    @Test func indentedContinuationsStayInTheTail() {
        let boundary = StreamingMarkdown.boundary(in: "1. Item\n\n    more of the item\n", from: "".startIndex)
        #expect(boundary == nil)
    }
}

/// What the streaming text reveal counts (ADR 0130).
@Suite("Streaming reveal")
struct StreamingRevealTests {
    @Test func revealLengthCountsCharactersAndOneGlyphPerFormula() {
        let content = InlineContent([
            .text("Héllo ", [], link: nil),
            .math("x^2"),
            .lineBreak,
            .citation(12),
        ])
        // 6 characters, the formula's image, the line break and " 12 " with thin spaces.
        #expect(content.revealLength == 6 + 1 + 1 + 4)
    }

    @Test func onlyProseBlocksRevealGlyphByGlyph() {
        #expect(MarkdownBlock.paragraph(InlineContent([])).isText)
        #expect(MarkdownBlock.list(ordered: false, start: 1, items: []).isText)
        #expect(!MarkdownBlock.code(language: nil, code: "x").isText)
        #expect(!MarkdownBlock.rule.isText)
    }
}
