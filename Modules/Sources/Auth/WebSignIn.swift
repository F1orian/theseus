public import Foundation
public import OpenWebUIKit

/// Single sign-on through the Server's own web flow (ADR 0014): a non-persistent web view loads
/// `/oauth/{provider}/login`; the Server finishes the IdP round-trip, sets a `token` cookie and
/// redirects to `/auth`. `WebSignIn` decides, from each URL and cookie snapshot the web view
/// reports, whether sign-in finished, failed, or should continue. It holds no WebKit types, so the
/// policy is unit-testable.
public struct WebSignIn: Sendable, Equatable {
    /// What the web view should do next.
    public enum Event: Sendable, Equatable {
        /// Keep browsing (IdP pages, consent, the Server's own MFA page).
        case `continue`
        /// The Server issued a Session token; validate it with `TokenSignIn`.
        case token(String)
        /// The Server signed the user in, but the Account awaits approval (`/auth?pending=1`).
        case pendingApproval
        /// The Server reported an error (`/auth?error=…`).
        case failed(String)
    }

    public let server: URL
    /// Where the web view starts.
    public let startURL: URL

    /// Sign in with an OAuth provider from `/api/config` `oauth.providers`.
    public static func oauth(server: URL, provider: String) -> WebSignIn {
        let encoded = provider.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider
        return WebSignIn(server: server, startURL: server.appending(path: "oauth/\(encoded)/login"))
    }

    /// Sign in through the Server's web page, for proxies that authenticate the browser
    /// (trusted-header auth). The page signs in and sets the same `token` cookie.
    public static func webPage(server: URL) -> WebSignIn {
        WebSignIn(server: server, startURL: server.appending(path: "auth"))
    }

    /// Decides what a navigation to `url`, with the web view's current `cookies`, means.
    public func event(at url: URL?, cookies: [HTTPCookie]) -> Event {
        if let token = sessionToken(in: cookies) {
            return .token(token)
        }
        guard let url, isAuthPage(url) else { return .continue }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            return .failed(error)
        }
        if query.contains(where: { $0.name == "pending" }) {
            return .pendingApproval
        }
        // `?mfa=1`: the Server's page asks for the code itself and then sets the cookie.
        return .continue
    }

    /// The Server's non-HttpOnly `token` cookie, scoped to its host.
    func sessionToken(in cookies: [HTTPCookie]) -> String? {
        guard let host = server.host()?.lowercased() else { return nil }
        return cookies.first { cookie in
            guard cookie.name == "token", !cookie.value.isEmpty else { return false }
            let domain = String(cookie.domain.lowercased().trimmingPrefix("."))
            return host == domain || host.hasSuffix("." + domain)
        }?.value
    }

    /// `{server}/auth`, respecting sub-path deployments.
    private func isAuthPage(_ url: URL) -> Bool {
        guard url.host()?.lowercased() == server.host()?.lowercased() else { return false }
        let base = server.path().hasSuffix("/") ? String(server.path().dropLast()) : server.path()
        var path = url.path()
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == base + "/auth"
    }
}

/// Native-token sign-in for Servers whose admin enabled `ENABLE_OAUTH_TOKEN_EXCHANGE` (off by
/// default and not advertised in `/api/config`): trades an access token Theseus obtained from the
/// IdP directly for a Session token. See ADR 0014 for when the UI uses it.
public struct OAuthTokenExchange: Sendable {
    private let server: ServerProfile
    private let transport: any HTTPTransport

    public init(server: ServerProfile, transport: any HTTPTransport) {
        self.server = server
        self.transport = transport
    }

    public func signIn(provider: String, accessToken: String) async throws(OpenWebUIError) -> SignInOutcome {
        let client = OpenWebUIClient(server: server.url, transport: transport)
        let result = try await client.send(.oauthTokenExchange(provider: provider, token: accessToken))
        return try PasswordSignIn(server: server, transport: transport).outcome(of: result)
    }
}
