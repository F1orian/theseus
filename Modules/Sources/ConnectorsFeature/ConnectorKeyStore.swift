import Foundation
import Security
import Synchronization

/// Personal connectors' keys that #186 kept in this device's Keychain. Since #189 the key lives in
/// the connector's entry in the user settings, like the web client stores it (ADR 0095, amended),
/// so this store is only read once to move a key there, and then emptied. Keys are per Account and
/// per connector id.
public protocol ConnectorKeyStore: Sendable {
    func key(for connector: String) -> String?
    func removeKey(for connector: String)
    /// Forgets every key of the Account (after the move, or when the Account leaves the device).
    func removeAll()
}

/// The Keychain items #186 wrote: generic passwords per Account and connector.
public struct KeychainConnectorKeyStore: ConnectorKeyStore {
    private let service: String
    private let accountKey: String

    public init(accountKey: String, service: String = "dev.unrush.theseus.connector-keys") {
        self.accountKey = accountKey
        self.service = service
    }

    public func key(for connector: String) -> String? {
        var query = baseQuery(connector)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func removeKey(for connector: String) {
        SecItemDelete(baseQuery(connector) as CFDictionary)
    }

    public func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrLabel as String: accountKey,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(_ connector: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(accountKey)|\(connector)",
            kSecAttrLabel as String: accountKey,
        ]
    }
}

/// Keys in memory, for tests, previews and UI-test launches.
public final class InMemoryConnectorKeyStore: ConnectorKeyStore {
    private let keys = Mutex<[String: String]>([:])

    public init(_ keys: [String: String] = [:]) {
        self.keys.withLock { $0 = keys }
    }

    public var isEmpty: Bool { keys.withLock { $0.isEmpty } }

    public func key(for connector: String) -> String? {
        keys.withLock { $0[connector] }
    }

    public func removeKey(for connector: String) {
        _ = keys.withLock { $0.removeValue(forKey: connector) }
    }

    public func removeAll() {
        keys.withLock { $0.removeAll() }
    }
}
