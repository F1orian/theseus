public import Foundation

/// Connecting a Connector (CONN-03, ADR 0090): Open WebUI's MCP OAuth 2.1 flow runs on the Server
/// (`/oauth/clients/mcp:<id>/authorize` → the provider → `/oauth/clients/mcp:<id>/callback`) and
/// ends with a redirect to the Server's root, or `/?error=…`. A web view signed in with the Session
/// token (as the `token` cookie) walks it; `ConnectorAuthorization` decides from each navigation
/// whether the flow finished, failed or continues. It holds no WebKit types, so the policy is
/// unit-testable, like `Auth.WebSignIn` for single sign-on (ADR 0014).
public struct ConnectorAuthorization: Sendable, Equatable, Identifiable {
    public enum Event: Sendable, Equatable {
        /// Keep browsing (the provider's sign-in and consent pages).
        case `continue`
        /// The Server stored the Connector's token and sent the browser home.
        case finished
        /// The Server or the provider reported an error.
        case failed(String)
    }

    public let connectorID: String
    public let name: String
    public let server: URL
    public let startURL: URL
    /// Seeds the web view's `token` cookie (the authorize endpoint needs a signed-in user).
    public let sessionToken: String

    public var id: String { connectorID }

    public init(connectorID: String, name: String, server: URL, startURL: URL, sessionToken: String) {
        self.connectorID = connectorID
        self.name = name
        self.server = server
        self.startURL = startURL
        self.sessionToken = sessionToken
    }

    /// The `token` cookie for the Server's host, as the web client's own session would have it.
    public var sessionCookie: HTTPCookie? {
        guard let host = server.host() else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "token",
            .value: sessionToken,
            .domain: host,
            .path: "/",
        ]
        if server.scheme == "https" { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// The first request: the Session token also goes in the header, in case a proxy strips cookies.
    public var startRequest: URLRequest {
        var request = URLRequest(url: startURL)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Decides what a navigation to `url` means.
    public func event(at url: URL?) -> Event {
        guard let url, isOnServer(url) else { return .continue }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .failed(error)
        }
        return relativePath(of: url)?.isEmpty == true ? .finished : .continue
    }

    /// An HTTP error from the Server itself (e.g. the authorize endpoint's 404 or 500 JSON) ends
    /// the flow; provider pages may use any status.
    public func event(forResponseFrom url: URL?, status: Int) -> Event {
        guard let url, isOnServer(url), status >= 400 else { return .continue }
        switch status {
        case 401: return .failed("Your session has expired. Sign in again and retry.")
        case 403: return .failed("This Server doesn't allow connecting tools.")
        case 404: return .failed("The Server doesn't know this connector any more.")
        default: return .failed("The Server couldn't start connecting (error \(status)).")
        }
    }

    private func isOnServer(_ url: URL) -> Bool {
        url.host()?.lowercased() == server.host()?.lowercased() && url.port == server.port
    }

    /// The path below the Server's base path, without slashes ("" for the root, `nil` outside it).
    private func relativePath(of url: URL) -> String? {
        let slashes = CharacterSet(charactersIn: "/")
        let base = server.path().trimmingCharacters(in: slashes)
        let path = url.path().trimmingCharacters(in: slashes)
        guard !base.isEmpty else { return path }
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: slashes)
    }
}
