import Foundation
@testable import Rendering
import Testing

/// Long code is drawn as a stack of shorter Texts (a single Text taller than the GPU's layer
/// limit renders blank, e.g. an Artifact's whole file).
struct CodeChunksTests {
    @Test func shortCodeIsOneChunk() {
        let chunks = CodeBlockView.chunks(AttributedString("let a = 1\nlet b = 2"))
        #expect(chunks.count == 1)
        #expect(String(chunks[0].characters) == "let a = 1\nlet b = 2")
    }

    @Test func longCodeSplitsOnLineBoundariesAndLosesNothing() {
        let lines = (1...150).map { "line \($0)" }
        let chunks = CodeBlockView.chunks(AttributedString(lines.joined(separator: "\n")))
        #expect(chunks.count == 3)
        #expect(chunks.map { String($0.characters) }.joined(separator: "\n") == lines.joined(separator: "\n"))
        #expect(String(chunks[1].characters).hasPrefix("line 61"))
    }

    @Test func highlightingSurvivesTheSplit() {
        var text = AttributedString((1...70).map { "x\($0)" }.joined(separator: "\n"))
        text.foregroundColor = .red
        let chunks = CodeBlockView.chunks(text)
        #expect(chunks.allSatisfy { $0.runs.allSatisfy { $0.foregroundColor == .red } })
    }
}
