public import Foundation

/// Open WebUI's text serialization of a Response's Thinking and tool calls: `<details type="…">`
/// blocks inside `message.content`, as the web client writes them when a Message has no `output`
/// items, e.g. in Chats imported from Claude or ChatGPT. Theseus reads them back into parts, so
/// the transcript never shows the raw markup (#180).
///
/// ```html
/// <details type="reasoning" done="true" duration="3">
/// <summary>Thought for 3 seconds</summary>
/// > The user wants…
/// </details>
/// <details type="tool_calls" done="true" id="toolu_1" name="web_search" arguments="&quot;{…}&quot;" result="…">
/// <summary>Tool Executed</summary>
/// </details>
/// ```
public enum SerializedContent {
    public enum Segment: Sendable, Hashable {
        /// Markdown between the blocks.
        case text(String)
        /// A `reasoning` block: its quoted text, unquoted.
        case reasoning(text: String, duration: TimeInterval?, isOpen: Bool)
        /// A `tool_calls` block.
        case toolCall(ToolActivity)
    }

    /// Whether `text` may hold serialized blocks (a cheap test before `segments`).
    public static func mayContainBlocks(_ text: String) -> Bool {
        text.contains("<details type=")
    }

    /// `text` split into markdown and its `reasoning` / `tool_calls` blocks, in order. Blocks inside
    /// code fences stay text; other `<details>` types keep their content as text, without the
    /// tags; an unclosed block (still streaming) runs to the end.
    public static func segments(_ text: String) -> [Segment] {
        guard mayContainBlocks(text) else { return text.isEmpty ? [] : [.text(text)] }
        var segments: [Segment] = []
        var prose: [Substring] = []
        var fence: String?
        var toolOrdinal = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(.text(joined)) }
            prose = []
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.drop(while: { $0 == " " })
            if let open = fence {
                prose.append(line)
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == open.first }).allSatisfy(\.isWhitespace) { fence = nil }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let symbol = trimmed.first ?? "`"
                fence = String(trimmed.prefix(while: { $0 == symbol }))
                prose.append(line)
                index += 1
                continue
            }
            guard trimmed.hasPrefix("<details type="), let tagEnd = trimmed.firstIndex(of: ">") else {
                prose.append(line)
                index += 1
                continue
            }
            // The block: from its opening tag to the matching `</details>` (blocks may nest).
            let attributes = Self.attributes(in: trimmed[trimmed.index(after: trimmed.startIndex)..<tagEnd])
            var body: [Substring] = []
            var rest = trimmed[trimmed.index(after: tagEnd)...]
            var depth = 1
            var closed = false
            while true {
                if let close = closingTag(in: rest, depth: &depth) {
                    body.append(rest[..<close.lowerBound])
                    // Text after the closing tag on the same line goes back to the prose.
                    let after = rest[close.upperBound...]
                    if !after.trimmingCharacters(in: .whitespaces).isEmpty { prose.append(after) }
                    closed = true
                    break
                }
                body.append(rest)
                index += 1
                guard index < lines.count else { break }
                rest = lines[index]
            }
            index += 1
            flushProse()
            switch attributes["type"] {
            case "reasoning":
                let text = Self.unquoted(Self.withoutSummary(body.joined(separator: "\n")))
                let duration = attributes["duration"].flatMap(TimeInterval.init)
                segments.append(.reasoning(text: text, duration: duration, isOpen: !closed || attributes["done"] == "false"))
            case "tool_calls":
                let id = attributes["id"].flatMap { $0.isEmpty ? nil : $0 } ?? "serialized-tool-\(toolOrdinal)"
                toolOrdinal += 1
                let done = attributes["done"] == "true"
                segments.append(.toolCall(ToolActivity(
                    id: id,
                    name: attributes["name"] ?? "",
                    arguments: Self.unwrappedJSON(attributes["arguments"] ?? ""),
                    isRunning: !done,
                    result: attributes["result"].map(Self.unwrappedJSON)
                )))
            default:
                // Other kinds (e.g. `code_interpreter`): their content as text, never the tags.
                let text = Self.withoutSummary(body.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { segments.append(.text(text)) }
            }
        }
        flushProse()
        return segments
    }

    /// The markdown of `text` without its serialized blocks.
    public static func plainText(_ text: String) -> String {
        guard mayContainBlocks(text) else { return text }
        return segments(text).compactMap { segment -> String? in
            if case .text(let markdown) = segment { return markdown }
            return nil
        }
        .joined(separator: "\n\n")
    }

    // MARK: Helpers

    /// Finds the `</details>` that closes the block in `line`, counting nested openings.
    private static func closingTag(in line: Substring, depth: inout Int) -> Range<Substring.Index>? {
        var cursor = line.startIndex
        while cursor < line.endIndex {
            let open = line[cursor...].range(of: "<details")
            let close = line[cursor...].range(of: "</details>")
            guard let close else {
                if open != nil { depth += line[cursor...].components(separatedBy: "<details").count - 1 }
                return nil
            }
            if let open, open.lowerBound < close.lowerBound {
                depth += 1
                cursor = open.upperBound
                continue
            }
            depth -= 1
            if depth == 0 { return close }
            cursor = close.upperBound
        }
        return nil
    }

    /// `name="value"` pairs of a tag (values entity-decoded): what `/([A-Za-z_:-]+)\s*=\s*"([^"]*)"/`
    /// matches, scanned by hand. (A regex literal is compiled again on every call, which made
    /// opening a long imported Chat take seconds.)
    static func attributes(in tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = tag.startIndex
        func skipWhitespace(_ index: inout Substring.Index) {
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
        }
        while cursor < tag.endIndex {
            guard isNameCharacter(tag[cursor]) else {
                cursor = tag.index(after: cursor)
                continue
            }
            let nameStart = cursor
            while cursor < tag.endIndex, isNameCharacter(tag[cursor]) { cursor = tag.index(after: cursor) }
            // No match from inside the name either (the rest is the same), so a miss resumes after it.
            var probe = cursor
            skipWhitespace(&probe)
            guard probe < tag.endIndex, tag[probe] == "=" else { continue }
            probe = tag.index(after: probe)
            skipWhitespace(&probe)
            guard probe < tag.endIndex, tag[probe] == "\"" else { continue }
            let valueStart = tag.index(after: probe)
            guard let valueEnd = tag[valueStart...].firstIndex(of: "\"") else { continue }
            result[String(tag[nameStart..<cursor])] = decodeEntities(String(tag[valueStart..<valueEnd]))
            cursor = tag.index(after: valueEnd)
        }
        return result
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character == "_" || character == ":" || character == "-"
    }

    /// Decodes the HTML entities Python's `html.escape` writes, plus numeric references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(12).firstIndex(of: ";") else {
                output.append("&")
                rest = rest.dropFirst()
                continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semicolon]
            let decoded: String? = switch entity {
            case "quot": "\""
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "apos": "'"
            case "nbsp": "\u{00A0}"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    nil
                }
            }
            if let decoded {
                output += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                output.append("&")
                rest = rest.dropFirst()
            }
        }
        output += rest
        return output
    }

    /// The web client writes arguments and results as JSON *strings* holding JSON; returns the
    /// inner JSON (or the value as is when it isn't such a string).
    static func unwrappedJSON(_ value: String) -> String {
        guard value.hasPrefix("\""),
              let data = value.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { return value }
        return inner
    }

    private static func withoutSummary(_ body: String) -> String {
        body.replacingOccurrences(of: #"(?s)<summary>.*?</summary>"#, with: "", options: .regularExpression)
    }

    /// Reasoning is written as a block quote; strips one level of `>`.
    private static func unquoted(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop(while: { $0 == " " })
                guard trimmed.hasPrefix(">") else { return line }
                let rest = trimmed.dropFirst()
                return rest.hasPrefix(" ") ? rest.dropFirst() : rest
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
