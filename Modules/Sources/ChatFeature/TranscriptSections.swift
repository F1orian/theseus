import ChatDomain

/// The transcript in two sections (#197, ADR 0160): **history**, older Messages built lazily as they
/// scroll into view, and the **tail**, the latest Messages, always built. Opening at the bottom,
/// following a stream, a sent Message rising and the footer arriving all happen in the tail, so
/// they work on fully laid-out content; only scrolling back reaches lazy rows.
///
/// The boundary is sticky: new Messages join the tail, and a Message never moves between sections
/// while the Chat is open, unless the path no longer holds the tail's first Message (a Branch
/// switched above it, a reload).
struct TranscriptSections: Equatable {
    /// The tail holds at least this many Messages…
    static let tailCount = 6
    /// …and at least this much stored text (UTF-8 bytes, markup included): well over a screen, even
    /// a wide one, so the visible end of a Chat is always in the tail.
    static let tailBytes = 12_000

    private(set) var history: [Message] = []
    private(set) var tail: [Message] = []

    /// History in chunks of about `chunkBytes` of text each, one lazy row per chunk (#197). A
    /// lazy stack estimates unbuilt rows from the average height of built ones; Messages alone
    /// range from a line to dozens of screens, so their average predicts nothing and the stack
    /// jumps as it corrects. Chunks of similar size keep the estimate close.
    var historyChunks: [Chunk] {
        var chunks: [Chunk] = []
        var current: [Message] = []
        var bytes = 0
        for message in history {
            current.append(message)
            bytes += message.content.utf8.count
            if bytes >= Self.chunkBytes {
                chunks.append(Chunk(messages: current))
                current = []
                bytes = 0
            }
        }
        if !current.isEmpty { chunks.append(Chunk(messages: current)) }
        return chunks
    }

    static let chunkBytes = 6000

    struct Chunk: Identifiable, Equatable {
        let messages: [Message]
        /// The first Message's id: stable while the chunk keeps its first Message.
        var id: String { messages.first?.id ?? "" }
    }

    /// - Parameter tailStart: The tail's first Message from before, kept while it's on the path.
    init(thread: [Message], tailStart: String?) {
        // One row per Message: system Messages draw nothing, so they're left out here rather than
        // as an empty row (lazy stacks need each row to be exactly one view).
        let messages = thread.filter { $0.role != .system }
        let start = tailStart.flatMap { id in messages.firstIndex { $0.id == id } } ?? Self.tailStart(in: messages)
        history = Array(messages[..<start])
        tail = Array(messages[start...])
    }

    /// The tail's first Message, to keep the boundary on the next change.
    var tailStartID: String? { tail.first?.id }

    /// Where the tail begins for a Chat opened now: back from the end until it holds `tailCount`
    /// Messages and `tailBytes` of text.
    static func tailStart(in messages: [Message]) -> Int {
        var start = messages.count
        var bytes = 0
        while start > 0, messages.count - start < tailCount || bytes < tailBytes {
            start -= 1
            bytes += messages[start].content.utf8.count
        }
        return start
    }
}
