public import Foundation

/// Every failure `OpenWebUIClient` can surface. Features switch on this instead of on `URLError`
/// or raw status codes.
public enum OpenWebUIError: Error, Sendable, Equatable {
    /// The user-entered Server address could not be turned into an http(s) URL.
    case invalidServerURL(String)
    /// The request never produced an HTTP response (offline, DNS, TLS, timeout, …).
    case transport(URLError.Code)
    /// The response is not from an Open WebUI API (e.g. an HTML proxy interstitial or a 404 page).
    case notOpenWebUI
    /// 401: the Session token is missing, expired or revoked and could not be renewed.
    case unauthorized(detail: String?)
    /// 403: the Account is signed in but not allowed to do this.
    case forbidden(detail: String?)
    /// 429: the server rate-limits this call (e.g. sign-in: 15 attempts per 3 minutes).
    case rateLimited
    /// Any other non-2xx status. `detail` is Open WebUI's `{"detail": …}` message when present.
    case server(status: Int, detail: String?)
    /// A 2xx body did not match the expected shape.
    case decoding(String)
    /// The operation has no transport yet (see `CompletionSession`).
    case unsupported(String)

    /// A short, user-presentable message.
    public var message: String {
        switch self {
        case .invalidServerURL: "That doesn't look like a valid server address."
        case .transport(let code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost: "You appear to be offline."
            case .timedOut: "The server took too long to respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "Couldn't reach the server."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
                "The server's certificate isn't trusted."
            default: "A network error occurred."
            }
        case .notOpenWebUI: "This server doesn't look like Open WebUI."
        case .unauthorized(let detail): detail ?? "Please sign in again."
        case .forbidden(let detail): detail ?? "You don't have permission to do that."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .server(let status, let detail): detail ?? "The server returned an error (\(status))."
        case .decoding: "The server sent an unexpected response."
        case .unsupported(let what): "\(what) isn't supported yet."
        }
    }
}

extension OpenWebUIError {
    /// The request was cancelled (its task ended, e.g. the screen that started it went away).
    /// Nothing failed, so there's nothing to tell the user.
    public var isCancellation: Bool {
        self == .transport(.cancelled)
    }

    /// Maps a non-2xx response to an error, extracting Open WebUI's `detail` field.
    static func from(status: Int, body: Data) -> OpenWebUIError {
        let detail = ErrorBody.detail(in: body)
        switch status {
        case 401: return .unauthorized(detail: detail)
        case 403: return .forbidden(detail: detail)
        case 429: return .rateLimited
        default: return .server(status: status, detail: detail)
        }
    }
}

/// FastAPI error bodies: `{"detail": "msg"}` or, for validation errors, `{"detail": [{"msg": …}]}`.
private enum ErrorBody {
    static func detail(in body: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return nil }
        switch json[path: "detail"] {
        case .string(let message): return message
        case .array(let items):
            let messages = items.compactMap { $0[path: "msg"]?.stringValue }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        default: return nil
        }
    }
}
