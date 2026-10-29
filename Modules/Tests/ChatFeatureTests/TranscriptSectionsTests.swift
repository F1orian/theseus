@testable import ChatFeature
import ChatDomain
import Foundation
import Testing

/// The transcript's lazy history and always-built tail (#197).
@Suite("Transcript sections")
struct TranscriptSectionsTests {
    private func thread(_ sizes: [Int], system: Set<Int> = []) -> [Message] {
        sizes.enumerated().map { index, size in
            Message(
                id: "m\(index)",
                parentID: index == 0 ? nil : "m\(index - 1)",
                role: system.contains(index) ? .system : (index.isMultiple(of: 2) ? .user : .assistant),
                content: String(repeating: "a", count: size),
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    @Test func aShortChatIsAllTail() {
        let sections = TranscriptSections(thread: thread([40, 900, 30, 1200]), tailStart: nil)
        #expect(sections.history.isEmpty)
        #expect(sections.tail.map(\.id) == ["m0", "m1", "m2", "m3"])
    }

    @Test func theTailHoldsEnoughMessagesAndText() {
        // Six small Messages aren't a screen's worth: the tail reaches back for the text.
        let sizes = Array(repeating: 3000, count: 20) + Array(repeating: 100, count: 6)
        let sections = TranscriptSections(thread: thread(sizes), tailStart: nil)
        let tailBytes = sections.tail.reduce(0) { $0 + $1.content.utf8.count }
        #expect(sections.tail.count >= TranscriptSections.tailCount)
        #expect(tailBytes >= TranscriptSections.tailBytes)
        // …and no further than it must.
        #expect(tailBytes - sections.tail[0].content.utf8.count < TranscriptSections.tailBytes)
        #expect(sections.history.count + sections.tail.count == sizes.count)
    }

    @Test func theBoundaryStaysWhileItsMessageIsOnThePath() {
        var messages = thread(Array(repeating: 4000, count: 30))
        let first = TranscriptSections(thread: messages, tailStart: nil)
        // A send: new Messages join the tail; nothing moves into history.
        messages += thread(Array(repeating: 4000, count: 34)).suffix(4)
        let after = TranscriptSections(thread: messages, tailStart: first.tailStartID)
        #expect(after.history == first.history)
        #expect(after.tail.count == first.tail.count + 4)
        // A Branch switched above it: the boundary is chosen again.
        let switched = TranscriptSections(thread: Array(messages.prefix(10)), tailStart: first.tailStartID)
        #expect(switched.tailStartID == TranscriptSections(thread: Array(messages.prefix(10)), tailStart: nil).tailStartID)
    }

    @Test func systemMessagesAreLeftOut() {
        let sections = TranscriptSections(thread: thread([10, 10, 10, 10], system: [1]), tailStart: nil)
        #expect(!(sections.history + sections.tail).contains { $0.role == .system })
        #expect((sections.history + sections.tail).count == 3)
    }

    @Test func historyComesInChunksOfSimilarSize() {
        let sizes = [40, 17_000, 30, 600, 50, 2500, 20, 1400, 70, 9000] + Array(repeating: 800, count: 40)
        let sections = TranscriptSections(thread: thread(sizes), tailStart: nil)
        let chunks = sections.historyChunks
        #expect(chunks.flatMap(\.messages) == sections.history)
        for chunk in chunks.dropLast() {
            #expect(chunk.messages.reduce(0) { $0 + $1.content.utf8.count } >= TranscriptSections.chunkBytes)
            // Each chunk ends as soon as it has enough.
            #expect(chunk.messages.dropLast().reduce(0) { $0 + $1.content.utf8.count } < TranscriptSections.chunkBytes)
        }
        #expect(Set(chunks.map(\.id)).count == chunks.count)
    }
}
