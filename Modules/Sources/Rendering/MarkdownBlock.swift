public import Foundation

/// Inline formatting of one run of text.
public struct InlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let strong = InlineStyle(rawValue: 1 << 0)
    public static let emphasis = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let code = InlineStyle(rawValue: 1 << 3)
}

/// One run of inline content.
public enum InlineRun: Sendable, Hashable {
    case text(String, InlineStyle, link: URL?)
    /// Inline LaTeX (`$…$`, `\(…\)`).
    case math(String)
    /// A citation marker `[n]` pointing at the Response's Sources (CHAT-07).
    case citation(Int)
    case lineBreak
}

/// A paragraph-level run list.
public struct InlineContent: Sendable, Hashable {
    public var runs: [InlineRun]

    public init(_ runs: [InlineRun] = []) {
        self.runs = runs
    }

    public var isEmpty: Bool { runs.isEmpty }

    /// The visible text without formatting (for accessibility, copy and tests).
    public var plainText: String {
        runs.map { run in
            switch run {
            case .text(let text, _, _): text
            case .math(let latex): latex
            case .citation(let number): "[\(number)]"
            case .lineBreak: "\n"
            }
        }.joined()
    }
}

public struct ListItem: Sendable, Hashable {
    /// `nil` for plain items; `true`/`false` for task-list checkboxes.
    public var checkbox: Bool?
    public var blocks: [MarkdownBlock]

    public init(checkbox: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

public struct MarkdownTable: Sendable, Hashable {
    public enum Alignment: Sendable, Hashable { case leading, center, trailing }

    public var alignments: [Alignment]
    public var header: [InlineContent]
    public var rows: [[InlineContent]]

    public init(alignments: [Alignment], header: [InlineContent], rows: [[InlineContent]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

/// A block of a rendered Response: the renderer's own model, independent of the parser.
public indirect enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, InlineContent)
    case paragraph(InlineContent)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case quote([MarkdownBlock])
    case code(language: String?, code: String)
    /// Display LaTeX (`$$…$$`, `\[…\]`, or a `math` fence).
    case math(String)
    case table(MarkdownTable)
    case rule
}
