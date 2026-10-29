public import Foundation
public import OpenWebUIKit

/// Completes a sign-in that answered with an `MFAChallenge` (Open WebUI TOTP): verify a code,
/// enrol a new authenticator, or redeem an admin's reset token. Challenge tokens are short-lived
/// and never persisted.
public struct MFASignIn: Sendable {
    private let server: ServerProfile
    private let client: OpenWebUIClient

    public init(server: ServerProfile, transport: any HTTPTransport) {
        self.server = server
        self.client = OpenWebUIClient(server: server.url, transport: transport)
    }

    /// A 6-digit TOTP code, or a recovery code when `recovery` is `true`.
    public func verify(_ challenge: MFAChallenge, code: String, recovery: Bool = false) async throws(OpenWebUIError) -> AuthenticatedSession {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return try session(from: await client.send(.mfaVerify(challengeToken: challenge.challengeToken, code: trimmed, recovery: recovery)))
    }

    /// Asks the Server for a new authenticator secret (an `enroll` challenge).
    public func startEnrollment(_ challenge: MFAChallenge) async throws(OpenWebUIError) -> MFASetup {
        try await client.send(.mfaEnrollStart(challengeToken: challenge.challengeToken))
    }

    /// Confirms the new authenticator with its first code. Returns the session and the recovery
    /// codes the user must save now.
    public func confirmEnrollment(_ challenge: MFAChallenge, code: String) async throws(OpenWebUIError) -> (AuthenticatedSession, recoveryCodes: [String]) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let enrollment = try await client.send(.mfaEnrollConfirm(challengeToken: challenge.challengeToken, code: trimmed))
        return (try session(from: enrollment.user), enrollment.recoveryCodes)
    }

    /// Redeems an admin-issued reset token for a `recover` challenge; returns the `enroll`
    /// challenge that follows.
    public func recover(_ challenge: MFAChallenge, resetToken: String) async throws(OpenWebUIError) -> MFAChallenge {
        let trimmed = resetToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .mfaRequired(let next) = try await client.send(.mfaRecover(challengeToken: challenge.challengeToken, resetToken: trimmed)) else {
            throw .decoding("Recovery didn't return an enrolment step")
        }
        return next
    }

    private func session(from user: SessionUser) throws(OpenWebUIError) -> AuthenticatedSession {
        guard let token = user.token else { throw .decoding("MFA session without a token") }
        let account = Account(server: server, userID: user.id, name: user.name, email: user.email)
        return AuthenticatedSession(account: account, user: user, token: token)
    }
}

extension MFAChallenge {
    /// The `otpauth://` URI authenticator apps import (as a QR code or a link), for an `enroll` setup.
    public static func provisioningURI(secret: String, account: String, issuer: String) -> URL? {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        components.path = "/\(issuer):\(account)"
        components.queryItems = [
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "issuer", value: issuer),
        ]
        return components.url
    }
}
