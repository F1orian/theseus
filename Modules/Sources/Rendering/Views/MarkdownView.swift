import DesignSystem
public import Foundation
public import SwiftUI

/// The reading voice of Responses: a serif face with generous leading (CHAT-03).
public enum ResponseTypography {
    public static let body = Font.system(.body, design: .serif)
    public static let lineSpacing: CGFloat = 5
    public static let blockSpacing: CGFloat = 14

    static func heading(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title2, design: .serif).weight(.semibold)
        case 2: .system(.title3, design: .serif).weight(.semibold)
        case 3: .system(.headline, design: .serif)
        default: .system(.body, design: .serif).weight(.semibold)
        }
    }
}

/// The URL scheme citation markers use, so taps can be routed to the Sources list.
public enum CitationLink {
    public static let scheme = "theseus-citation"

    public static func url(_ number: Int) -> URL? {
        URL(string: "\(scheme)://\(number)")
    }

    public static func number(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return url.host().flatMap(Int.init)
    }
}

/// Renders parsed markdown blocks.
public struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let selectsAcrossBlocks: Bool

    /// - Parameter selectsAcrossBlocks: Render runs of prose as one selectable text each, so a
    ///   selection spans paragraphs, headings and list items (#175; finished Responses). Off
    ///   while text streams: each block then reveals itself as it arrives (ADR 0010, 0130).
    public init(blocks: [MarkdownBlock], selectsAcrossBlocks: Bool = false) {
        self.blocks = blocks
        self.selectsAcrossBlocks = selectsAcrossBlocks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ResponseTypography.blockSpacing) {
            if selectsAcrossBlocks {
                ForEach(Array(MarkdownSegment.group(blocks).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .prose(let run): SelectableProseView(blocks: run)
                    case .block(let block): BlockView(block: block).equatable()
                    }
                }
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    // Equatable: frozen blocks skip body evaluation while the tail streams.
                    BlockView(block: block).equatable()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Markdown that may still be streaming: re-parses only the live tail on each change.
public struct StreamingMarkdownView: View {
    private let text: String
    private let isStreaming: Bool
    private let options: MarkdownParser.Options
    /// A reference cache, so an update parses in the same pass that renders it (no extra
    /// state-change round trip per token batch).
    @State private var cache = StreamingMarkdownCache()

    public init(text: String, isStreaming: Bool, citations: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
        options = MarkdownParser.Options(citations: citations)
    }

    public var body: some View {
        MarkdownView(blocks: cache.blocks(for: text, isComplete: !isStreaming, options: options), selectsAcrossBlocks: !isStreaming)
            // New text fades in as it arrives (CHAT-01, ADR 0130).
            .environment(\.isStreamingMarkdown, isStreaming)
    }
}

@MainActor
final class StreamingMarkdownCache {
    private var document = StreamingMarkdown()
    private var last: (text: String, isComplete: Bool, options: MarkdownParser.Options)?

    func blocks(for text: String, isComplete: Bool, options: MarkdownParser.Options) -> [MarkdownBlock] {
        if let last, last.text == text, last.isComplete == isComplete, last.options == options {
            return document.blocks
        }
        document.update(text, isComplete: isComplete, options: options)
        last = (text, isComplete, options)
        return document.blocks
    }
}

struct BlockView: View, Equatable {
    let block: MarkdownBlock
    @Environment(\.isStreamingMarkdown) private var isStreaming

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
    }

    var body: some View {
        content
            // A code block, table or rule arriving mid-stream fades in rather than popping in;
            // text inside reveals itself glyph by glyph.
            .fadeInOnAppear(isStreaming && !block.isText)
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .heading(let level, let content):
            InlineTextView(content: content, font: ResponseTypography.heading(level))
                .padding(.top, level <= 2 ? Spacing.xs : 0)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            InlineTextView(content: content, font: ResponseTypography.body)
        case .list(let ordered, let start, let items):
            ListBlockView(ordered: ordered, start: start, items: items)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: Spacing.m) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.separator.color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: ResponseTypography.blockSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in BlockView(block: child) }
                }
                .foregroundStyle(Palette.textSecondary.color)
            }
        case .code(let language, let code):
            CodeBlockSlot(language: language, code: code)
        case .math(let latex):
            MathBlockView(latex: latex)
        case .table(let table):
            TableBlockView(table: table)
        case .rule:
            Rectangle()
                .fill(Palette.separator.color)
                .frame(height: 1)
                .padding(.vertical, Spacing.xs)
        }
    }
}

extension MarkdownBlock {
    /// Text-only blocks reveal glyph by glyph; others fade in as a whole.
    var isText: Bool {
        switch self {
        case .heading, .paragraph, .list, .quote: true
        case .code, .math, .table, .rule: false
        }
    }
}

struct ListBlockView: View {
    let ordered: Bool
    let start: Int
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    marker(index: index, item: item)
                        .font(ResponseTypography.body)
                        .foregroundStyle(Palette.textSecondary.color)
                        .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in BlockView(block: child) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: ListItem) -> some View {
        if let checked = item.checkbox {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered {
            Text("\(start + index).").monospacedDigit()
        } else {
            Text("•")
        }
    }
}

/// One paragraph of inline runs as a single `Text`, so it wraps and selects naturally.
struct InlineTextView: View {
    let content: InlineContent
    let font: Font
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var mathSize: CGFloat = 17

    var body: some View {
        composed
            .font(font)
            .lineSpacing(ResponseTypography.lineSpacing)
            .foregroundStyle(Palette.textPrimary.color)
            .tint(Palette.accent.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .streamingReveal(length: content.revealLength)
    }

    private var composed: Text {
        var text = Text("")
        var pending = AttributedString()
        func flush() {
            guard !pending.characters.isEmpty else { return }
            text = Text("\(text)\(Text(pending))")
            pending = AttributedString()
        }
        for run in content.runs {
            switch run {
            case .text(let string, let style, let link):
                pending.append(Self.attributed(string, style: style, link: link, dark: colorScheme == .dark))
            case .lineBreak:
                pending.append(AttributedString("\n"))
            case .citation(let number):
                var marker = AttributedString("\u{2009}\(number)\u{2009}")
                marker.font = .caption2.weight(.semibold)
                marker.foregroundColor = Palette.accent.color
                marker.baselineOffset = 5
                marker.link = CitationLink.url(number)
                pending.append(marker)
            case .math(let latex):
                if let rendered = MathRenderer.shared.render(latex, fontSize: mathSize, display: false, dark: colorScheme == .dark) {
                    flush()
                    let image = Text(rendered.image).baselineOffset(-rendered.size.height * 0.28)
                    text = Text("\(text)\(image)")
                } else {
                    pending.append(Self.attributed(latex, style: .code, link: nil, dark: colorScheme == .dark))
                }
            }
        }
        flush()
        return text
    }

    static func attributed(_ string: String, style: InlineStyle, link: URL?, dark: Bool) -> AttributedString {
        var attributed = AttributedString(string)
        var intent: InlinePresentationIntent = []
        if style.contains(.strong) { intent.insert(.stronglyEmphasized) }
        if style.contains(.emphasis) { intent.insert(.emphasized) }
        if style.contains(.strikethrough) { intent.insert(.strikethrough) }
        if style.contains(.code) {
            intent.insert(.code)
            attributed.backgroundColor = Palette.recessedSurface.color
        }
        if !intent.isEmpty { attributed.inlinePresentationIntent = intent }
        if let link {
            attributed.link = link
            attributed.underlineStyle = .single
        }
        return attributed
    }
}

extension InlineContent {
    /// About how many glyphs the paragraph draws (math draws as one image).
    var revealLength: Int {
        runs.reduce(0) { count, run in
            switch run {
            case .text(let string, _, _): count + string.count
            case .lineBreak: count + 1
            case .citation(let number): count + String(number).count + 2
            case .math: count + 1
            }
        }
    }
}

struct TableBlockView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column)
                        }
                    }
                }
            }
            .padding(Spacing.m)
        }
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
    }

    private func cellView(_ cell: InlineContent, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        // The horizontal scroll view offers unlimited width, so a long cell would be measured
        // as one line and then drawn wrapped at 280 pt over the next row: measure it at 280 pt.
        return CappedWidth(maxWidth: 280) {
            InlineTextView(content: cell, font: .system(.callout, design: .serif))
        }
        .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
        .frame(minWidth: 40, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}

/// Lays its content out at most `maxWidth` wide, also when the container offers unlimited or
/// unspecified width (a horizontal scroll view, a Grid's ideal-size pass), so wrapped text
/// reports its real height.
struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return ProposedViewSize(width: width.isFinite ? width : maxWidth, height: proposal.height)
    }
}
