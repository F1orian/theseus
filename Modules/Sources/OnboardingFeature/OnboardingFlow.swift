import ChatDomain
public import Auth
import Foundation
public import Observation
public import OpenWebUIKit

/// The whole signed-out experience as one state machine: Server entry → sign in → (verification,
/// pending approval) → a signed-in `AuthenticatedSession`, handed to `onSignedIn`.
///
/// The app shell only decides *where* the flow starts (`Start`) and what happens with the
/// session; every step in between lives here.
@MainActor
@Observable
public final class OnboardingFlow {
    /// The screen currently shown.
    public enum Step {
        case serverEntry(ServerEntryModel)
        case signIn(SignInModel)
        case pendingApproval(PendingApprovalModel)
        case verification(VerificationModel)
    }

    /// Where the flow begins.
    public enum Start: Sendable {
        /// "Connect to your server", optionally prefilled.
        case serverEntry(address: String = "")
        /// Sign in to a known Server, e.g. after sign-out or when the Session token expired.
        /// `config` is fetched when `nil`.
        case signIn(server: ServerProfile, config: ServerConfig? = nil, email: String = "", notice: String? = nil)
        /// The Account is signed in but awaits admin approval (e.g. found at launch).
        case pendingApproval(AuthenticatedSession)
    }

    /// Persists the session and opens the main shell. Throwing keeps the user on the flow with an error.
    public typealias SignedInHandler = @MainActor (AuthenticatedSession) async throws -> Void

    public private(set) var step: Step

    /// When set, the flow shows Cancel (e.g. while adding a second Account) and calls this.
    public var onCancel: (@MainActor () -> Void)?

    /// Accounts already on this device; Server entry offers them as shortcuts (AUTH-07).
    public var accountShortcuts: [Account] = [] {
        didSet {
            if case .serverEntry(let model) = step { model.accountShortcuts = accountShortcuts }
        }
    }

    /// Picking a shortcut hands the Account back to the app, which switches to it.
    public var onPickAccount: (@MainActor (Account) async -> Void)?

    @ObservationIgnored let transport: any HTTPTransport
    @ObservationIgnored private let onSignedIn: SignedInHandler

    public init(start: Start, transport: any HTTPTransport, onSignedIn: @escaping SignedInHandler) {
        self.transport = transport
        self.onSignedIn = onSignedIn
        step = .serverEntry(ServerEntryModel(transport: transport))
        switch start {
        case .serverEntry(let address):
            showServerEntry(address: address)
        case .signIn(let server, let config, let email, let notice):
            showSignIn(server: server, config: config, email: email, notice: notice)
        case .pendingApproval(let session):
            showPendingApproval(server: session.account.server, session: session, email: session.account.email)
        }
    }

    /// Leaves the flow without signing in (only when `onCancel` is set).
    public func cancel() {
        onCancel?()
    }

    // MARK: Transitions

    func showServerEntry(address: String = "") {
        let model = ServerEntryModel(transport: transport)
        model.address = address
        model.accountShortcuts = accountShortcuts
        model.onConnected = { [weak self] server, config in
            self?.showSignIn(server: server, config: config)
        }
        model.onPickAccount = { [weak self] account in
            await self?.onPickAccount?(account)
        }
        step = .serverEntry(model)
    }

    func showSignIn(server: ServerProfile, config: ServerConfig?, email: String = "", notice: String? = nil) {
        let model = SignInModel(server: server, config: config, transport: transport)
        model.prefill(email: email)
        model.notice = notice
        model.onSignedIn = { [weak self, weak model] session in
            do {
                try await self?.onSignedIn(session)
            } catch {
                model?.errorMessage = Self.saveFailedMessage
            }
        }
        model.onChangeServer = { [weak self] in
            self?.showServerEntry(address: ServerDisplay.isHidingServer ? "" : server.url.host() ?? "")
        }
        model.onPendingApproval = { [weak self, weak model] session in
            self?.showPendingApproval(server: server, session: session, email: model?.email ?? "")
        }
        model.onMFARequired = { [weak self, weak model] challenge in
            self?.showVerification(server: server, email: model?.email ?? "", challenge: challenge)
        }
        step = .signIn(model)
    }

    func showVerification(server: ServerProfile, email: String, challenge: MFAChallenge) {
        let model = VerificationModel(server: server, email: email, challenge: challenge, transport: transport)
        model.onSignedIn = { [weak self] session in
            do {
                try await self?.onSignedIn(session)
            } catch {
                self?.showSignIn(server: server, config: nil, email: email, notice: Self.saveFailedMessage)
            }
        }
        model.onBack = { [weak self] notice in
            self?.showSignIn(server: server, config: nil, email: email, notice: notice)
        }
        step = .verification(model)
    }

    func showPendingApproval(server: ServerProfile, session: AuthenticatedSession?, email: String) {
        let model = PendingApprovalModel(server: server, session: session, transport: transport)
        model.onApproved = { [weak self] session in
            do {
                try await self?.onSignedIn(session)
            } catch {
                self?.showSignIn(server: server, config: nil, email: email, notice: Self.saveFailedMessage)
            }
        }
        model.onSignInAgain = { [weak self] notice in
            self?.showSignIn(server: server, config: nil, email: email, notice: notice)
        }
        step = .pendingApproval(model)
    }

    private static let saveFailedMessage = "Couldn't save your sign-in on this device."
}
