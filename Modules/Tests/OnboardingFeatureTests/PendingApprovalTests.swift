import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

/// AUTH-06 / AUTH-05: Accounts waiting for admin approval.
@MainActor
@Suite("Pending approval")
struct PendingApprovalTests {
    let transport = StubTransport()
    let server = ServerProfile(url: Fixture.serverURL, name: "Open WebUI")
    let pendingUser = Data(#"{"id":"u1","name":"New Person","email":"new@example.com","role":"pending","token":"pending-jwt"}"#.utf8)

    func pendingSession() throws -> AuthenticatedSession {
        let user = try JSONDecoder().decode(SessionUser.self, from: pendingUser)
        return AuthenticatedSession(
            account: Account(server: server, userID: user.id, name: user.name, email: user.email),
            user: user,
            token: "pending-jwt"
        )
    }

    func pending(_ flow: OnboardingFlow) throws -> PendingApprovalModel {
        guard case .pendingApproval(let model) = flow.step else { throw FlowError.unexpectedStep }
        return model
    }

    @Test func showsTheAdminsOwnMessage() async throws {
        transport.stub("GET", "api/config", body: Data(#"""
        {"name":"Open WebUI","version":"0.12.3","features":{},
         "ui":{"pending_user_overlay_title":"Hang tight","pending_user_overlay_content":"Ping the admin on Signal."}}
        """#.utf8))
        let flow = OnboardingFlow(start: .pendingApproval(try pendingSession()), transport: transport) { _ in }
        let model = try pending(flow)
        #expect(model.title == "Waiting for approval")
        await model.load()
        #expect(model.title == "Hang tight")
        #expect(model.message == "Ping the admin on Signal.")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer pending-jwt")
    }

    @Test func checkingAgainWhileStillPendingSaysSo() async throws {
        transport.stub("GET", "api/v1/auths/", body: pendingUser)
        let flow = OnboardingFlow(start: .pendingApproval(try pendingSession()), transport: transport) { _ in }
        let model = try pending(flow)
        await model.checkAgain()
        #expect(model.statusMessage?.contains("Still waiting") == true)
        _ = try pending(flow)
    }

    @Test func approvalSignsIn() async throws {
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        var signedIn: [AuthenticatedSession] = []
        let flow = OnboardingFlow(start: .pendingApproval(try pendingSession()), transport: transport) { signedIn.append($0) }
        await (try pending(flow)).checkAgain()
        #expect(signedIn.map(\.user.role) == [.admin])
    }

    @Test func aRevokedPendingTokenGoesBackToSignIn() async throws {
        try transport.stub("GET", "api/v1/auths/", status: 401, fixture: "models.unauthenticated.json")
        let flow = OnboardingFlow(start: .pendingApproval(try pendingSession()), transport: transport) { _ in }
        await (try pending(flow)).checkAgain()
        let signIn = try #require(flow.signInModel)
        #expect(signIn.email == "new@example.com")
        #expect(signIn.notice == "Please sign in again.")
    }

    @Test func usingAnotherAccountReturnsToTheForm() throws {
        let flow = OnboardingFlow(start: .pendingApproval(try pendingSession()), transport: transport) { _ in }
        try pending(flow).signInWithAnotherAccount()
        #expect(flow.signInModel != nil)
    }
}
