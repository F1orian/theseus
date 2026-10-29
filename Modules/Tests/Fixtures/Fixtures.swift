public import Foundation
public import OpenWebUIKit
import Synchronization

/// Recorded, scrubbed Open WebUI responses (see `scripts/record-fixtures`). Unit tests replay
/// these instead of talking to a live Server.
public enum Fixture {
    /// The Server version the bundled fixtures were recorded against.
    public static let serverVersion = "0.12.3"

    /// The Server URL the fixtures pretend to come from.
    public static let serverURL = URL(string: "https://owui.example.com") ?? URL(fileURLWithPath: "/")

    /// The raw bytes of fixture `name`, relative to the version directory
    /// (e.g. `"config.json"` or `"synthetic/signin.pending.json"`).
    public static func data(_ name: String) throws -> Data {
        let relativePath = "open-webui-\(serverVersion)/\(name)"
        guard let url = Bundle.module.resourceURL?.appending(path: relativePath),
              FileManager.default.fileExists(atPath: url.path())
        else { throw FixtureError.missing(relativePath) }
        return try Data(contentsOf: url)
    }
}

public enum FixtureError: Error, CustomStringConvertible {
    case missing(String)

    public var description: String {
        switch self {
        case .missing(let path): "Fixture not found: \(path). Run scripts/record-fixtures."
        }
    }
}

/// An in-memory `HTTPTransport`. Routes are matched on method + path (without leading slash);
/// unmatched requests get a FastAPI-style 404. Every request is recorded for assertions.
public final class StubTransport: HTTPTransport {
    public typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private struct State {
        var routes: [String: Handler] = [:]
        var requests: [URLRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Serves `handler`'s response for `method path`.
    public func stub(_ method: String, _ path: String, handler: @escaping Handler) {
        state.withLock { $0.routes["\(method) \(path)"] = handler }
    }

    /// Serves a fixed body for `method path`.
    public func stub(_ method: String, _ path: String, status: Int = 200, body: Data) {
        stub(method, path) { _ in (status, body) }
    }

    /// Serves a recorded fixture for `method path`.
    public func stub(_ method: String, _ path: String, status: Int = 200, fixture name: String) throws {
        stub(method, path, status: status, body: try Fixture.data(name))
    }

    /// All requests sent so far, in order.
    public var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = String((request.url?.path() ?? "").drop(while: { $0 == "/" }))
        let key = "\(request.httpMethod ?? "GET") \(path)"
        let handler = state.withLock { state in
            state.requests.append(request)
            return state.routes[key]
        }
        let (status, body) = handler?(request) ?? (404, Data(#"{"detail":"Not Found"}"#.utf8))
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw OpenWebUIError.transport(.badURL) }
        return (body, response)
    }
}

extension StubTransport: HTTPStreamingTransport {
    /// Serves the stubbed body as lines, as a streaming server would.
    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (body, response) = try await send(request)
        var lines = String(decoding: body, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (response, stream)
    }
}
