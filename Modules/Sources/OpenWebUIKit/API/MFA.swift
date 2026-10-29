import Foundation

// TOTP two-factor endpoints (`B/routers/mfa.py`). All are public: the short-lived challenge token
// from sign-in proves the password step. Errors are 401 with a `detail` (invalid code, expired step).

/// `POST /api/v1/auths/mfa/enroll/start` → the new authenticator secret.
public struct MFASetup: Sendable, Equatable, Decodable {
    /// The base32 TOTP secret, for manual entry.
    public let manualKey: String
    /// The Server's QR code as a `data:image/svg+xml;base64,…` URL. Theseus renders its own QR
    /// from `manualKey` instead, so this is informational.
    public let qrCode: String

    public init(manualKey: String, qrCode: String = "") {
        self.manualKey = manualKey
        self.qrCode = qrCode
    }

    enum CodingKeys: String, CodingKey {
        case manualKey = "manual_key"
        case qrCode = "qr_code"
    }
}

/// `POST /api/v1/auths/mfa/enroll/confirm` → a session plus one-time recovery codes.
public struct MFAEnrollment: Sendable, Equatable, Decodable {
    public let user: SessionUser
    /// Shown once; the Server only keeps their hashes.
    public let recoveryCodes: [String]

    enum CodingKeys: String, CodingKey {
        case recoveryCodes = "recovery_codes"
    }

    public init(from decoder: any Decoder) throws {
        user = try SessionUser(from: decoder)
        recoveryCodes = try decoder.container(keyedBy: CodingKeys.self).decode([String].self, forKey: .recoveryCodes)
    }
}

extension Endpoint where Response == SessionUser {
    /// `POST /api/v1/auths/mfa/verify`: a TOTP code, or a recovery code with `recovery: true`.
    public static func mfaVerify(challengeToken: String, code: String, recovery: Bool) -> Self {
        Endpoint(method: .post, path: "api/v1/auths/mfa/verify", body: MFABody.encode(
            MFABody(challengeToken: challengeToken, code: code, recovery: recovery)
        ), authentication: .none)
    }
}

extension Endpoint where Response == MFASetup {
    /// `POST /api/v1/auths/mfa/enroll/start` for an `enroll` challenge.
    public static func mfaEnrollStart(challengeToken: String) -> Self {
        Endpoint(method: .post, path: "api/v1/auths/mfa/enroll/start", body: MFABody.encode(
            MFABody(challengeToken: challengeToken)
        ), authentication: .none)
    }
}

extension Endpoint where Response == MFAEnrollment {
    /// `POST /api/v1/auths/mfa/enroll/confirm` with the first code from the new authenticator.
    public static func mfaEnrollConfirm(challengeToken: String, code: String) -> Self {
        Endpoint(method: .post, path: "api/v1/auths/mfa/enroll/confirm", body: MFABody.encode(
            MFABody(challengeToken: challengeToken, code: code)
        ), authentication: .none)
    }
}

extension Endpoint where Response == SignInResult {
    /// `POST /api/v1/auths/mfa/recover`: redeems the reset token an admin issued for a `recover`
    /// challenge; answers with a fresh `enroll` challenge.
    public static func mfaRecover(challengeToken: String, resetToken: String) -> Self {
        Endpoint(method: .post, path: "api/v1/auths/mfa/recover", body: MFABody.encode(
            MFABody(challengeToken: challengeToken, resetToken: resetToken)
        ), authentication: .none)
    }
}

/// The MFA forms forbid unknown keys (`extra='forbid'`), so only set fields are encoded.
private struct MFABody: Encodable {
    var challengeToken: String
    var code: String?
    var recovery: Bool?
    var resetToken: String?

    enum CodingKeys: String, CodingKey {
        case code, recovery
        case challengeToken = "challenge_token"
        case resetToken = "reset_token"
    }

    static func encode(_ body: MFABody) -> Data {
        // Encoding strings and a bool cannot fail; fall back to an empty body rather than force-trying.
        (try? WireCoding.encoder.encode(body)) ?? Data()
    }
}
