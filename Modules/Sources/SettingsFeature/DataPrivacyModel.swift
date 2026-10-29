import ChatDomain
public import Auth
public import Foundation
public import Observation
public import OpenWebUIKit

/// Settings > Data & privacy (SET-07) and Delete account (SET-10).
///
/// Open WebUI has no training opt-in and users can't delete themselves, so instead of a
/// privacy page this says where the data lives (this Server), who runs it (the admin contact, when
/// the Server publishes it), offers local cache controls, and replaces Delete account with a
/// "contact your Server admin" dialog plus "Remove this Account from this device".
@MainActor
@Observable
public final class DataPrivacyModel {
    public let account: Account
    public private(set) var adminContact: AdminContact?
    public private(set) var cacheSize: Int64?
    public private(set) var isClearingCache = false
    public private(set) var didClearCache = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let actions: SettingsActions

    public init(account: Account, client: OpenWebUIClient, actions: SettingsActions) {
        self.account = account
        self.client = client
        self.actions = actions
    }

    public var serverHost: String {
        ServerDisplay.host(account.server.url)
    }

    /// `mailto:` for the admin, when the Server publishes an email.
    public var adminEmailURL: URL? {
        guard let email = adminContact?.email, !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
    }

    public func load() async {
        // 400 means the admin chose not to publish contact details (SHOW_ADMIN_DETAILS=false).
        adminContact = try? await client.send(.adminContact)
        cacheSize = await actions.cacheSize()
    }

    public func clearCache() async {
        isClearingCache = true
        defer { isClearingCache = false }
        do {
            try await actions.clearCache()
            didClearCache = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't clear the cache."
        }
        cacheSize = await actions.cacheSize()
    }

    /// Signs out and forgets this Account on this device. Its data on the Server stays.
    public func removeAccountFromDevice() async {
        await actions.removeAccountFromDevice()
    }

    public func dismissError() {
        errorMessage = nil
    }
}

extension SettingsModel {
    /// A Data & privacy model for this Account. Also backs `DeleteAccountRow` on other pages.
    public func makeDataPrivacyModel() -> DataPrivacyModel {
        DataPrivacyModel(account: account, client: client, actions: actions)
    }
}
