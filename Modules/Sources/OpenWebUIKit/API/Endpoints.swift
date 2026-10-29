public import ChatDomain
import Foundation

// The typed endpoint catalogue. Paths and auth levels follow docs/research/open-webui-api.md.

extension Endpoint where Response == ServerConfig {
    /// `GET /api/config` (public; richer with a token).
    public static var config: Self {
        Endpoint(method: .get, path: "api/config", authentication: .optional)
    }
}

extension Endpoint where Response == ServerVersion {
    /// `GET /api/version` (public).
    public static var version: Self {
        Endpoint(method: .get, path: "api/version", authentication: .none)
    }
}

extension Endpoint where Response == SignInResult {
    /// `POST /api/v1/auths/signin` with email + password. Rate-limited to 15 attempts / 3 min.
    public static func signIn(email: String, password: String) -> Self {
        // Encoding two strings cannot fail; fall back to an empty body rather than force-trying.
        let body = try? WireCoding.encoder.encode(["email": email, "password": password])
        return Endpoint(method: .post, path: "api/v1/auths/signin", body: body ?? Data(), authentication: .none)
    }

    /// `POST /api/v1/auths/oauth/{provider}/token/exchange`: trades an IdP access token for a
    /// Session token. Off unless the admin set `ENABLE_OAUTH_TOKEN_EXCHANGE` (403 otherwise).
    public static func oauthTokenExchange(provider: String, token: String) -> Self {
        let body = try? WireCoding.encoder.encode(["token": token])
        let encoded = provider.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider
        return Endpoint(
            method: .post,
            path: "api/v1/auths/oauth/\(encoded)/token/exchange",
            body: body ?? Data(),
            authentication: .none
        )
    }

    /// `POST /api/v1/auths/ldap` with a directory username + password (when `features.enable_ldap`).
    public static func ldapSignIn(username: String, password: String) -> Self {
        let body = try? WireCoding.encoder.encode(["user": username, "password": password])
        return Endpoint(method: .post, path: "api/v1/auths/ldap", body: body ?? Data(), authentication: .none)
    }
}

extension Endpoint where Response == JSONValue {
    /// `POST /api/v1/auths/signout`: revokes the current Session token server-side.
    public static var signOut: Self {
        Endpoint(method: .post, path: "api/v1/auths/signout", authentication: .optional)
    }
}

extension Endpoint where Response == SessionUser {
    /// `GET /api/v1/auths/`: the signed-in user. Needs a Session token (API keys get 403).
    public static var sessionUser: Self {
        Endpoint(method: .get, path: "api/v1/auths/", authentication: .required)
    }
}

extension Endpoint where Response == [Model] {
    /// `GET /api/models`: the models this Account can use, in the admin's order.
    public static var models: Self {
        Endpoint(method: .get, path: "api/models", authentication: .required) { data in
            try ModelList.decode(data)
        }
    }
}

extension Endpoint where Response == [ChatSummary] {
    /// `GET /api/v1/chats/?page=`: 60 Chats per page, newest first. Excludes starred (pinned) Chats
    /// and Chats in a Project (folder).
    public static func chats(page: Int) -> Self {
        Endpoint(
            method: .get,
            path: "api/v1/chats/",
            query: [URLQueryItem(name: "page", value: String(max(page, 1)))],
            authentication: .required
        ) { data in
            try WireCoding.decoder.decode([ChatSummaryWire].self, from: data).map(\.domain)
        }
    }

    /// The server's page size for `chats(page:)`; a shorter page means it was the last one.
    public static var chatsPageSize: Int { 60 }
}

/// `ChatTitleIdResponse` (`B/models/chats.py`). Timestamps are epoch seconds.
struct ChatSummaryWire: Decodable {
    let id: String
    let title: String
    let updatedAt: Double
    let createdAt: Double
    let lastReadAt: Double?
    let snippet: String?
    let archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, snippet, archived
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case lastReadAt = "last_read_at"
    }

    var domain: ChatSummary {
        ChatSummary(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            lastReadAt: lastReadAt.map(Date.init(timeIntervalSince1970:)),
            snippet: snippet,
            isArchived: archived ?? false
        )
    }
}
