public import Foundation

/// One open WebSocket carrying text frames. The seam between `SocketIOClient` and the network:
/// production uses `URLSessionWebSocketConnector`; tests replay recorded frame logs.
public protocol WebSocketConnection: Sendable {
    func send(_ frame: String) async throws
    /// The next text frame. Throws once the connection is closed or fails.
    func receive() async throws -> String
    func close() async
}

/// Opens WebSocket connections.
public protocol WebSocketConnecting: Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection
}

public enum WebSocketError: Error, Sendable, Equatable {
    case closed
    case binaryFrame
}

/// `URLSessionWebSocketTask`-backed connections. Use one connector per Server profile so TLS
/// policy matches the HTTP transport.
public struct URLSessionWebSocketConnector: WebSocketConnecting {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        // Open WebUI sends 16 MiB maxPayload; snapshots of long Responses can be large.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

/// `URLSessionWebSocketTask` is thread-safe; the wrapper only forwards calls.
private final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ frame: String) async throws {
        try await task.send(.string(frame))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data: throw WebSocketError.binaryFrame
        @unknown default: throw WebSocketError.binaryFrame
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
