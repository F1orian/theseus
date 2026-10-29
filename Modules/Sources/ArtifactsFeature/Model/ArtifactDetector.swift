import Foundation
import Rendering

/// Finds Artifacts in a Response (ADR 0060): fenced code blocks with a renderable language that
/// are big enough to stand alone, plus HTML tool embeds.
public enum ArtifactDetector {
    /// Below this many non-empty lines, HTML (without a document marker), JSX and markdown stay
    /// ordinary code blocks.
    public static let minimumLines = 12

    /// The Artifacts of one Response, in order: code blocks first, then tool embeds.
    /// - Parameter isStreaming: The Response is still being written, so its last fence may be open.
    public static func artifacts(messageID: String, text: String, embeds: [String] = [], isStreaming: Bool = false) -> [Artifact] {
        var result: [Artifact] = []
        if text.contains("```") || text.contains("~~~") {
            let blocks = codeBlocks(in: MarkdownParser.parse(text))
            let lastIsOpen = isStreaming && hasOpenFence(text)
            for (offset, block) in blocks.enumerated() {
                let isOpen = lastIsOpen && offset == blocks.count - 1
                guard let kind = kind(language: block.language, code: block.code, isOpen: isOpen) else { continue }
                result.append(Artifact(
                    messageID: messageID,
                    index: result.count,
                    kind: kind,
                    language: block.language,
                    title: title(kind: kind, content: block.code),
                    content: block.code,
                    isComplete: !isOpen
                ))
            }
        }
        for embed in embeds where !isURL(embed) && !embed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Artifact(
                messageID: messageID,
                index: result.count,
                kind: .webPage,
                origin: .toolEmbed,
                language: "html",
                title: htmlTitle(embed) ?? "Tool view",
                content: embed
            ))
        }
        return result
    }

    /// The Artifact kind a fence could become, judged by its language alone (`nil`: always code).
    /// The transcript asks this first so ordinary code blocks never pay for detection.
    public static func candidateKind(language: String?) -> Artifact.Kind? {
        switch language?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "html", "htm", "xhtml": .webPage
        case "svg", "xml": .image
        case "mermaid": .diagram
        case "jsx", "tsx", "react": .component
        case "markdown", "md": .document
        default: nil
        }
    }

    /// The kind of an Artifact this fence is, or `nil` when it stays a code block. An open fence
    /// (still streaming) counts as soon as its language qualifies; size rules apply once it closes.
    public static func kind(language: String?, code: String, isOpen: Bool = false) -> Artifact.Kind? {
        guard let kind = candidateKind(language: language) else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .image:
            // `xml` only when it's an SVG; an open `xml` fence may not show its root yet.
            let isSVG = trimmed.range(of: #"^(<\?xml[^>]*>\s*)?(<!--.*?-->\s*)*(<!doctype[^>]*>\s*)?<svg[\s>]"#,
                                      options: [.regularExpression, .caseInsensitive]) != nil
            if language?.lowercased() == "xml" { return isSVG ? .image : nil }
            return isSVG || isOpen ? .image : nil
        case .diagram:
            return trimmed.isEmpty && !isOpen ? nil : .diagram
        case .webPage:
            if isOpen { return .webPage }
            let lower = trimmed.lowercased()
            let isDocument = ["<!doctype", "<html", "<head", "<body"].contains { lower.contains($0) }
            if isDocument { return .webPage }
            // A snippet to paste into another page (a `<script>` or `<style>` block, #180) would
            // open as a blank page: only fragments that show something are Artifacts.
            return nonEmptyLines(code) >= minimumLines && showsContent(fragment: code) ? .webPage : nil
        case .code:
            return nil
        case .component, .document:
            return isOpen || nonEmptyLines(code) >= minimumLines ? kind : nil
        }
    }

    // MARK: Titles

    /// A human title from the content, or the kind's name.
    public static func title(kind: Artifact.Kind, content: String) -> String {
        switch kind {
        case .webPage: htmlTitle(content) ?? "Web page"
        case .image: firstMatch(#"<title[^>]*>(.*?)</title>"#, in: content).map(cleanHTML).flatMap(nonEmpty) ?? "Image"
        case .diagram: mermaidTitle(content)
        case .component: componentTitle(content) ?? "Component"
        case .document: markdownTitle(content) ?? "Document"
        case .code: "Code"
        }
    }

    /// `<title>`, else the first `<h1>`, else (for fragments, #180) the first `<h2>` or `<h3>`.
    static func htmlTitle(_ html: String) -> String? {
        let title = firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html).map(cleanHTML).flatMap(nonEmpty)
            ?? firstMatch(#"<h1[^>]*>(.*?)</h1>"#, in: html).map(cleanHTML).flatMap(nonEmpty)
        if let title { return title }
        // A lesser heading only when it reads like a title, not a sentence.
        let heading = lastGroup(#"<h([23])[^>]*>(.*?)</h\1>"#, in: html).map(cleanHTML).flatMap(nonEmpty)
        return heading.flatMap { $0.split(separator: " ").count <= 6 ? $0 : nil }
    }

    /// Whether an HTML fragment draws anything: markup or text outside `<script>`, `<style>`,
    /// comments and head-only tags, or a script that builds the page itself.
    static func showsContent(fragment: String) -> Bool {
        var visible = fragment
        for pattern in [#"(?s)<script\b[^>]*>.*?</script\s*>"#, #"(?s)<style\b[^>]*>.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"<(meta|link|base|title)\b[^>]*>"#] {
            visible = visible.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if visible.contains(where: { !$0.isWhitespace }) { return true }
        let builders = #"createElement|innerHTML|insertAdjacentHTML|document\.write|appendChild|body\.append\(|getContext\("#
        return fragment.range(of: builders, options: .regularExpression) != nil
    }

    static func mermaidTitle(_ source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // YAML front matter: `---` / `title: …` / `---`.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            if let title = lines[1..<end].first(where: { $0.hasPrefix("title:") }) {
                let value = title.dropFirst("title:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !value.isEmpty { return value }
            }
            lines.removeSubrange(0...end)
        }
        let meaningful = lines.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        if let titled = meaningful.first(where: { $0.hasPrefix("title ") }) {
            return String(titled.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = meaningful.first else { return "Diagram" }
        let keyword = first.split(whereSeparator: { $0 == " " || $0 == ";" }).first.map(String.init) ?? ""
        if keyword == "pie", let range = first.range(of: " title ") {
            return String(first[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return switch keyword.lowercased() {
        case "graph", "flowchart", "flowchart-elk": "Flowchart"
        case "sequencediagram": "Sequence diagram"
        case "classdiagram", "classdiagram-v2": "Class diagram"
        case "statediagram", "statediagram-v2": "State diagram"
        case "erdiagram": "Entity relationship diagram"
        case "gantt": "Gantt chart"
        case "pie": "Pie chart"
        case "journey": "User journey"
        case "gitgraph": "Git graph"
        case "mindmap": "Mind map"
        case "timeline": "Timeline"
        case "quadrantchart": "Quadrant chart"
        case "sankey", "sankey-beta": "Sankey diagram"
        case "xychart", "xychart-beta": "Chart"
        case "block", "block-beta": "Block diagram"
        case "architecture", "architecture-beta": "Architecture diagram"
        default: "Diagram"
        }
    }

    static func componentTitle(_ source: String) -> String? {
        let patterns = [
            #"export\s+default\s+(?:async\s+)?function\s+([A-Z][A-Za-z0-9_]*)"#,
            #"export\s+default\s+([A-Z][A-Za-z0-9_]*)\s*;?\s*$"#,
            #"(?:function|const|let|class)\s+([A-Z][A-Za-z0-9_]*)"#,
        ]
        for pattern in patterns {
            if let name = firstMatch(pattern, in: source, multiline: true) {
                return splitCamelCase(name)
            }
        }
        return nil
    }

    static func markdownTitle(_ source: String) -> String? {
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            let plain = title.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            if !plain.isEmpty { return plain }
        }
        return nil
    }

    // MARK: Helpers

    struct CodeBlock {
        let language: String?
        let code: String
    }

    static func codeBlocks(in blocks: [MarkdownBlock]) -> [CodeBlock] {
        blocks.flatMap { block -> [CodeBlock] in
            switch block {
            case .code(let language, let code): [CodeBlock(language: language, code: code)]
            case .quote(let children): codeBlocks(in: children)
            case .list(_, _, let items): items.flatMap { codeBlocks(in: $0.blocks) }
            default: []
            }
        }
    }

    /// Whether the text ends inside a fenced code block (a closing fence uses the same character,
    /// at least as many of them, and nothing else on its line).
    static func hasOpenFence(_ text: String) -> Bool {
        var open: (character: Character, count: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix(while: { $0 == first }).count
            guard run >= 3 else { continue }
            if let current = open {
                if first == current.character, run >= current.count,
                   trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                    open = nil
                }
            } else {
                open = (first, run)
            }
        }
        return open != nil
    }

    static func nonEmptyLines(_ code: String) -> Int {
        code.split(separator: "\n").count { !$0.allSatisfy(\.isWhitespace) }
    }

    static func isURL(_ embed: String) -> Bool {
        let trimmed = embed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://")) && !trimmed.contains(where: \.isWhitespace)
    }

    static func firstMatch(_ pattern: String, in text: String, multiline: Bool = false) -> String? {
        var options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        if multiline { options = [.anchorsMatchLines] }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// The last capture group of the first match (for patterns with a back-reference group).
    static func lastGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges - 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// Strips tags, decodes the common entities and collapses whitespace.
    static func cleanHTML(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// `TipCalculator` → `Tip Calculator`.
    static func splitCamelCase(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name where character != "_" {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }
}
