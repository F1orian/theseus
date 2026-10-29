public import Auth
public import Foundation
public import Observation
import OpenWebUIKit

/// AUTH-04: one single sign-on attempt in the web sheet (ADR 0014). The sheet's web view reports
/// every navigation and cookie change here; `WebSignIn` decides what it means and this model turns
/// a captured `token` cookie into a validated session.
@MainActor
@Observable
public final class WebSignInModel: Identifiable {
    public enum Outcome: Sendable {
        case signedIn(AuthenticatedSession)
        /// Signed in, but awaiting approval; the session is `nil` when only `/auth?pending=1` was seen.
        case pendingApproval(AuthenticatedSession?)
        case failed(String)
        case cancelled
    }

    public enum State: Equatable {
        case browsing
        /// A token arrived and is being validated.
        case finishing
        case finished
    }

    public let id = UUID()
    /// The provider's display name ("Company SSO"), or the Server's name for its web page.
    public let title: String
    public let server: ServerProfile
    public let webSignIn: WebSignIn
    public private(set) var state: State = .browsing
    /// Host of the page currently shown, so the user can see who asks for their password.
    public private(set) var pageHost: String?
    /// Whether that page arrived over https.
    public private(set) var pageIsEncrypted: Bool

    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored var onOutcome: @MainActor (Outcome) async -> Void = { _ in }

    init(title: String, server: ServerProfile, webSignIn: WebSignIn, transport: any HTTPTransport) {
        self.title = title
        self.server = server
        self.webSignIn = webSignIn
        self.transport = transport
        pageHost = webSignIn.startURL.host()
        pageIsEncrypted = webSignIn.startURL.scheme == "https"
    }

    /// Called by the web view after each navigation step and cookie change.
    public func observe(url: URL?, cookies: [HTTPCookie]) async {
        guard state == .browsing else { return }
        if let url, let host = url.host() {
            pageHost = host
            pageIsEncrypted = url.scheme == "https"
        }
        switch webSignIn.event(at: url, cookies: cookies) {
        case .continue:
            return
        case .token(let token):
            state = .finishing
            do {
                switch try await TokenSignIn(server: server, transport: transport).signIn(token: token) {
                case .signedIn(let session): await finish(.signedIn(session))
                case .pendingApproval(let session): await finish(.pendingApproval(session))
                case .mfaRequired: await finish(.failed(OpenWebUIError.decoding("").message))
                }
            } catch {
                await finish(.failed(error.message))
            }
        case .pendingApproval:
            await finish(.pendingApproval(nil))
        case .failed(let message):
            await finish(.failed(message))
        }
    }

    /// The page itself failed to load (offline, TLS, …).
    public func loadFailed(_ error: URLError) async {
        guard state == .browsing else { return }
        await finish(.failed(OpenWebUIError.transport(error.code).message))
    }

    public func cancel() async {
        guard state == .browsing else { return }
        await finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) async {
        state = .finished
        await onOutcome(outcome)
    }
}
