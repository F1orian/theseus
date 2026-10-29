import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// AUTH-03: the verification card for Open WebUI TOTP (verify, enrol, recover).
@MainActor
@Suite("Verification code step")
struct VerificationTests {
    let transport = StubTransport()
    let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")

    final class Recorder {
        var sessions: [AuthenticatedSession] = []
        var flow: OnboardingFlow?
    }

    /// Signs in with a password that answers with the MFA `fixture`, landing on the card.
    func verification(after fixture: String, recorder: Recorder = Recorder()) async throws -> VerificationModel {
        try transport.stub("POST", "api/v1/auths/signin", fixture: fixture)
        let flow = OnboardingFlow(start: .signIn(server: server, email: "user@example.com"), transport: transport) {
            recorder.sessions.append($0)
        }
        recorder.flow = flow
        let signIn = try #require(flow.signInModel)
        signIn.password = "pw"
        await signIn.signIn()
        guard case .verification(let model) = flow.step else { throw FlowError.unexpectedStep }
        return model
    }

    @Test func aTOTPCodeFinishesSignIn() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", fixture: "signin.json")
        let recorder = Recorder()
        let model = try await verification(after: "synthetic/signin.mfa-verify.json", recorder: recorder)
        #expect(model.stage == .verify)
        #expect(model.email == "user@example.com")
        #expect(model.expectsNumericCode)

        model.code = "12345"
        #expect(!model.canSubmit, "TOTP codes have six digits")
        model.code = "123456"
        await model.submit()
        #expect(recorder.sessions.count == 1)
    }

    @Test func aWrongCodeClearsTheFieldAndExplains() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", status: 401, fixture: "synthetic/error.mfa-invalid-code.json")
        let model = try await verification(after: "synthetic/signin.mfa-verify.json")
        model.code = "000000"
        await model.submit()
        #expect(model.errorMessage == "Invalid or already used code.")
        #expect(model.code.isEmpty)
    }

    @Test func recoveryCodesAreFreeTextAndFlagged() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", fixture: "signin.json")
        let recorder = Recorder()
        let model = try await verification(after: "synthetic/signin.mfa-verify.json", recorder: recorder)
        model.toggleRecoveryCode()
        #expect(!model.expectsNumericCode)
        model.code = "3f9a-1c2e"
        await model.submit()
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(transport.requests.last?.httpBody))
        #expect(body["recovery"] == .bool(true))
        #expect(recorder.sessions.count == 1)
    }

    @Test func enrolmentShowsTheKeyThenRecoveryCodesThenSignsIn() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/enroll/start", fixture: "synthetic/mfa.enroll-start.json")
        try transport.stub("POST", "api/v1/auths/mfa/enroll/confirm", fixture: "synthetic/mfa.enroll-confirm.json")
        let recorder = Recorder()
        let model = try await verification(after: "synthetic/signin.mfa-enroll.json", recorder: recorder)
        #expect(model.stage == .enroll(nil))

        await model.load()
        #expect(model.stage == .enroll(MFASetup(manualKey: "JBSWY3DPEHPK3PXP", qrCode: "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=")))
        #expect(model.provisioningURI?.absoluteString.hasPrefix("otpauth://totp/Open%20WebUI:user@example.com?secret=JBSWY3DPEHPK3PXP") == true)

        model.code = "123456"
        await model.submit()
        guard case .recoveryCodes(let codes) = model.stage else {
            Issue.record("Expected recovery codes, got \(model.stage)")
            return
        }
        #expect(codes.count == 10)
        #expect(recorder.sessions.isEmpty, "the user sees the codes before entering the app")

        await model.finish()
        #expect(recorder.sessions.count == 1)
    }

    @Test func aResetTokenLeadsToANewEnrolment() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/recover", fixture: "synthetic/signin.mfa-enroll.json")
        try transport.stub("POST", "api/v1/auths/mfa/enroll/start", fixture: "synthetic/mfa.enroll-start.json")
        let model = try await verification(after: "synthetic/signin.mfa-recover.json")
        #expect(model.stage == .recover)
        #expect(!model.expectsNumericCode)

        model.code = "operator-reset-token"
        await model.submit()
        guard case .enroll(let setup?) = model.stage else {
            Issue.record("Expected an enrolment with its key, got \(model.stage)")
            return
        }
        #expect(setup.manualKey == "JBSWY3DPEHPK3PXP")
    }

    @Test func anExpiredStepGoesBackToSignInWithANotice() async throws {
        try transport.stub("POST", "api/v1/auths/mfa/verify", status: 401, fixture: "synthetic/error.mfa-expired.json")
        let recorder = Recorder()
        let model = try await verification(after: "synthetic/signin.mfa-verify.json", recorder: recorder)
        model.code = "123456"
        await model.submit()
        let signIn = try #require(recorder.flow?.signInModel)
        #expect(signIn.email == "user@example.com")
        #expect(signIn.notice?.contains("timed out") == true)
    }

    @Test func theChallengeExpiresLocallyToo() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let challenge = MFAChallenge(step: .verify, challengeToken: "challenge-verify-0000000000", expiresIn: 300)
        let model = VerificationModel(server: server, email: "e@x", challenge: challenge, transport: transport) { clock }
        var notices: [String?] = []
        model.onBack = { notices.append($0) }
        clock = clock.addingTimeInterval(301)
        model.code = "123456"
        await model.submit()
        #expect(notices.count == 1)
        #expect(transport.requests.isEmpty)
    }

    @Test func backReturnsToTheFormWithTheEmail() async throws {
        let recorder = Recorder()
        let model = try await verification(after: "synthetic/signin.mfa-verify.json", recorder: recorder)
        model.back()
        #expect(recorder.flow?.signInModel?.email == "user@example.com")
    }
}
