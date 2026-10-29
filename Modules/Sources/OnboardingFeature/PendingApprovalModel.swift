import ChatDomain
public import Auth
import Foundation
public import Observation
import OpenWebUIKit

/// "Waiting for approval" (AUTH-06, AUTH-05): the Account exists but the Server's admin hasn't
/// activated it. Shows the admin's own message when the Server has one, and checks again on demand.
@MainActor
@Observable
public final class PendingApprovalModel {
    public let server: ServerProfile
    /// The pending Account's email, when known.
    public let email: String?
    public private(set) var title = "Waiting for approval"
    public private(set) var message: String
    public private(set) var isChecking = false
    /// Feedback after "Check again" when nothing changed yet.
    public private(set) var statusMessage: String?

    @ObservationIgnored private let session: AuthenticatedSession?
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored var onApproved: (AuthenticatedSession) async -> Void = { _ in }
    @ObservationIgnored var onSignInAgain: (_ notice: String?) -> Void = { _ in }

    init(server: ServerProfile, session: AuthenticatedSession?, transport: any HTTPTransport) {
        self.server = server
        self.session = session
        self.email = session?.account.email
        self.transport = transport
        message = "An admin of \(ServerDisplay.host(server.url, fallback: server.name)) needs to activate your account. "
            + "You can use Theseus as soon as they do."
    }

    /// Whether "Check again" can ask the Server directly (a pending session exists).
    public var canCheckAgain: Bool { session != nil }

    /// Loads the admin's pending message (`ui.pending_user_overlay_*`) with the pending token.
    public func load() async {
        guard let session else { return }
        let client = OpenWebUIClient(server: server.url, transport: transport, authorizer: FixedTokenAuthorizer(token: session.token))
        guard let config = try? await client.send(.config) else { return }
        if let title = config.pendingApprovalTitle { self.title = title }
        if let message = config.pendingApprovalMessage { self.message = message }
    }

    public func checkAgain() async {
        guard let session, !isChecking else {
            onSignInAgain(nil)
            return
        }
        isChecking = true
        statusMessage = nil
        defer { isChecking = false }
        do {
            switch try await TokenSignIn(server: server, transport: transport).signIn(token: session.token) {
            case .signedIn(let approved):
                await onApproved(approved)
            case .pendingApproval, .mfaRequired:
                statusMessage = "Still waiting. Try again once your admin lets you know."
            }
        } catch .unauthorized {
            onSignInAgain("Please sign in again.")
        } catch {
            statusMessage = error.message
        }
    }

    /// Back to the sign-in screen, e.g. to use another Account.
    public func signInWithAnotherAccount() {
        if let session {
            Task { [transport, server] in
                // Best effort: don't leave the pending session valid on the Server.
                let client = OpenWebUIClient(server: server.url, transport: transport, authorizer: FixedTokenAuthorizer(token: session.token))
                _ = try? await client.send(.signOut)
            }
        }
        onSignInAgain(nil)
    }
}
