public import Auth
public import Entitlements
public import Foundation
public import Observation

/// AUTH-07: the Accounts on this device, grouped by Server, with the active one checked. Each
/// Account's data stays isolated (own credential, own database); switching only changes which
/// one the app shows. Embeddable in Settings (SET-01); for now the main shell presents it as a sheet.
@MainActor
@Observable
public final class AccountSwitcherModel: Identifiable {
    /// One row of the switcher.
    public struct Row: Identifiable, Equatable, Sendable {
        public let account: Account
        public let isActive: Bool
        /// A Session token is stored, so switching needs no password.
        public let isSignedIn: Bool

        public var id: String { account.id }

        public init(account: Account, isActive: Bool, isSignedIn: Bool) {
            self.account = account
            self.isActive = isActive
            self.isSignedIn = isSignedIn
        }
    }

    /// The rows of one Server.
    public struct ServerGroup: Identifiable, Equatable, Sendable {
        public let server: ServerProfile
        public let rows: [Row]

        public var id: URL { server.url }
    }

    /// What the app does for each choice.
    public struct Actions {
        public var switchTo: @MainActor (Account) async -> Void
        public var addAccount: @MainActor () -> Void
        public var remove: @MainActor (Account) async -> Void

        public init(
            switchTo: @escaping @MainActor (Account) async -> Void,
            addAccount: @escaping @MainActor () -> Void,
            remove: @escaping @MainActor (Account) async -> Void
        ) {
            self.switchTo = switchTo
            self.addAccount = addAccount
            self.remove = remove
        }
    }

    public let id = UUID()
    public private(set) var groups: [ServerGroup] = []
    /// Theseus Pro (ADR 0173): the first Account is free, more need Pro. `nil` doesn't gate.
    public var pro: ProStore?
    /// The paywall, when adding an Account needs Pro.
    public var paywallRequest: PaywallRequest?

    @ObservationIgnored private let registry: AccountRegistry
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let actions: Actions

    public init(registry: AccountRegistry, credentials: any CredentialStore, actions: Actions) {
        self.registry = registry
        self.credentials = credentials
        self.actions = actions
        reload()
    }

    /// Re-reads the registry (after a removal or sign-in).
    public func reload() {
        groups = Self.groups(registry: registry, credentials: credentials)
    }

    /// Switches to `row`'s Account. Returns `false` when the paywall opened instead.
    @discardableResult
    public func select(_ row: Row) async -> Bool {
        guard !row.isActive else { return true }
        // ADR 0173: keeping several Accounts signed in and switching between them is Pro. Without
        // it, logging out and signing in to another Account still works.
        if let pro, !pro.isPro {
            paywallRequest = PaywallRequest(.accounts)
            return false
        }
        await actions.switchTo(row.account)
        return true
    }

    /// Whether "Add account" needs Pro: an Account is already on this device and Pro isn't unlocked.
    public var addingNeedsPro: Bool {
        guard let pro, !pro.isPro else { return false }
        return !groups.isEmpty
    }

    /// Starts adding an Account, or asks for Pro first. Returns whether onboarding started (so the
    /// sheet closes).
    @discardableResult
    public func addAccount() -> Bool {
        if addingNeedsPro {
            paywallRequest = PaywallRequest(.accounts)
            return false
        }
        actions.addAccount()
        return true
    }

    /// "Remove from this device": forgets the Account's credential and cached data here. The
    /// Account itself stays on its Server.
    public func remove(_ row: Row) async {
        await actions.remove(row.account)
        reload()
    }

    /// Groups `registry` by Server (in the order Servers were first added), Accounts by name.
    static func groups(registry: AccountRegistry, credentials: any CredentialStore) -> [ServerGroup] {
        let activeID = registry.activeAccount?.id
        var order: [URL] = []
        var byServer: [URL: (ServerProfile, [Row])] = [:]
        for account in registry.accounts {
            let token = try? credentials.credential(for: account.id)?.sessionToken
            let row = Row(
                account: account,
                isActive: account.id == activeID,
                isSignedIn: token.map { !SessionToken.isExpired($0) } ?? false
            )
            if byServer[account.server.url] == nil {
                order.append(account.server.url)
                byServer[account.server.url] = (account.server, [])
            }
            byServer[account.server.url]?.1.append(row)
        }
        return order.compactMap { url in
            byServer[url].map { server, rows in
                ServerGroup(server: server, rows: rows.sorted { $0.account.name.localizedStandardCompare($1.account.name) == .orderedAscending })
            }
        }
    }
}
