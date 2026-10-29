public import Foundation
import Security
import Synchronization

/// Secure storage for `Credential`s, keyed by `Account.id`.
public protocol CredentialStore: Sendable {
    func credential(for accountID: String) throws(CredentialStoreError) -> Credential?
    func save(_ credential: Credential, for accountID: String) throws(CredentialStoreError)
    func deleteCredential(for accountID: String) throws(CredentialStoreError)
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(OSStatus)
    /// The stored item could not be decoded.
    case corrupted
}

/// Keychain-backed store (generic passwords, this-device-only, available after first unlock so
/// background refresh works). One item per Account; the value is the JSON-encoded `Credential`.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: Keychain service name; tests pass a unique one.
    ///   - accessGroup: An app-group keychain group, so extensions can share credentials.
    public init(service: String = "dev.unrush.theseus.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func credential(for accountID: String) throws(CredentialStoreError) -> Credential? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = try? JSONDecoder().decode(Credential.self, from: data)
            else { throw .corrupted }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    public func save(_ credential: Credential, for accountID: String) throws(CredentialStoreError) {
        guard let data = try? JSONEncoder().encode(credential) else { throw .corrupted }
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(accountID) as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(accountID)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw .keychain(addStatus) }
        default:
            throw .keychain(status)
        }
    }

    public func deleteCredential(for accountID: String) throws(CredentialStoreError) {
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }

    private func baseQuery(_ accountID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// A non-persistent store for tests, previews and UI-test launches.
public final class InMemoryCredentialStore: CredentialStore {
    private let items: Mutex<[String: Credential]>

    public init(_ items: [String: Credential] = [:]) {
        self.items = Mutex(items)
    }

    public func credential(for accountID: String) throws(CredentialStoreError) -> Credential? {
        items.withLock { $0[accountID] }
    }

    public func save(_ credential: Credential, for accountID: String) throws(CredentialStoreError) {
        items.withLock { $0[accountID] = credential }
    }

    public func deleteCredential(for accountID: String) throws(CredentialStoreError) {
        _ = items.withLock { $0.removeValue(forKey: accountID) }
    }
}
