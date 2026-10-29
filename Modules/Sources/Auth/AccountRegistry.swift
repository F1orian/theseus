public import Foundation
import Synchronization

/// The Accounts known on this device and which one is active. Holds no secrets (those live in a
/// `CredentialStore`); persisted as JSON so the app can restore the last Account at launch.
public final class AccountRegistry: Sendable {
    private struct Snapshot: Codable {
        var accounts: [Account] = []
        var activeAccountID: String?
    }

    private let fileURL: URL?
    private let state: Mutex<Snapshot>

    /// - Parameter fileURL: Where to persist; `nil` keeps the registry in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let snapshot = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        state = Mutex(snapshot ?? Snapshot())
    }

    public var accounts: [Account] {
        state.withLock { $0.accounts }
    }

    public var activeAccount: Account? {
        state.withLock { snapshot in
            snapshot.accounts.first { $0.id == snapshot.activeAccountID }
        }
    }

    /// Adds or updates `account` and makes it the active one.
    public func activate(_ account: Account) throws {
        try mutate { snapshot in
            if let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) {
                snapshot.accounts[index] = account
            } else {
                snapshot.accounts.append(account)
            }
            snapshot.activeAccountID = account.id
        }
    }

    /// Updates a known Account's details (e.g. its name after a Profile rename) without changing
    /// which Account is active. Unknown Accounts are ignored.
    public func update(_ account: Account) throws {
        try mutate { snapshot in
            guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }) else { return }
            snapshot.accounts[index] = account
        }
    }

    /// Clears the active Account (e.g. on sign-out) but remembers it for quick re-sign-in.
    public func deactivate() throws {
        try mutate { $0.activeAccountID = nil }
    }

    /// Forgets `accountID` entirely.
    public func remove(_ accountID: String) throws {
        try mutate { snapshot in
            snapshot.accounts.removeAll { $0.id == accountID }
            if snapshot.activeAccountID == accountID {
                snapshot.activeAccountID = nil
            }
        }
    }

    private func mutate(_ change: (inout Snapshot) -> Void) throws {
        let data: Data? = try state.withLock { snapshot in
            change(&snapshot)
            return fileURL == nil ? nil : try JSONEncoder().encode(snapshot)
        }
        guard let fileURL, let data else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
