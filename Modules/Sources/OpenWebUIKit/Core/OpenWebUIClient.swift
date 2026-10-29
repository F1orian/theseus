import ChatDomain
public import Foundation

/// Supplies the Session token for authenticated requests and renews it after a 401.
/// `Auth.SessionAuthenticator` is the production implementation (single-flight renewal).
public protocol RequestAuthorizer: Sendable {
    /// The token to attach, or `nil` when signed out.
    func currentToken() async -> String?
    /// Called when a request sent with `rejected` came back 401. Returns a token to retry with,
    /// or throws (typically `OpenWebUIError.unauthorized`) when the session cannot be renewed.
    func renewToken(rejected: String) async throws -> String
}

/// A typed HTTP client for one Server.
///
/// ```swift
/// let client = OpenWebUIClient(server: url, transport: URLSessionTransport(), authorizer: authenticator)
/// let models = try await client.send(.models)
/// ```
public struct OpenWebUIClient: Sendable {
    public let server: URL
    private let transport: any HTTPTransport
    private let authorizer: (any RequestAuthorizer)?

    public init(server: URL, transport: any HTTPTransport, authorizer: (any RequestAuthorizer)? = nil) {
        self.server = server
        self.transport = transport
        self.authorizer = authorizer
        ServerDisplay.register(server) // so links to this Server show the alias when one is set
    }

    /// Returns a client for the same Server and transport that authenticates through `authorizer`.
    public func authorized(by authorizer: any RequestAuthorizer) -> OpenWebUIClient {
        OpenWebUIClient(server: server, transport: transport, authorizer: authorizer)
    }

    /// The current Session token, for transports that authenticate outside HTTP headers
    /// (the Socket.IO handshake).
    public func sessionToken() async -> String? {
        await authorizer?.currentToken()
    }

    /// Opens a streaming request (SSE). One 401 renewal + retry, like `send(_:)`.
    func streamLines(
        _ endpoint: Endpoint<JSONValue>
    ) async throws(OpenWebUIError) -> AsyncThrowingStream<String, any Error> {
        guard let streaming = transport as? any HTTPStreamingTransport else {
            throw .unsupported("Streaming responses")
        }
        func open(_ token: String?) async throws(OpenWebUIError) -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
            do {
                return try await streaming.lines(for: endpoint.urlRequest(server: server, token: token))
            } catch let error as OpenWebUIError {
                throw error
            } catch let error as URLError {
                throw .transport(error.code)
            } catch {
                throw .transport(.unknown)
            }
        }
        let token = await authorizer?.currentToken()
        var (response, lines) = try await open(token)
        if response.statusCode == 401, let token, let authorizer {
            let renewed: String
            do {
                renewed = try await authorizer.renewToken(rejected: token)
            } catch let error as OpenWebUIError {
                throw error
            } catch {
                throw .unauthorized(detail: nil)
            }
            (response, lines) = try await open(renewed)
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            do {
                for try await line in lines { body.append(Data((line + "\n").utf8)) }
            } catch {}
            throw OpenWebUIError.from(status: response.statusCode, body: body)
        }
        return lines
    }

    /// Sends `endpoint` and decodes its response. On a 401 for an authenticated endpoint the
    /// authorizer renews the token once and the request is retried once.
    public func send<Response>(_ endpoint: Endpoint<Response>) async throws(OpenWebUIError) -> Response {
        let token = endpoint.authentication == .none ? nil : await authorizer?.currentToken()
        if endpoint.authentication == .required, token == nil {
            throw .unauthorized(detail: nil)
        }

        var (data, response) = try await perform(endpoint.urlRequest(server: server, token: token))

        if response.statusCode == 401, endpoint.authentication != .none, let token, let authorizer {
            let renewed: String
            do {
                renewed = try await authorizer.renewToken(rejected: token)
            } catch let error as OpenWebUIError {
                throw error
            } catch {
                throw .unauthorized(detail: nil)
            }
            (data, response) = try await perform(endpoint.urlRequest(server: server, token: renewed))
        }

        guard (200..<300).contains(response.statusCode) else {
            throw OpenWebUIError.from(status: response.statusCode, body: data)
        }
        guard !endpoint.returnsJSON || (try? WireCoding.decoder.decode(JSONValue.self, from: data)) != nil else {
            // A 2xx that isn't JSON is a proxy/login interstitial or a non-Open WebUI host.
            throw .notOpenWebUI
        }
        do {
            return try endpoint.decode(data)
        } catch let error as DecodingError {
            throw .decoding(Self.describe(error))
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest) async throws(OpenWebUIError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as OpenWebUIError {
            throw error
        } catch let error as URLError {
            throw .transport(error.code)
        } catch {
            throw .transport(.unknown)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing key '\(key.stringValue)' at '\(path(context))'"
        case .typeMismatch(_, let context): return "type mismatch at '\(path(context))'"
        case .valueNotFound(_, let context): return "null value at '\(path(context))'"
        case .dataCorrupted(let context): return "corrupted data at '\(path(context))'"
        @unknown default: return String(describing: error)
        }
    }
}
