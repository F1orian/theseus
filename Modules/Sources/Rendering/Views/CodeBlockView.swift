import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colours for highlighted code, 4.5:1 or better on `recessedSurface` in light and dark. Cool
/// gallery tones (brand.md §1): numbers take the gilt's ochre rather than the clay orange of
/// the earlier palette, and comments the neutral tertiary ink.
enum CodePalette {
    static let keyword = ColorToken(light: RGBA(hex: 0x9C2C8F), dark: RGBA(hex: 0xE38AD6))
    static let string = ColorToken(light: RGBA(hex: 0x276B2B), dark: RGBA(hex: 0x9CCC65))
    static let comment = ColorToken(light: RGBA(hex: 0x5F6571), dark: RGBA(hex: 0x8E929C))
    static let number = ColorToken(light: RGBA(hex: 0x7A5A12), dark: RGBA(hex: 0xD6AE55))
    static let type = ColorToken(light: RGBA(hex: 0x1D4ED8), dark: RGBA(hex: 0x8AB4F8))

    static func color(_ kind: CodeHighlighter.TokenKind) -> Color {
        switch kind {
        case .keyword: keyword.color
        case .string: string.color
        case .comment: comment.color
        case .number: number.color
        case .type: type.color
        }
    }
}

/// A fenced code block: language label, copy button, monospaced and horizontally scrollable
/// (CHAT-04).
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    withMotion(Motion.bouncy) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withMotion(Motion.snappy) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Typography.caption)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary.color)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)

            Rectangle().fill(Palette.separator.color).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                let chunks = Self.chunks(highlighted)
                if chunks.count == 1 {
                    styled(Text(highlighted))
                        // Streamed code types itself in like prose (ADR 0130).
                        .streamingReveal(length: code.count)
                        .padding(Spacing.m)
                } else {
                    // A long file (an Artifact's code) as one Text is taller than the largest layer
                    // the GPU draws, and it renders blank; a stack of shorter Texts doesn't.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(chunks.indices, id: \.self) { index in
                            styled(Text(chunks[index]))
                        }
                    }
                    .padding(Spacing.m)
                }
            }
        }
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Palette.textPrimary.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
    }

    /// Lines per Text: well under the GPU's layer limit (16,384 px) at the largest Dynamic Type sizes.
    static let linesPerChunk = 60

    /// `text` cut into runs of `linesPerChunk` lines (the newline between two runs is dropped; the
    /// stack puts them on separate lines). One run for short code.
    static func chunks(_ text: AttributedString) -> [AttributedString] {
        let characters = text.characters
        var result: [AttributedString] = []
        var start = characters.startIndex
        var lines = 0
        var index = characters.startIndex
        while index < characters.endIndex {
            if characters[index] == "\n" {
                lines += 1
                if lines == linesPerChunk {
                    result.append(AttributedString(text[start..<index]))
                    start = characters.index(after: index)
                    lines = 0
                }
            }
            index = characters.index(after: index)
        }
        if start < characters.endIndex || result.isEmpty { result.append(AttributedString(text[start..<characters.endIndex])) }
        return result
    }

    private var highlighted: AttributedString {
        var attributed = AttributedString(code)
        let characters = attributed.characters
        for token in CodeHighlighter.tokens(in: code, language: language) {
            guard token.range.upperBound <= code.count else { continue }
            let lower = characters.index(characters.startIndex, offsetBy: token.range.lowerBound)
            let upper = characters.index(characters.startIndex, offsetBy: token.range.upperBound)
            attributed[lower..<upper].foregroundColor = CodePalette.color(token.kind)
            if token.kind == .comment { attributed[lower..<upper].inlinePresentationIntent = .emphasized }
        }
        return attributed
    }
}

enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
