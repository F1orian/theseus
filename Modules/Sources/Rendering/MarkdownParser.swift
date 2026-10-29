import Foundation
import Markdown

/// Parses Response markdown (CommonMark + GFM tables, strikethrough, task lists) into
/// `MarkdownBlock`s, with LaTeX math (CHAT-05) and citation markers (CHAT-07).
public enum MarkdownParser {
    public struct Options: Sendable, Hashable {
        /// Turn `[n]` into citation runs (only when the Response has Sources).
        public var citations: Bool

        public init(citations: Bool = false) {
            self.citations = citations
        }
    }

    public static func parse(_ source: String, options: Options = Options()) -> [MarkdownBlock] {
        let prepared = MathExtractor.extract(from: source)
        let document = Document(parsing: prepared.markdown)
        let converter = Converter(math: prepared.inlineMath, options: options)
        return document.children.compactMap { converter.block($0) }
    }
}

/// Converts swift-markdown's tree into `MarkdownBlock`s.
private struct Converter {
    let math: [String]
    let options: MarkdownParser.Options

    init(math: [String], options: MarkdownParser.Options) {
        self.math = math
        self.options = options
    }

    func block(_ markup: any Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inlines(heading))
        case let paragraph as Paragraph:
            let content = inlines(paragraph)
            return content.isEmpty ? nil : .paragraph(content)
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: list.listItems.map(item))
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item))
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap { block($0) })
        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased()
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            if language == MathExtractor.displayFence || language == "latex" && Self.looksLikeMath(body) {
                return .math(body)
            }
            return .code(language: language?.isEmpty == true ? nil : language, code: body)
        case let table as Markdown.Table:
            return .table(MarkdownTable(
                alignments: table.columnAlignments.map { alignment in
                    switch alignment {
                    case .center: .center
                    case .right: .trailing
                    default: .leading
                    }
                },
                header: table.head.cells.map { inlines($0) },
                rows: table.body.rows.map { row in row.cells.map { inlines($0) } }
            ))
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            // Raw HTML isn't rendered; show its text so nothing silently disappears.
            let text = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph(InlineContent([.text(text, [], link: nil)]))
        default:
            return nil
        }
    }

    private static func looksLikeMath(_ body: String) -> Bool {
        !body.contains("\\documentclass") && !body.contains("\\begin{document}")
    }

    func item(_ item: Markdown.ListItem) -> ListItem {
        let checkbox: Bool? = switch item.checkbox {
        case .checked: true
        case .unchecked: false
        case nil: nil
        }
        return ListItem(checkbox: checkbox, blocks: item.children.compactMap { block($0) })
    }

    func inlines(_ container: any Markup) -> InlineContent {
        var runs: [InlineRun] = []
        for child in container.children {
            append(child, style: [], link: nil, to: &runs)
        }
        return InlineContent(Self.merged(runs))
    }

    private func append(_ markup: any Markup, style: InlineStyle, link: URL?, to runs: inout [InlineRun]) {
        switch markup {
        case let text as Markdown.Text:
            appendText(text.string, style: style, link: link, to: &runs)
        case is SoftBreak:
            appendText(" ", style: style, link: link, to: &runs)
        case is LineBreak:
            runs.append(.lineBreak)
        case let code as InlineCode:
            if let index = MathExtractor.inlineIndex(code.code), index < math.count {
                runs.append(.math(math[index]))
            } else {
                runs.append(.text(code.code, style.union(.code), link: link))
            }
        case let emphasis as Emphasis:
            for child in emphasis.children { append(child, style: style.union(.emphasis), link: link, to: &runs) }
        case let strong as Strong:
            for child in strong.children { append(child, style: style.union(.strong), link: link, to: &runs) }
        case let strike as Strikethrough:
            for child in strike.children { append(child, style: style.union(.strikethrough), link: link, to: &runs) }
        case let anchor as Markdown.Link:
            let url = anchor.destination.flatMap(URL.init(string:))
            if anchor.childCount == 0 {
                appendText(anchor.destination ?? "", style: style, link: url, to: &runs)
            }
            for child in anchor.children { append(child, style: style, link: url, to: &runs) }
        case let image as Markdown.Image:
            // Images aren't fetched inline yet; show the alt text as a link to the source.
            let alt = image.plainText.isEmpty ? "Image" : image.plainText
            appendText(alt, style: style, link: image.source.flatMap(URL.init(string:)), to: &runs)
        case let html as InlineHTML:
            let raw = html.rawHTML
            if raw.lowercased().hasPrefix("<br") { runs.append(.lineBreak) } else { appendText(raw, style: style, link: link, to: &runs) }
        default:
            for child in markup.children { append(child, style: style, link: link, to: &runs) }
        }
    }

    private func appendText(_ text: String, style: InlineStyle, link: URL?, to runs: inout [InlineRun]) {
        guard options.citations, link == nil, !style.contains(.code), text.contains("[") else {
            runs.append(.text(text, style, link: link))
            return
        }
        var rest = Substring(text)
        while let match = rest.firstMatch(of: /\[(\d{1,3})\]/) {
            let before = rest[..<match.range.lowerBound]
            if !before.isEmpty { runs.append(.text(String(before), style, link: nil)) }
            if let number = Int(match.output.1) { runs.append(.citation(number)) }
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { runs.append(.text(String(rest), style, link: nil)) }
    }

    /// Joins adjacent text runs with identical formatting.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs {
            if case .text(let text, let style, let link) = run,
               case .text(let previous, let previousStyle, let previousLink)? = result.last,
               style == previousStyle, link == previousLink {
                result[result.count - 1] = .text(previous + text, style, link: link)
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// Finds LaTeX math outside code before markdown parsing (cmark doesn't know math):
/// display math becomes a ```` ```math ```` fence, inline math a placeholder code span.
enum MathExtractor {
    static let displayFence = "math"
    /// Private-use prefix for inline placeholders: `` `\u{E000}<n>` ``.
    private static let marker: Character = "\u{E000}"

    struct Result {
        var markdown: String
        var inlineMath: [String]
    }

    static func inlineIndex(_ code: String) -> Int? {
        guard code.first == marker else { return nil }
        return Int(code.dropFirst())
    }

    static func extract(from source: String) -> Result {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else {
            return Result(markdown: source, inlineMath: [])
        }
        var output = ""
        var inline: [String] = []
        var prose = ""
        var fence: String?

        func flushProse() {
            output += replaceMath(in: prose, inline: &inline)
            prose = ""
        }

        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        var first = true
        while let line = lines.next() {
            let newline = first ? "" : "\n"
            first = false
            let trimmed = line.drop(while: { $0 == " " })
            if let open = fence {
                output += newline + line
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let symbol = trimmed.first ?? "`"
                fence = String(trimmed.prefix(while: { $0 == symbol }))
                output += newline + line
                continue
            }
            prose += newline + line
        }
        flushProse()
        return Result(markdown: output, inlineMath: inline)
    }

    /// Replaces math in a code-fence-free stretch of markdown, leaving inline code spans alone.
    private static func replaceMath(in text: String, inline: inout [String]) -> String {
        guard !text.isEmpty else { return text }
        let chars = Array(text)
        var result = ""
        var index = 0

        func starts(_ token: String, at position: Int) -> Bool {
            let tokenChars = Array(token)
            guard position + tokenChars.count <= chars.count else { return false }
            return Array(chars[position..<position + tokenChars.count]) == tokenChars
        }
        func find(_ token: String, from position: Int) -> Int? {
            var cursor = position
            while cursor < chars.count {
                if chars[cursor] == "\\", !token.hasPrefix("\\") { cursor += 2; continue }
                if starts(token, at: cursor) { return cursor }
                cursor += 1
            }
            return nil
        }
        func display(_ latex: String) -> String {
            "\n\n```\(displayFence)\n\(latex.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n\n"
        }
        func placeholder(_ latex: String) -> String {
            inline.append(latex.trimmingCharacters(in: .whitespaces))
            return "`\(marker)\(inline.count - 1)`"
        }

        while index < chars.count {
            let char = chars[index]
            // Inline code spans: copy verbatim.
            if char == "`" {
                let run = chars[index...].prefix(while: { $0 == "`" }).count
                let ticks = String(repeating: "`", count: run)
                if let close = find(ticks, from: index + run) {
                    result += String(chars[index..<close + run])
                    index = close + run
                    continue
                }
                result += ticks
                index += run
                continue
            }
            if char == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "[", let close = find("\\]", from: index + 2) {
                    result += display(String(chars[index + 2..<close]))
                    index = close + 2
                    continue
                }
                if next == "(", let close = find("\\)", from: index + 2) {
                    result += placeholder(String(chars[index + 2..<close]))
                    index = close + 2
                    continue
                }
                result.append(char)
                result.append(next)
                index += 2
                continue
            }
            if char == "$" {
                if starts("$$", at: index) {
                    if let close = find("$$", from: index + 2) {
                        result += display(String(chars[index + 2..<close]))
                        index = close + 2
                    } else {
                        // Still streaming: everything after an unclosed $$ is display math.
                        result += display(String(chars[(index + 2)...]))
                        index = chars.count
                    }
                    continue
                }
                if let close = inlineDollarClose(chars, open: index) {
                    result += placeholder(String(chars[index + 1..<close]))
                    index = close + 1
                    continue
                }
            }
            result.append(char)
            index += 1
        }
        return result
    }

    /// Pandoc's rule: `$` must be followed by non-space, the closing `$` preceded by non-space
    /// and not followed by a digit, on the same paragraph. This keeps "$5 and $10" as text.
    private static func inlineDollarClose(_ chars: [Character], open: Int) -> Int? {
        let start = open + 1
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }
        var cursor = start
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "\\" { cursor += 2; continue }
            if char == "\n", cursor + 1 < chars.count, chars[cursor + 1] == "\n" { return nil }
            if char == "$" {
                let before = chars[cursor - 1]
                let after = cursor + 1 < chars.count ? chars[cursor + 1] : " "
                if cursor > start, !before.isWhitespace, !after.isNumber { return cursor }

            }
            cursor += 1
        }
        return nil
    }
}
