public import Auth
import Foundation
public import Observation
import OpenWebUIKit

/// "Connect to your server": validates the address against `/api/config`.
@MainActor
@Observable
public final class ServerEntryModel {
    public var address = ""
    public private(set) var isConnecting = false
    public private(set) var errorMessage: String?

    /// Accounts already on this device, offered as shortcuts below the field (AUTH-07).
    public internal(set) var accountShortcuts: [Account] = []

    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored var onConnected: (ServerProfile, ServerConfig) -> Void = { _, _ in }
    @ObservationIgnored var onPickAccount: (Account) async -> Void = { _ in }

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public var canSubmit: Bool {
        !isConnecting && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Continue with an Account already on this device.
    public func pick(_ account: Account) async {
        await onPickAccount(account)
    }

    public func connect() async {
        guard canSubmit else { return }
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            let (server, config) = try await ServerConnection(transport: transport).connect(to: address)
            onConnected(server, config)
        } catch {
            errorMessage = error.message
        }
    }
}

