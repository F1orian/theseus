import DesignSystem
public import Foundation
import SwiftUI
#if canImport(UIKit)
public import UIKit
public typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformFontDescriptorTraitKey = UIFontDescriptor.TraitKey
#elseif canImport(AppKit)
public import AppKit
public typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformFontDescriptorTraitKey = NSFontDescriptor.TraitKey
#endif

/// A whole Message as **one** attributed string (#175), for the Select text sheet: one text view,
/// so any range across paragraphs, list items and headings can be selected and copied. Headings,
/// emphasis, lists, quotes and links keep their look; code (inline and blocks) is monospaced;
/// tables become tab-separated rows; math stays as its LaTeX source.
///
/// ```swift
/// let text = MarkdownAttributedText.make(markdown: response.text)
/// ```
public enum MarkdownAttributedText {
    /// The body size the sheet starts from; Dynamic Type scales it (`preferredFont`).
    public static func make(markdown: String, citations: Bool = false) -> NSAttributedString {
        make(blocks: MarkdownParser.parse(markdown, options: MarkdownParser.Options(citations: citations)))
    }

    /// Plain text (a user Message) in the body face, untouched by markdown.
    public static func make(plain text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Fonts.body,
            .foregroundColor: Colors.primary,
            .paragraphStyle: paragraph(spacing: 0),
        ])
    }

    public static func make(blocks: [MarkdownBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        append(blocks, to: result, indent: 0, quoted: false)
        // No trailing paragraph break after the last block.
        while result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    // MARK: Blocks

    private static let blockSpacing: CGFloat = ResponseTypography.blockSpacing
    private static let listIndent: CGFloat = 22

    private static func append(_ blocks: [MarkdownBlock], to result: NSMutableAttributedString, indent: CGFloat, quoted: Bool) {
        for block in blocks {
            append(block, to: result, indent: indent, quoted: quoted)
        }
    }

    private static func append(_ block: MarkdownBlock, to result: NSMutableAttributedString, indent: CGFloat, quoted: Bool) {
        let colour = quoted ? Colors.secondary : Colors.primary
        switch block {
        case .heading(let level, let content):
            let line = inline(content, font: Fonts.heading(level), colour: colour)
            line.append(NSAttributedString(string: "\n"))
            let style = paragraph(
                spacing: blockSpacing, indent: indent, before: level <= 2 ? Spacing.xs : 0, font: Fonts.heading(level)
            )
            let whole = NSRange(location: 0, length: line.length)
            line.addAttribute(.paragraphStyle, value: style, range: whole)
            #if canImport(UIKit)
            // VoiceOver's heading rotor still finds it inside one text view.
            line.addAttribute(.accessibilityTextHeadingLevel, value: level, range: whole)
            #endif
            result.append(line)
        case .paragraph(let content):
            let line = inline(content, font: Fonts.body, colour: colour)
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: paragraph(spacing: blockSpacing, indent: indent), range: NSRange(location: 0, length: line.length))
            result.append(line)
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                let marker: String = if let checked = item.checkbox {
                    checked ? "☑︎" : "☐"
                } else {
                    ordered ? "\(start + index)." : "•"
                }
                let itemStart = result.length
                result.append(NSAttributedString(string: "\(marker)\t", attributes: [.font: Fonts.body, .foregroundColor: Colors.secondary]))
                let childStart = result.length
                append(item.blocks, to: result, indent: indent + listIndent, quoted: quoted)
                // The first line hangs its marker in the indent; following lines align with the text.
                if result.length > childStart {
                    let first = result.string as NSString
                    let firstLineEnd = first.range(of: "\n", range: NSRange(location: childStart, length: first.length - childStart)).location
                    let end = firstLineEnd == NSNotFound ? result.length : firstLineEnd + 1
                    let style = paragraph(spacing: Spacing.s, indent: indent + listIndent, firstLineIndent: indent, tab: indent + listIndent)
                    result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: itemStart, length: end - itemStart))
                }
            }
            setSpacingOfLastParagraph(in: result, to: blockSpacing)
        case .quote(let blocks):
            append(blocks, to: result, indent: indent + 14, quoted: true)
        case .code(let language, let code):
            var text = code.hasSuffix("\n") ? String(code.dropLast()) : code
            if let language, !language.isEmpty { text = "\(language)\n\(text)" }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Fonts.code,
                .foregroundColor: colour,
                .backgroundColor: Colors.recessed,
                // One block: no spacing between its lines, the usual spacing after it.
                .paragraphStyle: paragraph(spacing: 0, indent: indent + 8, firstLineIndent: indent + 8, font: Fonts.code),
            ]
            result.append(NSAttributedString(string: text + "\n", attributes: attributes))
            setSpacingOfLastParagraph(in: result, to: blockSpacing)
        case .math(let latex):
            result.append(NSAttributedString(string: latex + "\n", attributes: [
                .font: Fonts.code,
                .foregroundColor: colour,
                .paragraphStyle: paragraph(spacing: blockSpacing, indent: indent),
            ]))
        case .table(let table):
            let rows = [table.header] + table.rows
            for (index, row) in rows.enumerated() {
                let line = NSMutableAttributedString()
                for (column, cell) in row.enumerated() {
                    if column > 0 { line.append(NSAttributedString(string: "\t")) }
                    line.append(inline(cell, font: index == 0 ? Fonts.bold(Fonts.body) : Fonts.body, colour: colour))
                }
                line.append(NSAttributedString(string: "\n"))
                let spacing = index == rows.count - 1 ? blockSpacing : Spacing.xs
                line.addAttribute(.paragraphStyle, value: paragraph(spacing: spacing, indent: indent), range: NSRange(location: 0, length: line.length))
                result.append(line)
            }
        case .rule:
            result.append(NSAttributedString(string: "———\n", attributes: [
                .font: Fonts.body,
                .foregroundColor: Colors.secondary,
                .paragraphStyle: paragraph(spacing: blockSpacing, indent: indent),
            ]))
        }
    }

    private static func setSpacingOfLastParagraph(in result: NSMutableAttributedString, to spacing: CGFloat) {
        guard result.length > 0 else { return }
        let string = result.string as NSString
        let paragraphRange = string.paragraphRange(for: NSRange(location: result.length - 1, length: 0))
        let current = result.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
        guard let style = (current ?? NSParagraphStyle.default).mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = max(0, spacing - ResponseTypography.lineSpacing)
        result.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
    }

    private static func paragraph(
        spacing: CGFloat,
        indent: CGFloat = 0,
        firstLineIndent: CGFloat? = nil,
        tab: CGFloat? = nil,
        before: CGFloat = 0,
        font: PlatformFont = Fonts.body
    ) -> NSParagraphStyle {
        // Lay lines out like SwiftUI's `Text`, so a finished Response that switches to this view
        // keeps its height (#183). TextKit makes each line the font's leading taller than `Text`
        // does and adds `lineSpacing` after a paragraph's last line too: take the leading off the
        // line spacing, and the line spacing off the paragraph spacing.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(0, ResponseTypography.lineSpacing + Fonts.textLineHeight(font) - font.lineHeightWithLeading)
        style.paragraphSpacing = max(0, spacing - ResponseTypography.lineSpacing)
        style.paragraphSpacingBefore = before
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        if let tab {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
            style.defaultTabInterval = listIndent
        }
        return style
    }

    // MARK: Inline

    private static func inline(_ content: InlineContent, font: PlatformFont, colour: PlatformColor) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs {
            switch run {
            case .text(let string, let style, let link):
                var runFont = font
                if style.contains(.code) { runFont = Fonts.code }
                if style.contains(.strong) { runFont = Fonts.bold(runFont) }
                if style.contains(.emphasis) { runFont = Fonts.italic(runFont) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: colour]
                if style.contains(.code) { attributes[.backgroundColor] = Colors.recessed }
                if style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: string, attributes: attributes))
            case .lineBreak:
                result.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font]))
            case .citation(let number):
                result.append(NSAttributedString(string: "[\(number)]", attributes: [
                    .font: Fonts.caption,
                    .foregroundColor: Colors.accent,
                    .baselineOffset: 4,
                ]))
            case .math(let latex):
                result.append(NSAttributedString(string: latex, attributes: [.font: Fonts.code, .foregroundColor: colour]))
            }
        }
        return result
    }

    // MARK: Fonts and colours

    /// How much taller than SwiftUI's `Text` a text view lays out `blocks` at its edges: TextKit
    /// ignores the spacing before the first paragraph (a heading's 4 pt) and gives the last line
    /// the font's leading. `SelectableProseView` pads by these so the switch keeps heights (#183).
    static func edgeAdjustments(for blocks: [MarkdownBlock]) -> (top: CGFloat, bottom: CGFloat) {
        let top: CGFloat = if case .heading(let level, _)? = blocks.first, level <= 2 { Spacing.xs } else { 0 }
        let lastFont: PlatformFont = if case .heading(let level, _)? = blocks.last { Fonts.heading(level) } else { Fonts.body }
        return (top, Fonts.textLineHeight(lastFont) - lastFont.lineHeightWithLeading)
    }

    /// Responses' faces (`ResponseTypography`) as platform fonts, scaled with Dynamic Type.
    enum Fonts {
        /// A line of `Text` in `font`: ascender to descender, rounded up to whole pixels.
        static func textLineHeight(_ font: PlatformFont) -> CGFloat {
            #if canImport(UIKit)
            let scale = max(UITraitCollection.current.displayScale, 1)
            #else
            let scale: CGFloat = 2
            #endif
            return ((font.ascender - font.descender) * scale).rounded(.up) / scale
        }

        static var body: PlatformFont { serif(.body) }
        static var caption: PlatformFont { PlatformFont.preferredFont(forTextStyle: .caption1) }
        static var code: PlatformFont {
            #if canImport(UIKit)
            // Scales with Dynamic Type like the faces built from text styles.
            return UIFontMetrics(forTextStyle: .callout).scaledFont(for: PlatformFont.monospacedSystemFont(ofSize: 16, weight: .regular))
            #else
            let size = PlatformFont.preferredFont(forTextStyle: .callout).pointSize
            return PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
            #endif
        }

        /// `ResponseTypography.heading`: semibold serif, title 2 down to body.
        static func heading(_ level: Int) -> PlatformFont {
            switch level {
            case 1: semibold(serif(.title2))
            case 2: semibold(serif(.title3))
            case 3: serif(.headline)
            default: semibold(serif(.body))
            }
        }

        static func semibold(_ font: PlatformFont) -> PlatformFont {
            let descriptor = font.fontDescriptor.addingAttributes([
                .traits: [PlatformFontDescriptorTraitKey.weight: PlatformFont.Weight.semibold],
            ])
            #if canImport(UIKit)
            return PlatformFont(descriptor: descriptor, size: 0)
            #else
            return PlatformFont(descriptor: descriptor, size: font.pointSize) ?? font
            #endif
        }

        static func serif(_ style: PlatformFont.TextStyle) -> PlatformFont {
            let base = PlatformFont.preferredFont(forTextStyle: style)
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            #if canImport(UIKit)
            return PlatformFont(descriptor: descriptor, size: 0)
            #else
            return PlatformFont(descriptor: descriptor, size: base.pointSize) ?? base
            #endif
        }

        static func bold(_ font: PlatformFont) -> PlatformFont { adding(bold: true, to: font) }
        static func italic(_ font: PlatformFont) -> PlatformFont { adding(bold: false, to: font) }

        private static func adding(bold: Bool, to font: PlatformFont) -> PlatformFont {
            #if canImport(UIKit)
            let trait: UIFontDescriptor.SymbolicTraits = bold ? .traitBold : .traitItalic
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)) else { return font }
            return PlatformFont(descriptor: descriptor, size: 0)
            #else
            let trait: NSFontDescriptor.SymbolicTraits = bold ? .bold : .italic
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            return PlatformFont(descriptor: descriptor, size: font.pointSize) ?? font
            #endif
        }
    }

    enum Colors {
        static var primary: PlatformColor { PlatformColor(Palette.textPrimary.color) }
        static var secondary: PlatformColor { PlatformColor(Palette.textSecondary.color) }
        static var accent: PlatformColor { PlatformColor(Palette.accent.color) }
        static var recessed: PlatformColor { PlatformColor(Palette.recessedSurface.color) }
    }
}

extension PlatformFont {
    /// A TextKit line in this font: ascender to descender plus the font's leading.
    var lineHeightWithLeading: CGFloat { ascender - descender + leading }
}
