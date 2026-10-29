public import ComposerFeature
public import OpenWebUIKit
public import SettingsFeature
import SwiftUI

/// Plugs the Connectors & tools area into the rest of the app: Settings › Connectors,
/// Settings › Permissions and Server administration › Connectors (`SettingsExtensions`), and
/// Add to Chat › Connectors (`AddToChatExtensions`). Every entry is gated by its Capability
/// (ADR 0006); Server administration only shows for admins (#186).
public enum ConnectorsRegistration {
    /// Registers Connectors (when the Server offers any kind of tool) and Permissions.
    @MainActor
    public static func register(
        in extensions: inout SettingsExtensions,
        directory: ConnectorDirectory,
        location: LocationSharing,
        capabilities: Capabilities
    ) {
        if capabilities.contains(.connectors) {
            extensions.register(.connectors) {
                ConnectorsSettingsPage(directory: directory)
            }
        }
        extensions.register(.permissions) {
            PermissionsPage(location: location)
        }
        // #186: the Server's tool-server connections, for admins (the section is admin-only).
        extensions.registerAdministration(SettingsAdministrationRow(
            id: "connectors",
            title: "Connectors",
            systemImage: "square.grid.2x2",
            subtitle: "Tool servers everyone can use",
            order: SettingsAdministrationRow.Order.connectors
        ) {
            ServerConnectionsPage(directory: directory)
        })
    }

    /// Adds the per-Chat Connectors page to the Add to Chat sheet. The sheet shows the row only
    /// when the selected model's Capabilities include `.connectors`.
    @MainActor
    public static func register(in extensions: inout AddToChatExtensions, directory: ConnectorDirectory) {
        extensions.connectors = { composer in
            AnyView(ChatConnectorsPage(directory: directory, composer: composer))
        }
        extensions.connectorsValue = { composer in
            let usable = Set(directory.usable.map(\.id))
            let count = composer.enabledToolIDs.filter(usable.contains).count
            return count == 0 ? nil : "\(count) on"
        }
    }
}
