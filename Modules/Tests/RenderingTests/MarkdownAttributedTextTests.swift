import Foundation
@testable import Rendering
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// #175: a whole Message as one attributed string for the Select text sheet.
@Suite("Markdown as one attributed string (Select text)")
struct MarkdownAttributedTextTests {
    let markdown = """
    # The maze

    A maze is a **branching** puzzle with *one* way out. See [Wikipedia](https://en.wikipedia.org/wiki/Maze).

    - Walls
    - Paths with `dead ends`

    1. Enter
    2. Leave

    > Keep one hand on the wall.

    ```swift
    let exit = maze.solve()
    ```

    | Kind | Exits |
    | --- | --- |
    | Labyrinth | 1 |
    """

    private func font(_ text: NSAttributedString, at needle: String) -> PlatformFont? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
    }

    private func isMonospaced(_ font: PlatformFont?) -> Bool {
        guard let font else { return false }
        #if canImport(UIKit)
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        #endif
    }

    /// Bold or semibold (headings are semibold, like `ResponseTypography`).
    private func isBold(_ font: PlatformFont?) -> Bool {
        guard let font else { return false }
        #if canImport(UIKit)
        if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        #else
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        #endif
        return ((traits?[.weight] as? CGFloat) ?? 0) >= PlatformFont.Weight.semibold.rawValue - 0.01
    }

    @Test func everyBlockLandsInOneStringInOrder() {
        let text = MarkdownAttributedText.make(markdown: markdown).string
        let order = ["The maze", "A maze is a branching puzzle", "•\tWalls", "•\tPaths with dead ends", "1.\tEnter", "2.\tLeave",
                     "Keep one hand on the wall.", "swift\nlet exit = maze.solve()", "Kind\tExits", "Labyrinth\t1"]
        var cursor = text.startIndex
        for piece in order {
            let found = text.range(of: piece, range: cursor..<text.endIndex)
            #expect(found != nil, "\(piece) after the previous block in \(text)")
            if let found { cursor = found.upperBound }
        }
        #expect(!text.contains("**") && !text.contains("```") && !text.contains("# "), "markdown syntax is gone")
        #expect(!text.hasSuffix("\n"))
    }

    @Test func formattingSurvives() {
        let text = MarkdownAttributedText.make(markdown: markdown)
        #expect(isBold(font(text, at: "The maze")), "headings are bold")
        #expect(isBold(font(text, at: "branching")))
        #expect(!isBold(font(text, at: "puzzle")))
        #expect(isMonospaced(font(text, at: "dead ends")), "inline code is monospaced")
        #expect(isMonospaced(font(text, at: "let exit")), "code blocks are monospaced")
        #expect(!isMonospaced(font(text, at: "puzzle")))
        let link = (text.string as NSString).range(of: "Wikipedia")
        #expect(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://en.wikipedia.org/wiki/Maze"))
    }

    @Test func listItemsHangTheirMarker() throws {
        let text = MarkdownAttributedText.make(markdown: "- one long item\n- two")
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > style.firstLineHeadIndent)
    }

    @Test func proseRunsGroupAndEverythingElseStaysApart() {
        let blocks = MarkdownParser.parse(markdown)
        let segments = MarkdownSegment.group(blocks)
        let kinds = segments.map { segment -> String in
            switch segment {
            case .prose(let run): "prose(\(run.count))"
            case .block(let block): "\(block)".components(separatedBy: "(").first ?? ""
            }
        }
        // Heading, paragraph, two lists and the quote join one run; code and the table don't.
        #expect(kinds == ["prose(5)", "code", "table"], "\(kinds)")
        #expect(!MarkdownBlock.paragraph(InlineContent([.text("E = ", [], link: nil), .math("mc^2")])).isSelectableProse,
                "inline math keeps its rendered image")
        #expect(!MarkdownBlock.list(ordered: false, start: 1, items: [ListItem(blocks: [.code(language: nil, code: "x")])]).isSelectableProse)
    }

    @Test func plainTextStaysAsWritten() {
        let text = MarkdownAttributedText.make(plain: "Use **stars**\n\nliterally")
        #expect(text.string == "Use **stars**\n\nliterally")
    }
}
