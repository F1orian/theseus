import Foundation

/// Turns a Response's markdown into text worth reading aloud (MSG-07): markup, links, citation
/// markers and code blocks are dropped, list items and headings become plain sentences.
public enum SpeechText {
    public static func plain(from markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            var line = trimmed
            // Table separator rows (|---|:--:|) carry nothing to say.
            if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { continue }
            if line.allSatisfy({ "-*_ ".contains($0) }) {
                lines.append("")
                continue
            }
            // Headings, list items and table rows end without punctuation; give them a pause.
            let isItem = line.hasPrefix("#") || line.hasPrefix("|") || line.contains(/^([-*+]|\d+[.)])\s/)
            line = line.replacing(/^#{1,6}\s+/, with: "")
            line = line.replacing(/^(>\s?)+/, with: "")
            line = line.replacing(/^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, with: "")
            line = inline(line)
            if isItem, let last = line.last, !".!?:;".contains(last) { line += "." }
            lines.append(line)
        }
        // Collapse runs of blank lines into paragraph breaks.
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func inline(_ text: String) -> String {
        var line = text
        line = line.replacing(/!\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        line = line.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
        // Citation markers: [1], [2, 3].
        line = line.replacing(/\s?\[\d+(,\s*\d+)*\]/, with: "")
        line = line.replacing(/<[^>]+>/, with: "")
        line = line.replacing(/(\*\*|__|~~|`)/, with: "")
        line = line.replacing(/(^|[\s(])[*_]([^*_\s][^*_]*?)[*_](?=$|[\s.,;:!?)])/) { "\($0.output.1)\($0.output.2)" }
        line = line.replacing("|", with: " ")
        line = line.replacing(/\s{2,}/, with: " ")
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Splits text into chunks of at most `limit` characters at sentence or paragraph ends, so
    /// server speech can start before the whole Response is synthesised.
    public static func chunks(of text: String, limit: Int = 400) -> [String] {
        var result: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            var current = ""
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
                if !current.isEmpty, current.count + sentence.count + 1 > limit {
                    result.append(current)
                    current = ""
                }
                current = current.isEmpty ? sentence : "\(current) \(sentence)"
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }
}
