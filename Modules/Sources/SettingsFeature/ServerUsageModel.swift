import ChatDomain
public import Auth
public import Foundation
public import Observation
public import OpenWebUIKit

/// Settings > Server & usage (SET-09). Open WebUI has no plans or billing, so this replaces
/// In place of a billing page: the Server, the Account's role, and personal usage statistics.
@MainActor
@Observable
public final class ServerUsageModel {
    public let account: Account
    public private(set) var serverVersion: String?
    public private(set) var user: SessionUser?
    public private(set) var usage: UsageStats?
    public private(set) var usageError: String?
    public private(set) var isLoading = false

    @ObservationIgnored private let client: OpenWebUIClient

    public init(account: Account, client: OpenWebUIClient, user: SessionUser?) {
        self.account = account
        self.client = client
        self.user = user
    }

    public var serverHost: String {
        ServerDisplay.host(account.server.url)
    }

    /// "Admin", "User" or "Pending", once known.
    public var role: String? {
        switch user?.role {
        case .admin: "Admin"
        case .user: "User"
        case .pending: "Pending approval"
        case .other(let name): name.capitalized
        case nil: nil
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        async let version = try? client.send(.version)
        // Not `Result { async … }`: the async Result initializer needs Swift 6.4, and CI builds with Xcode 26.6 / Swift 6.3.
        async let usage = Self.capture { () async throws(OpenWebUIError) -> UsageStats in try await client.send(.usage) }
        if user == nil {
            user = try? await client.send(.sessionUser)
        }
        serverVersion = await version?.version ?? serverVersion
        switch await usage {
        case .success(let stats):
            self.usage = stats
            usageError = nil
        case .failure(let error):
            usageError = error.message
        }
    }

    private nonisolated static func capture<T: Sendable>(
        _ body: () async throws(OpenWebUIError) -> T
    ) async -> Result<T, OpenWebUIError> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// `12.6M`, `950`: token counts in the locale's compact notation.
    nonisolated static func compact(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }
}
