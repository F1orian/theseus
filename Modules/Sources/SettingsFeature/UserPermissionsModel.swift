import Foundation
public import Observation
public import OpenWebUIKit

/// Settings › Server administration › User permissions (#186): two switches on the **default**
/// user permissions (`/api/v1/users/default/permissions`). Each change is confirmed first, then
/// written read-modify-write so other keys (changed meanwhile in the web admin) survive.
@MainActor
@Observable
public final class UserPermissionsModel {
    /// One switch of the page.
    public struct Permission: Identifiable, Hashable, Sendable {
        /// The dotted key in the permission tree.
        public let id: String
        public let title: String
        public let caption: String
        public let systemImage: String

        public static let personalConnectors = Permission(
            id: DefaultUserPermissions.personalConnectors,
            title: "Let users add personal connectors",
            caption: "People can connect their own OpenAPI tool servers, in Theseus and the web app. Their device or browser calls the server.",
            systemImage: "person.crop.circle.badge.plus"
        )

        public static let createSkills = Permission(
            id: DefaultUserPermissions.createSkills,
            title: "Let users create skills",
            caption: "People can write their own skills and share them with others.",
            systemImage: "book.closed"
        )

        public static let all: [Permission] = [.personalConnectors, .createSkills]
    }

    /// A change waiting for the admin's confirmation.
    public struct PendingChange: Identifiable, Equatable, Sendable {
        public let permission: Permission
        public let newValue: Bool
        public var id: String { permission.id }
    }

    public enum LoadState: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: LoadState = .loading
    public private(set) var permissions: DefaultUserPermissions?
    public var pending: PendingChange?
    /// The permission being written right now.
    public private(set) var saving: String?
    /// A failed save, shown under the list.
    public var notice: String?
    public let host: String

    @ObservationIgnored private let client: OpenWebUIClient

    public init(client: OpenWebUIClient, host: String) {
        self.client = client
        self.host = host
    }

    public func load() async {
        do {
            permissions = try await client.send(.defaultUserPermissions)
            state = .loaded
        } catch {
            if permissions == nil { state = .failed(error.message) } else { notice = error.message }
        }
    }

    public func isOn(_ permission: Permission) -> Bool {
        permissions?.allows(permission.id) ?? false
    }

    /// The switch was flipped: ask before anything is written.
    public func request(_ permission: Permission, on: Bool) {
        guard on != isOn(permission) else { return }
        pending = PendingChange(permission: permission, newValue: on)
    }

    /// The admin confirmed `pending`: re-read, change only that key, write.
    public func confirm() async {
        guard let change = pending else { return }
        await confirm(change)
    }

    /// The admin confirmed `change` (the alert hands it over: it clears `pending` before its
    /// button's action runs).
    public func confirm(_ change: PendingChange) async {
        pending = nil
        saving = change.permission.id
        defer { saving = nil }
        do {
            permissions = try await client.updateDefaultUserPermission(change.permission.id, to: change.newValue)
            notice = nil
        } catch {
            notice = "Couldn't save. \(error.message)"
            await load()
        }
    }

    public func cancel() {
        pending = nil
    }
}
