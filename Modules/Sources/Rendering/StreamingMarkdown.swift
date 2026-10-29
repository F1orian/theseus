import Foundation

/// Incremental markdown for a streaming Response: a **frozen prefix** of finished blocks that is
/// parsed once, plus a **live tail** re-parsed on every update (ADR 0010).
///
/// The split point is the last blank line that is outside a code fence or display math and not
/// followed by an indented line (which could continue a list item). Blocks before it can't change
/// any more as text is appended, so each update costs only the tail.
public struct StreamingMarkdown: Sendable {
    public private(set) var blocks: [MarkdownBlock] = []
    /// How many leading blocks are frozen (stable identity for views).
    public private(set) var frozenCount = 0

    private var source = ""
    private var frozenEnd: String.Index?
    private var frozenBlocks: [MarkdownBlock] = []
    private var options = MarkdownParser.Options()

    public init() {}

    /// Updates to the full text so far. `isComplete` re-parses the whole document once, so the
    /// final rendering is exactly the non-streaming one.
    public mutating func update(_ text: String, isComplete: Bool, options: MarkdownParser.Options = .init()) {
        if options != self.options || !text.hasPrefix(frozenPrefix) {
            reset()
            self.options = options
        }
        source = text
        if isComplete {
            blocks = MarkdownParser.parse(text, options: options)
            frozenBlocks = blocks
            frozenCount = blocks.count
            frozenEnd = text.endIndex
            return
        }
        let start = frozenEnd ?? text.startIndex
        if let boundary = Self.boundary(in: text, from: start), boundary > start {
            frozenBlocks += MarkdownParser.parse(String(text[start..<boundary]), options: options)
            frozenEnd = boundary
        }
        let tailStart = frozenEnd ?? text.startIndex
        let tail = MarkdownParser.parse(String(text[tailStart...]), options: options)
        blocks = frozenBlocks + tail
        frozenCount = frozenBlocks.count
    }

    private var frozenPrefix: Substring {
        guard let frozenEnd, frozenEnd <= source.endIndex else { return "" }
        return source[..<frozenEnd]
    }

    private mutating func reset() {
        source = ""
        frozenEnd = nil
        frozenBlocks = []
        frozenCount = 0
        blocks = []
    }

    /// The index just after the last safe blank line at or after `start`, or `nil`.
    static func boundary(in text: String, from start: String.Index) -> String.Index? {
        var inFence: String?
        var inDisplayMath = false
        var lastBoundary: String.Index?
        var previousBlank = false
        var cursor = text.startIndex
        // Fence and math state depend on everything before `start`, so scan from the top, but
        // only boundaries at or after `start` count.
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[cursor..<lineEnd]
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let isBlank = trimmed.isEmpty
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex

            if let fence = inFence {
                if trimmed.hasPrefix(fence), trimmed.drop(while: { $0 == fence.first }).allSatisfy(\.isWhitespace) {
                    inFence = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if previousBlank, !inDisplayMath, line.first != " ", line.first != "\t", cursor >= start {
                    lastBoundary = cursor
                }
                let symbol = trimmed.first ?? "`"
                inFence = String(trimmed.prefix(while: { $0 == symbol }))
            } else {
                let dollars = line.components(separatedBy: "$$").count - 1
                if dollars % 2 == 1 { inDisplayMath.toggle() }
                // A blank line followed by an unindented line ends the previous block.
                if previousBlank, !isBlank, inFence == nil, !inDisplayMath || dollars % 2 == 1,
                   line.first != " ", line.first != "\t", cursor >= start {
                    lastBoundary = cursor
                }
            }
            previousBlank = isBlank && inFence == nil && !inDisplayMath
            if lineEnd == text.endIndex { break }
            cursor = next
        }
        return lastBoundary
    }
}
