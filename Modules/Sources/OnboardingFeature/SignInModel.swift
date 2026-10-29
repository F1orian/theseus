import ChatDomain
public import Auth
import Foundation
public import Observation
public import OpenWebUIKit

/// The sign-in screen for one Server (AUTH-02): the methods its `/api/config` offers, email (or
/// LDAP username) and password, and the outcome of each attempt.
///
/// Theseus never creates Accounts (ADR 0170): App Store apps that create accounts must also delete
/// them in-app, and Open WebUI only lets admins delete users. Accounts come from the Server's web UI
/// or its admin.
@MainActor
@Observable
public final class SignInModel {
    /// Which credential form is showing.
    public enum Mode: Sendable, Equatable {
        case email
        /// Directory username instead of email (`features.enable_ldap`).
        case ldap
    }

    public let server: ServerProfile
    public var mode: Mode = .email
    /// Email, or the LDAP username in `.ldap` mode.
    public var email = ""
    public var password = ""
    /// The password field appears once an identifier was entered (or was prefilled).
    public private(set) var showsPasswordField = false
    public private(set) var isSigningIn = false
    public internal(set) var errorMessage: String?
    /// Informational banner, e.g. "Your session has expired".
    public internal(set) var notice: String?
    public private(set) var config: ServerConfig?
    /// The single sign-on sheet, while one is open.
    public var webSignIn: WebSignInModel?

    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored var onSignedIn: (AuthenticatedSession) async -> Void = { _ in }
    @ObservationIgnored var onChangeServer: () -> Void = {}
    @ObservationIgnored var onPendingApproval: (AuthenticatedSession?) -> Void = { _ in }
    @ObservationIgnored var onMFARequired: (MFAChallenge) -> Void = { _ in }

    init(server: ServerProfile, config: ServerConfig?, transport: any HTTPTransport) {
        self.server = server
        self.config = config
        self.transport = transport
    }

    /// The Server's Open WebUI version, once its config is known.
    public var serverVersion: String? { config?.version }

    /// What this Server offers. Until its config is known, assume the email + password form.
    public var methods: SignInMethods {
        config.map(SignInMethods.init(config:)) ?? SignInMethods(password: true)
    }

    /// `false` when the admin turned off the password form.
    public var allowsPasswordSignIn: Bool {
        mode == .ldap ? methods.ldap : methods.password
    }

    /// The credential form (email or LDAP) is shown at all.
    public var showsCredentialForm: Bool {
        methods.requiresAuth && (methods.password || methods.ldap)
    }

    private var identifier: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canSubmitIdentifier: Bool {
        !isSigningIn && !identifier.isEmpty
    }

    public var canSubmit: Bool {
        !isSigningIn && allowsPasswordSignIn && !identifier.isEmpty && !password.isEmpty
    }

    /// Prefills the identifier (re-sign-in) and goes straight to the password.
    func prefill(email: String) {
        self.email = email
        showsPasswordField = !email.isEmpty
    }

    /// Fetches `/api/config` when the flow started without it (e.g. re-sign-in after expiry).
    public func loadConfigIfNeeded() async {
        guard config == nil else { return }
        config = try? await OpenWebUIClient(server: server.url, transport: transport).send(.config)
        if !methods.password, methods.ldap { mode = .ldap }
    }

    /// The email field's arrow: checks the identifier and reveals the password field.
    public func submitIdentifier() {
        guard canSubmitIdentifier else { return }
        if mode == .email, !Self.looksLikeEmail(identifier) {
            errorMessage = "Enter a valid email address."
            return
        }
        errorMessage = nil
        showsPasswordField = true
    }

    public func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        errorMessage = nil
        password = ""
        showsPasswordField = false
    }

    public func signIn() async {
        guard canSubmit else { return }
        let signIn = PasswordSignIn(server: server, transport: transport)
        let (mode, identifier, password) = (mode, identifier, password)
        await attempt { () async throws(OpenWebUIError) -> SignInOutcome in
            switch mode {
            case .email: try await signIn.signIn(email: identifier, password: password)
            case .ldap: try await signIn.signIn(ldapUsername: identifier, password: password)
            }
        }
    }

    /// Servers without authentication (`WEBUI_AUTH=false`) sign everyone in as their one user.
    public func continueWithoutAccount() async {
        guard !methods.requiresAuth, !isSigningIn else { return }
        let signIn = PasswordSignIn(server: server, transport: transport)
        await attempt { () async throws(OpenWebUIError) -> SignInOutcome in
            try await signIn.signIn(email: "", password: "")
        }
    }

    public func changeServer() {
        onChangeServer()
    }

    // MARK: Single sign-on (AUTH-04)

    /// Opens the provider's login in the sign-on sheet.
    public func startSSO(_ provider: SignInMethods.SSOProvider) {
        openWebSignIn(title: provider.name, WebSignIn.oauth(server: server.url, provider: provider.id))
    }

    /// Opens the Server's own sign-in page, for proxies that authenticate the browser.
    public func startWebPageSignIn() {
        openWebSignIn(title: ServerDisplay.name(server.name), WebSignIn.webPage(server: server.url))
    }

    private func openWebSignIn(title: String, _ webSignIn: WebSignIn) {
        guard !isSigningIn else { return }
        errorMessage = nil
        let model = WebSignInModel(title: title, server: server, webSignIn: webSignIn, transport: transport)
        model.onOutcome = { [weak self] outcome in
            await self?.finishWebSignIn(outcome)
        }
        self.webSignIn = model
    }

    private func finishWebSignIn(_ outcome: WebSignInModel.Outcome) async {
        webSignIn = nil
        switch outcome {
        case .signedIn(let session):
            isSigningIn = true
            defer { isSigningIn = false }
            await onSignedIn(session)
        case .pendingApproval(let session):
            onPendingApproval(session)
        case .failed(let message):
            errorMessage = message
        case .cancelled:
            break
        }
    }

    private func attempt(_ operation: () async throws(OpenWebUIError) -> SignInOutcome) async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            switch try await operation() {
            case .signedIn(let session):
                password = ""
                await onSignedIn(session)
            case .mfaRequired(let challenge):
                password = ""
                onMFARequired(challenge)
            case .pendingApproval(let session):
                password = ""
                onPendingApproval(session)
            }
        } catch {
            errorMessage = error.message
        }
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        // Lenient on purpose: single-label domains (admin@localhost) are valid on self-hosted Servers.
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !text.contains(" ")
    }
}
