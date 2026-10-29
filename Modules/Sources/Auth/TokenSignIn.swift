public import Foundation
public import OpenWebUIKit

/// Turns a Session token obtained elsewhere (a web sign-in cookie, a pending Account's token) into a
/// `SignInOutcome` by asking the Server who it belongs to (`GET /api/v1/auths/`).
public struct TokenSignIn: Sendable {
    private let server: ServerProfile
    private let transport: any HTTPTransport

    public init(server: ServerProfile, transport: any HTTPTransport) {
        self.server = server
        self.transport = transport
    }

    public func signIn(token: String) async throws(OpenWebUIError) -> SignInOutcome {
        let client = OpenWebUIClient(server: server.url, transport: transport, authorizer: FixedTokenAuthorizer(token: token))
        let user = try await client.send(.sessionUser)
        let account = Account(server: server, userID: user.id, name: user.name, email: user.email)
        let session = AuthenticatedSession(account: account, user: user, token: user.token ?? token)
        return user.role == .pending ? .pendingApproval(session) : .signedIn(session)
    }
}

/// Authorizes with one known token and never renews it (a 401 is final).
public struct FixedTokenAuthorizer: RequestAuthorizer {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func currentToken() async -> String? { token }

    public func renewToken(rejected: String) async throws -> String {
        throw OpenWebUIError.unauthorized(detail: nil)
    }
}

/// What Theseus can read from a Session token (a JWT) without asking the Server.
public enum SessionToken {
    /// The token's `exp` claim, or `nil` when it isn't a readable JWT or never expires.
    public static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let exp = claims.exp
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether the token's `exp` has passed (with a little leeway for clock skew). Unreadable
    /// tokens count as valid; the Server has the final word with a 401.
    public static func isExpired(_ token: String, at now: Date = .now, leeway: TimeInterval = 30) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry.addingTimeInterval(leeway) <= now
    }

    private struct Claims: Decodable {
        let exp: Double?
    }
}
