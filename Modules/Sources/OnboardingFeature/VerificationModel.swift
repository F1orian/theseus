public import Auth
public import Foundation
public import Observation
public import OpenWebUIKit

/// AUTH-03: the verification card after a password sign-in that needs a second factor. Open WebUI
/// uses TOTP (no email or SMS codes), so this covers its three steps: verify a code, enrol an
/// authenticator (QR or key, then recovery codes), and redeem an admin reset token.
@MainActor
@Observable
public final class VerificationModel {
    public enum Stage: Equatable {
        /// Enter the authenticator code (or a recovery code).
        case verify
        /// Set up an authenticator: `setup` is `nil` while the secret loads.
        case enroll(MFASetup?)
        /// Enter the reset token an admin issued.
        case recover
        /// Enrolment done: save these codes, then continue.
        case recoveryCodes([String])
    }

    public let server: ServerProfile
    public let email: String
    public private(set) var stage: Stage
    /// The code (TOTP, recovery code or reset token) being typed.
    public var code = "" {
        didSet { autoSubmitIfComplete() }
    }
    /// In `.verify`: use a one-time recovery code instead of the authenticator.
    public private(set) var usesRecoveryCode = false
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private var challenge: MFAChallenge
    @ObservationIgnored private var expiresAt: Date
    @ObservationIgnored private var enrolledSession: AuthenticatedSession?
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored var onSignedIn: (AuthenticatedSession) async -> Void = { _ in }
    @ObservationIgnored var onBack: (_ notice: String?) -> Void = { _ in }

    init(server: ServerProfile, email: String, challenge: MFAChallenge, transport: any HTTPTransport, now: @escaping () -> Date = Date.init) {
        self.server = server
        self.email = email
        self.challenge = challenge
        self.transport = transport
        self.now = now
        expiresAt = now().addingTimeInterval(challenge.expiresIn)
        stage = Self.stage(for: challenge.step)
    }

    private static func stage(for step: MFAChallenge.Step) -> Stage {
        switch step {
        case .verify: .verify
        case .enroll: .enroll(nil)
        case .recover: .recover
        }
    }

    /// TOTP codes are six digits; recovery codes and reset tokens are free text.
    public var expectsNumericCode: Bool {
        switch stage {
        case .verify: !usesRecoveryCode
        case .enroll: true
        case .recover, .recoveryCodes: false
        }
    }

    public var canSubmit: Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking, !trimmed.isEmpty else { return false }
        return expectsNumericCode ? trimmed.count == 6 && trimmed.allSatisfy(\.isNumber) : true
    }

    /// The `otpauth://` link for the authenticator being enrolled.
    public var provisioningURI: URL? {
        guard case .enroll(let setup?) = stage else { return nil }
        return MFAChallenge.provisioningURI(secret: setup.manualKey, account: email, issuer: server.name)
    }

    /// Loads the authenticator secret when enrolling.
    public func load() async {
        guard case .enroll(nil) = stage else { return }
        await run { () async throws(OpenWebUIError) in
            let setup = try await MFASignIn(server: server, transport: transport).startEnrollment(challenge)
            stage = .enroll(setup)
        }
    }

    public func toggleRecoveryCode() {
        guard stage == .verify else { return }
        usesRecoveryCode.toggle()
        errorMessage = nil
        code = ""
    }

    public func submit() async {
        guard canSubmit else { return }
        guard now() < expiresAt else {
            onBack("That verification step timed out. Sign in again to get a new one.")
            return
        }
        let mfa = MFASignIn(server: server, transport: transport)
        let (code, challenge, recovery) = (code, challenge, usesRecoveryCode)
        switch stage {
        case .verify:
            await run { () async throws(OpenWebUIError) in
                let session = try await mfa.verify(challenge, code: code, recovery: recovery)
                await onSignedIn(session)
            }
        case .enroll:
            await run { () async throws(OpenWebUIError) in
                let (session, codes) = try await mfa.confirmEnrollment(challenge, code: code)
                enrolledSession = session
                stage = .recoveryCodes(codes)
            }
        case .recover:
            await run { () async throws(OpenWebUIError) in
                let next = try await mfa.recover(challenge, resetToken: code)
                self.challenge = next
                expiresAt = now().addingTimeInterval(next.expiresIn)
                stage = .enroll(nil)
            }
            if case .enroll(nil) = stage { await load() }
        case .recoveryCodes:
            break
        }
    }

    /// After saving the recovery codes.
    public func finish() async {
        guard case .recoveryCodes = stage, let enrolledSession else { return }
        await onSignedIn(enrolledSession)
    }

    /// "Back to sign in" (the card's "Change email address" counterpart).
    public func back() {
        onBack(nil)
    }

    private func run(_ operation: () async throws(OpenWebUIError) -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            code = ""
        } catch {
            if case .unauthorized(let detail?) = error, detail.localizedCaseInsensitiveContains("expired") {
                onBack("That verification step timed out. Sign in again to get a new one.")
                return
            }
            errorMessage = error.message
            if expectsNumericCode { code = "" }
        }
    }

    private func autoSubmitIfComplete() {
        guard expectsNumericCode, canSubmit, stage == .verify || isEnrolling else { return }
        Task { await submit() }
    }

    private var isEnrolling: Bool {
        if case .enroll(_?) = stage { true } else { false }
    }
}
