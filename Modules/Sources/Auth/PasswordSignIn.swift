import Foundation
public import OpenWebUIKit

/// The result of one sign-in attempt.
public enum SignInOutcome: Sendable, Equatable {
    case signedIn(AuthenticatedSession)
    /// A second factor is required before the Server issues a Session token.
    case mfaRequired(MFAChallenge)
    /// The account exists but an admin hasn't approved it yet. Carries the pending Account's
    /// session when the Server issued one (it can't use the app, but can ask "approved yet?");
    /// `nil` when MFA servers answer `{"next_step": "pending"}` without a token.
    case pendingApproval(AuthenticatedSession?)
}

/// A signed-in Account with its Session token and the user record it came from.
public struct AuthenticatedSession: Sendable, Equatable {
    public let account: Account
    public let user: SessionUser
    public let token: String

    public init(account: Account, user: SessionUser, token: String) {
        self.account = account
        self.user = user
        self.token = token
    }
}

/// Email + password sign-in (`POST /api/v1/auths/signin`). Other strategies (LDAP, API key,
/// web SSO, MFA completion) are separate types with the same outcome.
public struct PasswordSignIn: Sendable {
    private let client: OpenWebUIClient
    private let server: ServerProfile

    public init(server: ServerProfile, transport: any HTTPTransport) {
        self.server = server
        self.client = OpenWebUIClient(server: server.url, transport: transport)
    }

    public func signIn(email: String, password: String) async throws(OpenWebUIError) -> SignInOutcome {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return try outcome(of: await client.send(.signIn(email: trimmedEmail, password: password)))
    }

    /// LDAP sign-in (`POST /api/v1/auths/ldap`) with a directory username, when the Server enables it.
    public func signIn(ldapUsername username: String, password: String) async throws(OpenWebUIError) -> SignInOutcome {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return try outcome(of: await client.send(.ldapSignIn(username: trimmed, password: password)))
    }

    /// Maps a `SignInResult` from any sign-in endpoint to an outcome for this Server.
    func outcome(of result: SignInResult) throws(OpenWebUIError) -> SignInOutcome {
        switch result {
        case .session(let user):
            guard let token = user.token else { throw .decoding("Sign-in session without a token") }
            let account = Account(server: server, userID: user.id, name: user.name, email: user.email)
            let session = AuthenticatedSession(account: account, user: user, token: token)
            // Without MFA, a not-yet-approved user still gets a session, but with role `pending`.
            return user.role == .pending ? .pendingApproval(session) : .signedIn(session)
        case .mfaRequired(let challenge):
            return .mfaRequired(challenge)
        case .pendingApproval:
            return .pendingApproval(nil)
        }
    }
}
