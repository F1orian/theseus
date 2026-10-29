public import Foundation

/// A Server the user added: its normalised base URL plus what it calls itself.
public struct ServerProfile: Sendable, Hashable, Codable, Identifiable {
    public let url: URL
    /// The Server's own name from `/api/config` (e.g. "Open WebUI").
    public var name: String

    public var id: URL { url }

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// A signed-in user on one Server. Each Account's data (credentials, cache database) is
/// isolated under its `id`.
public struct Account: Sendable, Hashable, Codable, Identifiable {
    public let server: ServerProfile
    public let userID: String
    public var name: String
    public var email: String

    public init(server: ServerProfile, userID: String, name: String, email: String) {
        self.server = server
        self.userID = userID
        self.name = name
        self.email = email
    }

    /// Stable key for this (Server, user) pair: `"<server url>|<user id>"`.
    public var id: String { "\(server.url.absoluteString)|\(userID)" }
}

/// What the Keychain stores per Account.
public struct Credential: Sendable, Hashable, Codable {
    /// The Session token (JWT).
    public var sessionToken: String
    /// Only stored when the user opted in, to renew an expired Session token silently
    /// (Open WebUI has no refresh tokens).
    public var password: String?

    public init(sessionToken: String, password: String? = nil) {
        self.sessionToken = sessionToken
        self.password = password
    }
}
