public import Foundation

/// A hand-rolled Socket.IO v4 client over Engine.IO v4 WebSocket framing (ADR 0003).
///
/// It authenticates the handshake with the Session token (`40{"token":…}`), then emits
/// `user-join` and only reports `.joined` once the server **acknowledged** it: before that the
/// socket isn't in the `user:{id}` room and streamed events would go nowhere. It answers server
/// pings, watches for silent connections, and reconnects with capped exponential backoff.
///
/// ```swift
/// let socket = SocketIOClient(server: url, connector: URLSessionWebSocketConnector()) { await client.sessionToken() }
/// await socket.start()
/// let sessionID = try await socket.joinedSessionID()
/// for await event in await socket.events() { … }
/// ```
public actor SocketIOClient {
    public enum State: Sendable, Equatable {
        /// Not started, or stopped.
        case idle
        case connecting
        /// Connected and joined: `sessionID` may be sent as `session_id`.
        case joined(sessionID: String)
        /// The connection dropped; retrying after `retryIn`.
        case disconnected(retryIn: Duration)
        /// The Server rejected the Session token. Waits for `reconnectNow()`.
        case unauthorized

        public var sessionID: String? {
            if case .joined(let id) = self { return id }
            return nil
        }
    }

    /// A server-to-client event. `connection` identifies the socket it arrived on, so acks
    /// never go to a newer connection.
    public struct Event: Sendable, Equatable {
        public let name: String
        public let arguments: [JSONValue]
        public let ackID: Int?
        public let connection: Int
    }

    public enum Failure: Error, Sendable, Equatable {
        case notConnected
        case timedOut
        case disconnected
        case unauthorized
    }

    public struct Backoff: Sendable {
        public var initial: Duration
        public var maximum: Duration

        public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
            self.initial = initial
            self.maximum = maximum
        }

        public func delay(attempt: Int) -> Duration {
            guard attempt > 0 else { return .zero }
            let factor = 1 << min(attempt - 1, 16)
            return min(initial * factor, maximum)
        }
    }

    public let url: URL
    public private(set) var state: State = .idle

    private let connector: any WebSocketConnecting
    private let token: @Sendable () async -> String?
    private let backoff: Backoff
    private let joinTimeout: Duration

    private var runTask: Task<Void, Never>?
    private var retrySleep: Task<Void, any Error>?
    private var isStopped = false
    private var connection: (any WebSocketConnection)?
    private var generation = 0
    private var nextAckID = 0
    private var pendingAcks: [Int: CheckedContinuation<[JSONValue], any Error>] = [:]
    private var lastFrame = ContinuousClock.now
    private var tokenRejected = false
    private var eventSubscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var stateSubscribers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var joinWaiters: [UUID: CheckedContinuation<String, any Error>] = [:]

    /// - Parameters:
    ///   - server: The Server base URL; the socket lives at `<server>/ws/socket.io/`.
    ///   - token: Supplies the current Session token for each (re)connect.
    public init(
        server: URL,
        connector: any WebSocketConnecting,
        backoff: Backoff = Backoff(),
        joinTimeout: Duration = .seconds(10),
        token: @escaping @Sendable () async -> String?
    ) {
        url = Self.socketURL(for: server)
        self.connector = connector
        self.backoff = backoff
        self.joinTimeout = joinTimeout
        self.token = token
    }

    /// `https://host/sub` → `wss://host/sub/ws/socket.io/?EIO=4&transport=websocket`.
    public static func socketURL(for server: URL) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/ws/socket.io/"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        return components.url ?? server
    }

    // MARK: Lifecycle

    /// Connects and keeps the connection alive until `stop()`.
    public func start() {
        guard runTask == nil else { return }
        isStopped = false
        runTask = Task { await self.run() }
    }

    public func stop() async {
        isStopped = true
        runTask?.cancel()
        runTask = nil
        retrySleep?.cancel()
        let open = connection
        connection = nil
        if let open {
            try? await open.send(SocketPacket.disconnect(namespace: "/").frame)
            await open.close()
        }
        failPending(Failure.disconnected)
        setState(.idle)
    }

    /// Skips the backoff wait (e.g. when the app returns to the foreground or the network is
    /// back) and retries a rejected token with a fresh one.
    public func reconnectNow() {
        tokenRejected = false
        retrySleep?.cancel()
        if runTask == nil, !isStopped { start() }
    }

    // MARK: Subscriptions

    /// Every event from every connection, until the stream is dropped.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    /// The current state, then every change.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        return stream
    }

    /// Waits until the socket is joined and returns its session id.
    public func joinedSessionID(timeout: Duration = .seconds(10)) async throws -> String {
        if let id = state.sessionID { return id }
        if state == .unauthorized { throw Failure.unauthorized }
        let waiterID = UUID()
        let timer = Task {
            try await Task.sleep(for: timeout)
            self.failJoinWaiter(waiterID)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            joinWaiters[waiterID] = continuation
        }
    }

    // MARK: Emitting

    public func emit(_ name: String, _ payload: JSONValue) async throws {
        guard let connection, state.sessionID != nil else { throw Failure.notConnected }
        try await connection.send(SocketPacket.event(namespace: "/", ackID: nil, name: name, arguments: [payload]).frame)
    }

    /// Emits and waits for the server's acknowledgement.
    public func emitWithAck(_ name: String, _ payload: JSONValue, timeout: Duration = .seconds(10)) async throws -> [JSONValue] {
        guard let connection else { throw Failure.notConnected }
        return try await sendWithAck(name, payload, on: connection, timeout: timeout)
    }

    /// Answers a server call (`sio.call`) received on `connection`. Dropped if that connection
    /// has since closed: the server already gave up on it.
    public func acknowledge(_ ackID: Int, connection: Int, with payload: JSONValue) async {
        guard connection == generation, let open = self.connection else { return }
        try? await open.send(SocketPacket.ack(namespace: "/", ackID: ackID, arguments: [payload]).frame)
    }

    // MARK: Connection loop

    private enum Outcome {
        case dropped(wasJoined: Bool)
        case unauthorized
    }

    private func run() async {
        var attempt = 0
        while !isStopped, !Task.isCancelled {
            setState(.connecting)
            let outcome = await connectOnce()
            if isStopped || Task.isCancelled { break }
            switch outcome {
            case .unauthorized:
                setState(.unauthorized)
                tokenRejected = true
                // Wait (cancellably) for reconnectNow() with a fresh token.
                while tokenRejected, !isStopped {
                    await sleepForRetry(.seconds(3600))
                }
                attempt = 0
                continue
            case .dropped(let wasJoined):
                attempt = wasJoined ? 1 : attempt + 1
            }
            let delay = backoff.delay(attempt: attempt)
            setState(.disconnected(retryIn: delay))
            await sleepForRetry(delay)
        }
        runTask = nil
    }

    private func sleepForRetry(_ delay: Duration) async {
        let sleep = Task { try await Task.sleep(for: delay) }
        retrySleep = sleep
        _ = try? await sleep.value
        retrySleep = nil
    }

    private func connectOnce() async -> Outcome {
        guard let token = await token() else { return .unauthorized }
        let open: any WebSocketConnection
        do {
            open = try await connector.connect(to: url)
        } catch {
            return .dropped(wasJoined: false)
        }
        generation += 1
        let current = generation
        connection = open
        nextAckID = 0
        tokenRejected = false
        var wasJoined = false
        defer {
            if generation == current {
                connection = nil
                failPending(Failure.disconnected)
            }
        }

        do {
            guard case .open(let handshake)? = EnginePacket(frame: try await open.receive()) else {
                await open.close()
                return .dropped(wasJoined: false)
            }
            lastFrame = .now
            let watchdog = startWatchdog(handshake, connection: open, generation: current)
            defer { watchdog.cancel() }
            try await open.send(SocketPacket.connect(namespace: "/", payload: .object(["token": .string(token)])).frame)

            while !isStopped {
                let frame = try await open.receive()
                lastFrame = .now
                guard generation == current else { return .dropped(wasJoined: wasJoined) }
                switch EnginePacket(frame: frame) {
                case .ping(let payload)?:
                    try await open.send(EnginePacket.pong(payload).frame)
                case .close?:
                    return .dropped(wasJoined: wasJoined)
                case .message(let payload)?:
                    switch SocketPacket(payload: payload) {
                    case .connect(_, let ack)?:
                        let sessionID = ack?[path: "sid"]?.stringValue ?? handshake.sid
                        Task { await self.join(token: token, sessionID: sessionID, generation: current) }
                    case .connectError?:
                        await open.close()
                        return .unauthorized
                    case .disconnect?:
                        await open.close()
                        return .dropped(wasJoined: wasJoined)
                    case .event(_, let ackID, let name, let arguments)?:
                        broadcast(Event(name: name, arguments: arguments, ackID: ackID, connection: current))
                    case .ack(_, let ackID, let arguments)?:
                        pendingAcks.removeValue(forKey: ackID)?.resume(returning: arguments)
                    case nil:
                        break
                    }
                default:
                    break
                }
                if state.sessionID != nil { wasJoined = true }
                if tokenRejected {
                    await open.close()
                    return .unauthorized
                }
            }
            return .dropped(wasJoined: wasJoined)
        } catch {
            await open.close()
            return tokenRejected ? .unauthorized : .dropped(wasJoined: wasJoined || state.sessionID != nil)
        }
    }

    /// `user-join` re-authenticates and joins the `user:{id}` room; the ack carries `{id, name}`.
    /// An invalid token gets no user back.
    private func join(token: String, sessionID: String, generation joining: Int) async {
        guard let open = connection, generation == joining else { return }
        do {
            let ack = try await sendWithAck(
                "user-join",
                .object(["auth": .object(["token": .string(token)])]),
                on: open,
                timeout: joinTimeout
            )
            guard generation == joining else { return }
            guard ack.first?[path: "id"]?.stringValue != nil else {
                tokenRejected = true
                await open.close()
                return
            }
            setState(.joined(sessionID: sessionID))
            let waiters = joinWaiters
            joinWaiters = [:]
            for waiter in waiters.values { waiter.resume(returning: sessionID) }
        } catch {
            if generation == joining { await open.close() }
        }
    }

    private func sendWithAck(
        _ name: String,
        _ payload: JSONValue,
        on open: any WebSocketConnection,
        timeout: Duration
    ) async throws -> [JSONValue] {
        let ackID = nextAckID
        nextAckID += 1
        let timer = Task {
            try await Task.sleep(for: timeout)
            self.failAck(ackID, Failure.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingAcks[ackID] = continuation
            Task {
                do {
                    try await open.send(SocketPacket.event(namespace: "/", ackID: ackID, name: name, arguments: [payload]).frame)
                } catch {
                    self.failAck(ackID, Failure.disconnected)
                }
            }
        }
    }

    /// Closes a connection that stopped receiving pings (`pingInterval + pingTimeout`).
    private func startWatchdog(_ handshake: EngineHandshake, connection open: any WebSocketConnection, generation watched: Int) -> Task<Void, Never> {
        let limit = Duration.milliseconds(handshake.pingInterval + handshake.pingTimeout)
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: limit / 2)
                guard !Task.isCancelled, self.generation == watched else { return }
                if ContinuousClock.now - self.lastFrame > limit {
                    await open.close()
                    return
                }
            }
        }
    }

    // MARK: Bookkeeping

    private func broadcast(_ event: Event) {
        for subscriber in eventSubscribers.values { subscriber.yield(event) }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        for subscriber in stateSubscribers.values { subscriber.yield(new) }
        if new == .unauthorized {
            let waiters = joinWaiters
            joinWaiters = [:]
            for waiter in waiters.values { waiter.resume(throwing: Failure.unauthorized) }
        }
    }

    private func failAck(_ id: Int, _ error: Failure) {
        pendingAcks.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failJoinWaiter(_ id: UUID) {
        joinWaiters.removeValue(forKey: id)?.resume(throwing: Failure.timedOut)
    }

    private func failPending(_ error: Failure) {
        let acks = pendingAcks
        pendingAcks = [:]
        for ack in acks.values { ack.resume(throwing: error) }
    }

    private func removeEventSubscriber(_ id: UUID) {
        eventSubscribers[id] = nil
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }
}
