public import Foundation
public import OpenWebUIKit

/// A recorded streaming scenario (`stream/<name>.*`, written by `scripts/record-stream-fixtures`):
/// `plain`, `reasoning`, `stop`, `error`, `resume`, `websearch`, `interleaved`, `askuser`, `branches`, `artifacts`,
/// `sandbox`, `skills`, `sse`.
public struct StreamFixture: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// `<name>.ids.json`: the chat id and the client-minted `[user, assistant]` message ids.
    public struct IDs: Sendable, Decodable {
        public let chatID: String?
        private let turn: [String]?
        private let first: [String]?
        private let second: [String]?
        /// Multi-turn scenarios (`artifacts`, `sandbox`, `skills`): `[user, assistant]` per turn.
        private let turns: [[String]]?
        /// The terminal server the `sandbox` scenario used.
        public let terminalID: String?

        /// The (first) turn's user Message id.
        public var userMessageID: String { (turn ?? first ?? turns?.first ?? ["", ""])[0] }
        /// The (first) turn's assistant Message id.
        public var assistantMessageID: String { (turn ?? first ?? turns?.first ?? ["", ""])[1] }
        /// Every turn as `(user, assistant)`, in order.
        public var allTurns: [(user: String, assistant: String)] {
            (turns ?? [turn ?? first].compactMap { $0 } + [second].compactMap { $0 }).map { ($0[0], $0[1]) }
        }
        /// The follow-up turn (`plain` only).
        public var followUp: (user: String, assistant: String)? {
            second.map { ($0[0], $0[1]) }
        }
    }

    public func ids() throws -> IDs {
        try JSONDecoder().decode(IDs.self, from: Fixture.data("stream/\(name).ids.json"))
    }

    /// Raw bytes of `<name>.<suffix>` (e.g. `"chat.final.json"`).
    public func data(_ suffix: String) throws -> Data {
        try Fixture.data("stream/\(name).\(suffix)")
    }

    /// Every server → client `events` envelope in arrival order, across all connections, with
    /// its ack id when the server expects an answer. `connection` is 0 for the first socket.
    public func envelopes(connection wanted: Int? = nil) throws -> [(envelope: JSONValue, ackID: Int?)] {
        let log = String(decoding: try Fixture.data("stream/\(name).frames.jsonl"), as: UTF8.self)
        var result: [(JSONValue, Int?)] = []
        var connection = -1
        for raw in log.split(separator: "\n") {
            guard let line = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else { continue }
            if line[path: "dir"]?.stringValue == "note", line[path: "note"]?.stringValue?.contains(": open ") == true {
                connection += 1
            }
            guard wanted == nil || wanted == connection,
                  line[path: "dir"]?.stringValue == "in",
                  let frame = line[path: "frame"]?.stringValue,
                  case .message(let payload)? = EnginePacket(frame: frame),
                  case .event(_, let ackID, "events", let arguments)? = SocketPacket(payload: payload),
                  let envelope = arguments.first
            else { continue }
            result.append((envelope, ackID))
        }
        return result
    }
}
