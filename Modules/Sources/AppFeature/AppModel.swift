import ChatDomain
public import AppIntentsFeature
public import Auth
import ComposerFeature
public import DesignSystem
public import Entitlements
public import Foundation
public import Observation
public import OnboardingFeature
import OpenWebUIKit
import Persistence
import SettingsFeature

/// Root navigation: the signed-out `OnboardingFlow` → main shell. Owns Session lifetime (token
/// storage, renewal, expiry) so screens only deal with their own state.
@MainActor
@Observable
public final class AppModel {
    public enum Route {
        case launching
        /// Signed out: Server entry, sign-in and its follow-up steps (OnboardingFeature).
        case onboarding(OnboardingFlow)
        /// Signed in, but the Account hasn't agreed yet to send its data to the Server and its AI
        /// providers (App Review 5.1.2(i), ADR 0171). The shell waits, unloaded, behind the question.
        case aiDataConsent(MainShellModel)
        case main(MainShellModel)
    }

    public private(set) var route: Route = .launching
    /// The Account switcher sheet (AUTH-07), while open.
    public var accountSwitcher: AccountSwitcherModel?
    /// Theseus Pro for every Account on this device (ADR 0173).
    public let pro: ProStore
    @ObservationIgnored private let environment: AppEnvironment
    /// The signed-in shell kept alive while the user adds another Account, so Cancel returns to it.
    @ObservationIgnored private var suspendedShell: MainShellModel?
    /// Created at launch so a tapped Response notification can open its Chat (SET-06).
    @ObservationIgnored private let notifications: any NotificationScheduling
    /// A deep link that arrived while signed out or launching; opened once an Account is (PLAT-03).
    @ObservationIgnored private var pendingLink: DeepLink?
    /// Which Accounts agreed to share their data with their Server's AI (ADR 0171).
    @ObservationIgnored var consentRecord: AIDataConsentRecord
    /// The active Account's accent, read from its stored preferences at launch (#179).
    @ObservationIgnored private let launchAccent: AccentChoice

    public init(environment: AppEnvironment) {
        self.environment = environment
        notifications = environment.makeNotificationCenter()
        consentRecord = AIDataConsentRecord(defaults: environment.preferences)
        // The free code execution runs count per device, across Accounts.
        pro = ProStore(backend: environment.proBackend, allowance: SandboxAllowance(defaults: environment.preferences))
        launchAccent = environment.registry.activeAccount.map {
            AccountPreferencesStore(accountID: $0.id, defaults: environment.preferences).preferences.accent
        } ?? .default
        // Before the first frame (the splash), so a non-default accent never flashes Verdigris.
        AccentSelection.shared.choice = launchAccent
    }

    /// The accent the app shows (#179, ADR 0145): the signed-in Account's choice; the active
    /// Account's stored one while launching; Verdigris while signed out (like the appearance,
    /// which follows the system then). `RootView` applies it to `AccentSelection.shared`.
    public var accent: AccentChoice {
        switch route {
        case .launching: launchAccent
        case .onboarding: .default
        case .aiDataConsent(let shell), .main(let shell): shell.preferences.preferences.accent
        }
    }

    // MARK: Deep links (PLAT-03)

    /// Opens a `theseus://` URL; returns whether Theseus understood it.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        open(link)
        return true
    }

    /// Opens `link` in the active Account, or after sign-in when there is none yet.
    public func open(_ link: DeepLink) {
        if case .main(let shell) = route {
            accountSwitcher = nil
            shell.open(link)
        } else {
            pendingLink = link
        }
    }

    /// Restores the active Account from the registry + Keychain, or starts onboarding.
    public func start() async {
        guard case .launching = route else { return }
        let pro = pro
        Task { await pro.start() }
        guard let account = environment.registry.activeAccount,
              let credential = try? environment.credentials.credential(for: account.id)
        else {
            showServerEntry()
            return
        }
        // A token past its `exp` would only bounce off the Server: ask to sign in right away.
        guard !SessionToken.isExpired(credential.sessionToken) else {
            try? environment.credentials.deleteCredential(for: account.id)
            showSignIn(server: account.server, config: nil, email: account.email, notice: Self.expiredNotice)
            return
        }
        await openSession(account: account, credential: credential)
    }

    /// Call when the app returns to the foreground: a Session token that expired while the app
    /// was in the background ends the session before any request fails.
    public func sceneDidBecomeActive() async {
        // A purchase on another device, a refund or Ask to Buy may have landed meanwhile.
        if pro.status != .unknown { await pro.refreshEntitlement() }
        guard case .main(let shell) = route,
              let token = try? environment.credentials.credential(for: shell.account.id)?.sessionToken,
              SessionToken.isExpired(token)
        else { return }
        await sessionExpired(account: shell.account)
    }

    // MARK: Transitions

    func showServerEntry(address: String = "") {
        showOnboarding(.serverEntry(address: address))
    }

    func showSignIn(server: ServerProfile, config: ServerConfig?, email: String = "", notice: String? = nil) {
        showOnboarding(.signIn(server: server, config: config, email: email, notice: notice))
    }

    private func showOnboarding(_ start: OnboardingFlow.Start) {
        let flow = OnboardingFlow(start: start, transport: environment.transport) { [weak self] session in
            try await self?.completeSignIn(session)
        }
        let current = suspendedShell?.account.id
        flow.accountShortcuts = environment.registry.accounts.filter { $0.id != current }
        flow.onPickAccount = { [weak self] account in await self?.switchAccount(to: account) }
        if let suspendedShell {
            flow.onCancel = { [weak self] in
                self?.suspendedShell = nil
                self?.route = .main(suspendedShell)
            }
        }
        route = .onboarding(flow)
    }

    // MARK: Accounts (AUTH-07)

    /// Opens the Account switcher as a sheet over the whole app.
    public func showAccountSwitcher() {
        accountSwitcher = makeAccountSwitcher()
    }

    /// A switcher wired to this app's Accounts, e.g. for the Settings sheet to present.
    public func makeAccountSwitcher() -> AccountSwitcherModel {
        let switcher = AccountSwitcherModel(
            registry: environment.registry,
            credentials: environment.credentials,
            actions: .init(
                switchTo: { [weak self] account in await self?.switchAccount(to: account) },
                addAccount: { [weak self] in self?.addAccount() },
                remove: { [weak self] account in await self?.removeAccount(account) }
            )
        )
        // ADR 0173: more than one Account is Pro.
        switcher.pro = pro
        return switcher
    }

    /// Starts onboarding for another Account; Cancel returns to the current one.
    public func addAccount() {
        if case .main(let shell) = route {
            shell.isSettingsPresented = false
            suspendedShell = shell
        }
        showServerEntry()
    }

    /// Makes `account` the active one. Uses its stored Session token when it's still valid,
    /// otherwise asks for its password (with Cancel back to the current Account).
    public func switchAccount(to account: Account) async {
        if case .main(let shell) = route {
            guard shell.account.id != account.id else { return }
            shell.isSettingsPresented = false
            // Cancel returns here, unless this Account was just removed.
            let isStillOnDevice = environment.registry.accounts.contains { $0.id == shell.account.id }
            suspendedShell = isStillOnDevice ? shell : nil
        }
        if let credential = try? environment.credentials.credential(for: account.id),
           !SessionToken.isExpired(credential.sessionToken) {
            do {
                try environment.registry.activate(account)
            } catch {
                return
            }
            await openSession(account: account, credential: credential)
        } else {
            showSignIn(server: account.server, config: nil, email: account.email)
        }
    }

    /// "Remove from this device": revokes and forgets the Account's token, its registry entry and
    /// its cached database. If it was the active Account, moves on to another signed-in one.
    public func removeAccount(_ account: Account) async {
        let wasActive = environment.registry.activeAccount?.id == account.id
        if let shell = mainShell(for: account) { retire(shell) }
        if let token = try? environment.credentials.credential(for: account.id)?.sessionToken {
            let client = OpenWebUIClient(
                server: account.server.url,
                transport: environment.transport,
                authorizer: FixedTokenAuthorizer(token: token)
            )
            _ = try? await client.send(.signOut)
        }
        try? environment.credentials.deleteCredential(for: account.id)
        try? environment.registry.remove(account.id)
        AccountPreferencesStore.remove(accountID: account.id, defaults: environment.preferences)
        consentRecord.remove(accountID: account.id)
        ComposerLocalStore(accountKey: account.id, defaults: environment.preferences).removeAll()
        if let directory = environment.databaseDirectory {
            // Each Account's database lives in its own folder (with its -wal/-shm files).
            let folder = AccountDatabase.fileURL(forAccountKey: account.id, in: directory).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: folder)
        }
        if suspendedShell?.account.id == account.id { suspendedShell = nil }
        guard wasActive else { return }
        let next = environment.registry.accounts.first { candidate in
            (try? environment.credentials.credential(for: candidate.id)).flatMap { $0 } != nil
        }
        if let next {
            await switchAccount(to: next)
        } else {
            environment.sharedState?.clear()
            showServerEntry(address: ServerDisplay.isHidingServer ? "" : account.server.url.host() ?? "")
        }
    }

    private func completeSignIn(_ session: AuthenticatedSession) async throws {
        let credential = Credential(sessionToken: session.token)
        try environment.credentials.save(credential, for: session.account.id)
        try environment.registry.activate(session.account)
        await openSession(account: session.account, credential: credential)
    }

    private func openSession(account: Account, credential: Credential) async {
        let authenticator = makeAuthenticator(account: account, credential: credential)
        let client = OpenWebUIClient(server: account.server.url, transport: environment.transport, authorizer: authenticator)
        let database = openDatabase(for: account)
        let preferences = AccountPreferencesStore(accountID: account.id, defaults: environment.preferences)
        let shell = MainShellModel(
            account: account,
            client: client,
            database: database,
            preferences: preferences,
            composerStore: ComposerLocalStore(accountKey: account.id, defaults: environment.preferences),
            notificationCenter: notifications,
            pro: pro
        ) { [weak self] in
            await self?.signOut(account: account, client: client)
        }
        shell.makeAccountSwitcher = { [weak self] in self?.makeAccountSwitcher() }
        shell.sharedState = environment.sharedState
        // Another Account's Chats must not linger in the widgets while this one loads.
        if let shared = environment.sharedState, shared.snapshots.read()?.accountID != account.id { shared.clear() }
        // Each Account gets its own socket: close the previous shell's before showing this one.
        var leaving: [MainShellModel] = []
        if case .main(let previous) = route { leaving.append(previous) }
        if let suspendedShell, !leaving.contains(where: { $0 === suspendedShell }) { leaving.append(suspendedShell) }
        leaving.forEach(retire)
        suspendedShell = nil
        (notifications as? UserNotificationCenter)?.onOpenChat = { [weak shell] chatID in
            shell?.isSettingsPresented = false
            shell?.navigate(to: .chat(id: chatID))
        }
        shell.onRemoveAccount = { [weak self] in
            await self?.removeFromDevice(account: account, client: client)
        }
        shell.onAccountChanged = { [registry = environment.registry] changed in
            try? registry.update(changed)
        }
        if environment.asksForAIDataConsent, consentRecord.isNeeded(accountID: account.id) {
            // A deep link (e.g. Ask Theseus) waits in `pendingLink` until the user agrees.
            route = .aiDataConsent(shell)
            return
        }
        await present(shell)
    }

    /// Shows the signed-in shell, opens a deep link that waited for it, and loads the Account.
    private func present(_ shell: MainShellModel) async {
        if let link = pendingLink {
            pendingLink = nil
            shell.open(link)
        }
        route = .main(shell)
        await shell.refresh()
    }

    // MARK: AI data consent (ADR 0171)

    /// "Agree and continue": remembered for this Account on this device.
    public func agreeToAIDataSharing() async {
        guard case .aiDataConsent(let shell) = route else { return }
        consentRecord.record(accountID: shell.account.id)
        await present(shell)
    }

    /// "Sign out": nothing was sent; back to the sign-in screen for this Server.
    public func declineAIDataSharing() async {
        guard case .aiDataConsent(let shell) = route else { return }
        pendingLink = nil
        retire(shell)
        await shell.signOut()
    }

    private func makeAuthenticator(account: Account, credential: Credential) -> SessionAuthenticator {
        let credentials = environment.credentials
        let transport = environment.transport
        let password = credential.password
        return SessionAuthenticator(
            token: credential.sessionToken,
            renew: {
                // Silent renewal is only possible if the user opted to store the password.
                guard let password else { throw OpenWebUIError.unauthorized(detail: nil) }
                let outcome = try await PasswordSignIn(server: account.server, transport: transport)
                    .signIn(email: account.email, password: password)
                guard case .signedIn(let session) = outcome else { throw OpenWebUIError.unauthorized(detail: nil) }
                return session.token
            },
            onTokenChange: { [weak self] token in
                if let token {
                    try? credentials.save(Credential(sessionToken: token, password: password), for: account.id)
                    Task { @MainActor in await self?.mainShell(for: account)?.sessionTokenDidChange() }
                } else {
                    Task { @MainActor in await self?.sessionExpired(account: account) }
                }
            }
        )
    }

    private func openDatabase(for account: Account) -> AccountDatabase? {
        guard let directory = environment.databaseDirectory else { return try? AccountDatabase.inMemory() }
        let url = AccountDatabase.fileURL(forAccountKey: account.id, in: directory)
        return (try? AccountDatabase(fileURL: url)) ?? (try? AccountDatabase.inMemory())
    }

    /// The Session token was rejected and could not be renewed. Either an admin moved the Account
    /// back to pending (its token still identifies it), or the session is over: ask to sign in again.
    func sessionExpired(account: Account) async {
        guard isShowingMain(account) else { return }
        if let token = try? environment.credentials.credential(for: account.id)?.sessionToken,
           !SessionToken.isExpired(token),
           case .pendingApproval(let session?)? = try? await TokenSignIn(server: account.server, transport: environment.transport)
               .signIn(token: token) {
            guard let shell = mainShell(for: account) else { return }
            retire(shell)
            showOnboarding(.pendingApproval(session))
            return
        }
        guard let shell = mainShell(for: account) else { return }
        retire(shell)
        try? environment.credentials.deleteCredential(for: account.id)
        environment.sharedState?.clear()
        showSignIn(server: account.server, config: nil, email: account.email, notice: Self.expiredNotice)
    }

    private func isShowingMain(_ account: Account) -> Bool {
        mainShell(for: account) != nil
    }

    private func mainShell(for account: Account) -> MainShellModel? {
        if case .main(let shell) = route, shell.account.id == account.id { shell } else { nil }
    }

    /// Closes a shell the app is leaving for good (its Chat socket and health checks).
    private func retire(_ shell: MainShellModel) {
        Task { await shell.tearDown() }
    }

    static let expiredNotice = "Your session has expired. Please sign in again."

    /// SET-10: signs out and forgets the Account on this device (credentials, registry entry, cache
    /// database and preferences). Its data on the Server is untouched.
    /// Same as the Account switcher's "Remove from this device" (AUTH-07): moves on to another
    /// signed-in Account, or to Server entry when none is left.
    func removeFromDevice(account: Account, client: OpenWebUIClient) async {
        await removeAccount(account)
    }

    private func signOut(account: Account, client: OpenWebUIClient) async {
        _ = try? await client.send(.signOut)
        try? environment.credentials.deleteCredential(for: account.id)
        try? environment.registry.deactivate()
        environment.sharedState?.clear()
        showSignIn(server: account.server, config: nil, email: account.email)
    }
}
