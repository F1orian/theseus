import ChatDomain
public import Auth
public import Entitlements
import Foundation
public import Observation
public import OpenWebUIKit

/// What the Settings sheet asks the app to do. The app shell (`AppFeature`) owns sessions,
/// Keychain items and cache databases, so Settings only calls back.
public struct SettingsActions {
    /// Revoke the Session token and return to sign-in (SET-04).
    public var signOut: @MainActor () async -> Void
    /// Sign out and forget the Account on this device: credentials, cache and preferences (SET-10).
    public var removeAccountFromDevice: @MainActor () async -> Void
    /// Erase the Account's local mirror cache (SET-07); Chats reload from the Server.
    public var clearCache: @MainActor () async throws -> Void
    /// The cache's size on disk in bytes, if known.
    public var cacheSize: @MainActor () async -> Int64?

    public init(
        signOut: @escaping @MainActor () async -> Void,
        removeAccountFromDevice: @escaping @MainActor () async -> Void,
        clearCache: @escaping @MainActor () async throws -> Void,
        cacheSize: @escaping @MainActor () async -> Int64?
    ) {
        self.signOut = signOut
        self.removeAccountFromDevice = removeAccountFromDevice
        self.clearCache = clearCache
        self.cacheSize = cacheSize
    }
}

/// One row of the Settings sheet's Account and App groups.
public enum SettingsRow: Hashable, Sendable {
    case profile
    case instructions
    /// "Server & usage", in place of a billing page (SET-09).
    case serverUsage
    case notifications
    /// "Data & privacy" (SET-07).
    case dataPrivacy
    case sharedLinks
    case capabilities
    /// Settings › Skills: your own and shared Skills (#187).
    case skills
    case connectors
    case permissions
    case voice
    case styles
    /// The model for new Chats (MODEL-04).
    case models
    case hapticFeedback
}

/// Pushed pages inside the Settings sheet.
public enum SettingsPage: Hashable, Sendable {
    case `extension`(SettingsExtensionPage)
    case serverUsage
    case notifications
    case dataPrivacy
    case sharedLinks
    case sharedChat(SharedChatLink)
    case capabilities
    /// Settings › Skills (#187).
    case skills
    /// Server administration › Skills (#187, admins).
    case skillsAdministration
    case about
    case acknowledgements
    /// Settings › App Icon (BRAND-02).
    case appIcon
    /// Settings › About › The Collection: the artworks' and the typeface's credits (BRAND-04).
    case collection
    /// Settings › Server administration (#186, admins only): rows Feature areas contribute.
    case administration
    /// One contributed Server administration row, by `SettingsAdministrationRow.id`.
    case administrationRow(String)
    /// Settings › Server administration › User permissions (#186).
    case userPermissions
    /// Settings › Theseus Pro (ADR 0173).
    case pro
}

/// The Settings sheet (SET-01): the Account, its gated rows, haptics, appearance and Log out.
@MainActor
@Observable
public final class SettingsModel {
    /// The signed-in Account. `accountRenamed(to:)` keeps its name current.
    public private(set) var account: Account
    public let preferences: AccountPreferencesStore
    /// Capabilities for this Server and Account without a Model (ADR 0006). Seeded by the app and
    /// refreshed by `load()`.
    public private(set) var capabilities: Capabilities
    public private(set) var user: SessionUser?
    public private(set) var serverVersion: String?
    /// Pages other Feature areas plugged in.
    public var extensions = SettingsExtensions()
    /// Opens the Account switcher (AUTH-07) when the app provides one; the row is hidden otherwise.
    public var switchAccount: (@MainActor () -> Void)?
    /// The Settings navigation stack.
    public var path: [SettingsPage] = []
    /// Shared links (SET-08), shared by the list and the snapshot pages.
    public let sharedLinks: SharedLinksModel
    /// Response notifications (SET-06).
    public let notifier: ResponseNotifier
    /// Settings › App Icon (BRAND-02). Its row hides where alternate icons aren't supported.
    public let appIcons: AppIconPickerModel
    /// Theseus Pro (ADR 0173): the upgrade card, Settings › Theseus Pro and the App Icon gate.
    /// `nil` hides them (and gates nothing).
    public var pro: ProStore?

    @ObservationIgnored let client: OpenWebUIClient
    @ObservationIgnored let actions: SettingsActions

    public init(
        account: Account,
        client: OpenWebUIClient,
        preferences: AccountPreferencesStore,
        capabilities: Capabilities,
        notifier: ResponseNotifier? = nil,
        appIconSwitcher: (any AppIconSwitching)? = nil,
        actions: SettingsActions
    ) {
        self.account = account
        self.client = client
        self.preferences = preferences
        self.capabilities = capabilities
        self.actions = actions
        sharedLinks = SharedLinksModel(client: client)
        self.notifier = notifier
            ?? ResponseNotifier(center: InertNotificationCenter(), preferences: preferences, isAppActive: { true })
        appIcons = AppIconPickerModel(switcher: appIconSwitcher ?? systemAppIconSwitcher())
    }

    /// Whether the Appearance group shows the App Icon row (`supportsAlternateIcons`).
    public var showsAppIconRow: Bool { appIcons.isSupported }

    public var canSwitchAccount: Bool { switchAccount != nil }

    /// Whether Settings shows Server administration (#186): admins only. It appears once `load()`
    /// confirmed the Account's role.
    public var showsAdministration: Bool {
        user?.role == .admin
    }

    /// The Server's host, as Server administration names it ("Changes affect everyone on …").
    public var serverHost: String {
        ServerDisplay.host(account.server.url, fallback: account.server.name)
    }

    /// The model behind Server administration › User permissions.
    public func makeUserPermissionsModel() -> UserPermissionsModel {
        UserPermissionsModel(client: client, host: serverHost)
    }

    /// The Account's full name changed (a Profile rename, PERS-01): refresh the Account card.
    public func accountRenamed(to name: String) {
        account.name = name
    }

    /// The Account group, in display order.
    public var accountRows: [SettingsRow] {
        var rows: [SettingsRow] = [.profile]
        if capabilities.contains(.instructions) { rows.append(.instructions) }
        rows += [.serverUsage, .notifications, .dataPrivacy]
        if capabilities.contains(.shareChat) { rows.append(.sharedLinks) }
        return rows
    }

    /// The App group, in display order. The haptics switch is always last.
    public var appRows: [SettingsRow] {
        // Skills (#187) are for everyone: without permission to create, the page explains why.
        var rows: [SettingsRow] = [.capabilities, .skills]
        let pluggable: [(SettingsRow, SettingsExtensionPage)] = [
            (.models, .models),
            (.connectors, .connectors), (.permissions, .permissions), (.voice, .voice), (.styles, .styles),
        ]
        for (row, page) in pluggable where extensions.isRegistered(page) {
            rows.append(row)
        }
        rows.append(.hapticFeedback)
        return rows
    }

    /// Refreshes the Capabilities and the Account's role from the Server. Offline, the seeded
    /// Capabilities stay.
    public func load() async {
        do {
            async let config = client.send(.config)
            async let user = client.send(.sessionUser)
            // The sandbox row (ADR 0120) needs the Account's terminals; optional.
            async let terminals = try? client.send(.terminals)
            let (loadedConfig, loadedUser) = try await (config, user)
            self.user = loadedUser
            serverVersion = loadedConfig.version
            capabilities = Capabilities.resolve(features: loadedConfig.features, user: loadedUser, model: nil, terminals: await terminals)
        } catch {
            // Keep what we have; each page reports its own errors.
        }
    }

    /// Signs out (SET-04). The app returns to sign-in, which dismisses the sheet.
    public func logOut() async {
        await actions.signOut()
    }

    /// Opens `page` on top of the Settings stack.
    public func open(_ page: SettingsPage) {
        path.append(page)
    }
}
