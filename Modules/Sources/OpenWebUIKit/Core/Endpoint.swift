public import Foundation

/// A typed description of one Open WebUI API call. Construct endpoints through the static
/// factories in `Endpoints.swift` (e.g. `.config`, `.signIn(email:password:)`); send them with
/// `OpenWebUIClient.send(_:)`.
public struct Endpoint<Response: Sendable>: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    /// How the request is authenticated.
    public enum Authentication: Sendable {
        /// Never send a token (e.g. sign-in).
        case none
        /// Send the token if there is one; the response may be richer when authenticated (e.g. `/api/config`).
        case optional
        /// A token is required; a 401 triggers one single-flight renewal and a retry.
        case required
    }

    public let method: Method
    /// Path relative to the Server base URL, without a leading slash (e.g. `"api/v1/chats/"`).
    public let path: String
    public let query: [URLQueryItem]
    public let body: Data?
    /// The `Content-Type` of `body` (JSON unless an endpoint uploads, e.g. multipart files).
    public let contentType: String
    public let authentication: Authentication
    /// `false` for endpoints that return raw bytes (file content) instead of JSON.
    public let returnsJSON: Bool
    let decode: @Sendable (Data) throws -> Response

    init(
        method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        returnsJSON: Bool = true,
        authentication: Authentication,
        decode: @escaping @Sendable (Data) throws -> Response
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.returnsJSON = returnsJSON
        self.authentication = authentication
        self.decode = decode
    }

    /// Builds the `URLRequest` for a Server base URL and an optional bearer token.
    func urlRequest(server: URL, token: String?) -> URLRequest {
        var url = server.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(returnsJSON ? "application/json" : "*/*", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token, authentication != .none {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

extension Endpoint where Response: Decodable {
    init(
        method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        authentication: Authentication
    ) {
        self.init(method: method, path: path, query: query, body: body, contentType: contentType, authentication: authentication) { data in
            try WireCoding.decoder.decode(Response.self, from: data)
        }
    }
}

/// Shared JSON coding configuration for the wire format (snake_case keys are mapped explicitly
/// with `CodingKeys` so field names stay greppable against the server source).
enum WireCoding {
    static let decoder = JSONDecoder()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
