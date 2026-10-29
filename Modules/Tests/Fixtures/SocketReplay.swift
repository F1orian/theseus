public import Foundation
public import OpenWebUIKit
import Synchronization

/// Replays a recorded Socket.IO frame log (`stream/<scenario>.frames.jsonl`, written by
/// `scripts/record-stream-fixtures`) as a fake WebSocket server.
///
/// Each `socket…: open` note starts a new connection; when a connection's frames run out and a
/// later one exists, it drops (the client should reconnect). Recorded client frames become
/// sync points: the replay waits until the client has sent that many frames. Notes for the
/// HTTP calls the test makes (completion, stop, resolve) become **gates** that the test opens
/// from its `StubTransport` handlers, so events arrive after the request, as on the wire.
public final class SocketReplay: WebSocketConnecting, Sendable {
    public enum Gate: String, Sendable, CaseIterable {
        case completion = "POST /api/chat/completions"
        case stop = "POST stop"
        case resolve = "POST resolve"
    }

    enum Step: Sendable, Equatable {
        case receive(String)
        case awaitSend
        case gate(Gate)
    }

    struct Line: Decodable {
        let dir: String
        let frame: String?
        let note: String?
    }

    private struct State {
        var openedGates: Set<Gate> = []
        var gateWaiters: [(Gate, CheckedContinuation<Void, Never>)] = []
        var connections = 0
        var sent: [[String]] = []
    }

    private let segments: [[Step]]
    private let state = Mutex(State())

    /// Loads `stream/<scenario>.frames.jsonl`.
    public convenience init(scenario: String) throws {
        let data = try Fixture.data("stream/\(scenario).frames.jsonl")
        try self.init(log: String(decoding: data, as: UTF8.self))
    }

    public init(log: String) throws {
        var segments: [[Step]] = []
        var current: [Step]?
        for raw in log.split(separator: "\n") where !raw.isEmpty {
            let line = try JSONDecoder().decode(Line.self, from: Data(raw.utf8))
            switch line.dir {
            case "note":
                let note = line.note ?? ""
                if note.contains(": open ") {
                    if let current { segments.append(current) }
                    current = []
                } else if let gate = Gate.allCases.first(where: { note.hasPrefix($0.rawValue) }) {
                    current?.append(.gate(gate))
                }
            case "in":
                if let frame = line.frame { current?.append(.receive(frame)) }
            case "out":
                current?.append(.awaitSend)
            default:
                break
            }
        }
        if let current { segments.append(current) }
        // Trailing client frames (the final disconnect) have nothing to wait for.
        self.segments = segments.map { steps in
            var steps = steps
            while steps.last == .awaitSend { steps.removeLast() }
            return steps
        }
    }

    /// Lets frames recorded after `gate` flow.
    public func open(_ gate: Gate) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.openedGates.insert(gate)
            let ready = state.gateWaiters.filter { $0.0 == gate }.map(\.1)
            state.gateWaiters.removeAll { $0.0 == gate }
            return ready
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Frames the client sent, per connection.
    public var sentFrames: [[String]] {
        state.withLock { $0.sent }
    }

    public var connectionCount: Int {
        state.withLock { $0.connections }
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let index = state.withLock { state -> Int in
            state.connections += 1
            state.sent.append([])
            return state.connections - 1
        }
        guard index < segments.count else { throw WebSocketError.closed }
        return ReplayConnection(replay: self, index: index, steps: segments[index], isLast: index == segments.count - 1)
    }

    func waitForGate(_ gate: Gate) async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state -> Bool in
                if state.openedGates.contains(gate) { return true }
                state.gateWaiters.append((gate, continuation))
                return false
            }
            if isOpen { continuation.resume() }
        }
    }

    func record(_ frame: String, connection index: Int) {
        state.withLock { $0.sent[index].append(frame) }
    }
}

private actor ReplayConnection: WebSocketConnection {
    private let replay: SocketReplay
    private let index: Int
    private var steps: ArraySlice<Step>
    private let isLast: Bool
    private var sentCount = 0
    private var expectedSends = 0
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var isClosed = false

    typealias Step = SocketReplay.Step

    init(replay: SocketReplay, index: Int, steps: [Step], isLast: Bool) {
        self.replay = replay
        self.index = index
        self.steps = steps[...]
        self.isLast = isLast
    }

    func send(_ frame: String) async throws {
        guard !isClosed else { throw WebSocketError.closed }
        replay.record(frame, connection: index)
        sentCount += 1
        if sentCount >= expectedSends, let waiter = sendWaiter {
            sendWaiter = nil
            waiter.resume()
        }
    }

    func receive() async throws -> String {
        while let step = steps.first {
            guard !isClosed else { throw WebSocketError.closed }
            steps.removeFirst()
            switch step {
            case .receive(let frame):
                return frame
            case .awaitSend:
                expectedSends += 1
                if sentCount < expectedSends {
                    await withCheckedContinuation { sendWaiter = $0 }
                }
            case .gate(let gate):
                await replay.waitForGate(gate)
            }
        }
        if !isLast {
            isClosed = true
            throw WebSocketError.closed
        }
        // The last connection stays open until the client closes it.
        if !isClosed {
            await withCheckedContinuation { closeWaiter = $0 }
        }
        throw WebSocketError.closed
    }

    func close() async {
        isClosed = true
        closeWaiter?.resume()
        closeWaiter = nil
        sendWaiter?.resume()
        sendWaiter = nil
    }
}
