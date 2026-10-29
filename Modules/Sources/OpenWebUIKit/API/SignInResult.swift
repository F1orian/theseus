public import Foundation

/// `POST /api/v1/auths/signin` returns one of three shapes (`SigninResult` in `B/models/auths.py`).
public enum SignInResult: Sendable, Equatable {
    /// Signed in. `user.token` is the Session token.
    case session(SessionUser)
    /// The Server requires a second factor before it issues a Session token.
    case mfaRequired(MFAChallenge)
    /// MFA is enabled and the account still awaits admin approval (`{"next_step": "pending"}`).
    case pendingApproval
}

public struct MFAChallenge: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable {
        /// MFA is mandatory but not set up yet: start enrolment (`/mfa/enroll/start`).
        case enroll
        /// Enter a TOTP or recovery code (`/mfa/verify`).
        case verify
        /// Account recovery is in progress (`/mfa/recover`).
        case recover
    }

    public let step: Step
    /// Short-lived token proving the password step succeeded. Never persist it.
    public let challengeToken: String
    public let expiresIn: TimeInterval

    public init(step: Step, challengeToken: String, expiresIn: TimeInterval) {
        self.step = step
        self.challengeToken = challengeToken
        self.expiresIn = expiresIn
    }
}

extension SignInResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case nextStep = "next_step"
        case challengeToken = "challenge_token"
        case expiresIn = "expires_in"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .nextStep) {
        case nil:
            let user = try SessionUser(from: decoder)
            guard user.token != nil else {
                throw DecodingError.keyNotFound(
                    SessionUser.CodingKeys.token,
                    .init(codingPath: [], debugDescription: "Sign-in session without a token")
                )
            }
            self = .session(user)
        case "pending":
            self = .pendingApproval
        case let step?:
            guard let parsed = MFAChallenge.Step(rawValue: step) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nextStep, in: container, debugDescription: "Unknown next_step '\(step)'"
                )
            }
            self = .mfaRequired(MFAChallenge(
                step: parsed,
                challengeToken: try container.decode(String.self, forKey: .challengeToken),
                expiresIn: try container.decode(Double.self, forKey: .expiresIn)
            ))
        }
    }
}
