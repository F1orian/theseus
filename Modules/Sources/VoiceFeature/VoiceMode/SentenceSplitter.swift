import Foundation
import MessageActionsFeature

/// Cuts a streaming Response into speakable pieces as it grows (VOICE-03): everything up to the
/// last finished sentence or line is returned once, as plain text without markdown (`SpeechText`).
/// Code blocks are never cut open, and list numbers ("1.") aren't sentence ends.
struct SentenceSplitter {
    /// How much of the Response's markdown has been handed out.
    private(set) var consumed = 0

    /// The new speakable pieces of `markdown` (the whole Response so far). With `isFinal`, the
    /// rest is returned too.
    mutating func feed(_ markdown: String, isFinal: Bool) -> [String] {
        let characters = Array(markdown)
        guard characters.count > consumed else { return [] }
        let end = isFinal ? characters.count : lastBoundary(in: characters)
        guard end > consumed else { return [] }
        let piece = String(characters[consumed..<end])
        consumed = end
        let text = SpeechText.plain(from: piece)
        return text.isEmpty ? [] : [text]
    }

    /// The index just after the last sentence end (or line break) outside a code block that has
    /// whitespace after it, or `consumed` when there is none yet.
    private func lastBoundary(in characters: [Character]) -> Int {
        var best = consumed
        var inFence = false
        var lineStart = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if index == lineStart, isFence(characters, at: index) {
                inFence.toggle()
            }
            if character == "\n" {
                if !inFence, index + 1 > consumed { best = index + 1 }
                lineStart = index + 1
            } else if !inFence, ".!?".contains(character), index + 1 < characters.count,
                      characters[index + 1] == " " || characters[index + 1] == "\n",
                      !isListNumber(characters, lineStart: lineStart, end: index) {
                if index + 1 > consumed { best = index + 1 }
            }
            index += 1
        }
        return best
    }

    private func isFence(_ characters: [Character], at index: Int) -> Bool {
        var position = index
        while position < characters.count, characters[position] == " " { position += 1 }
        guard position + 2 < characters.count else { return false }
        let marker = characters[position]
        return (marker == "`" || marker == "~") && characters[position + 1] == marker && characters[position + 2] == marker
    }

    /// "12." at the start of a line (after indentation) is a list number, not a sentence end.
    private func isListNumber(_ characters: [Character], lineStart: Int, end: Int) -> Bool {
        let prefix = characters[lineStart..<end].drop { $0 == " " }
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber)
    }
}
