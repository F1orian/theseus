public import Foundation

/// The single seam between `OpenWebUIClient` and the network. Production uses `URLSessionTransport`;
/// tests substitute a stub that serves recorded fixtures.
public protocol HTTPTransport: Sendable {
    /// Performs the request. Throws `OpenWebUIError.transport` when no HTTP response arrives;
    /// non-2xx responses are returned, not thrown.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport. One instance per Server profile, so TLS policy, cookies and
/// headers can later be scoped per Server (see docs/research/oss-clients.md, pitfall 4).
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw OpenWebUIError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenWebUIError.transport(.badServerResponse)
        }
        return (data, http)
    }
}

/// Streams a response body line by line (Server-Sent Events). Transports that can't stream
/// may buffer; `OpenWebUIClient` only needs the lines in order.
public protocol HTTPStreamingTransport: HTTPTransport {
    /// Starts the request and returns the response head plus the body's lines (without line
    /// terminators; blank lines are kept because they delimit SSE events).
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
}

extension URLSessionTransport: HTTPStreamingTransport {
    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        var request = request
        // Generations can be silent for minutes (web search, long Thinking).
        request.timeoutInterval = 300
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw OpenWebUIError.transport(error.code)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenWebUIError.transport(.badServerResponse)
        }
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if line.last == UInt8(ascii: "\r") { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: OpenWebUIError.transport(error.code))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}
