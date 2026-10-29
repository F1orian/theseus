public import OpenWebUIKit

/// What this Account may do with connectors on this Server (#186). It decides which sections
/// Settings › Connectors shows and whether Server administration offers Connectors.
public struct ConnectorAccess: Sendable, Equatable {
    /// The Account is a Server admin.
    public var isAdmin: Bool
    /// `features.enable_tool_servers`: tool servers (shared and personal) are on for the Server.
    public var toolServersEnabled: Bool
    /// `permissions.features.direct_tool_servers` (admins always): personal connectors allowed.
    public var personalPermitted: Bool
    /// `features.enable_direct_integrations`: the Server-wide switch for personal tool servers
    /// (Admin › Settings › Connections › Direct integrations; `ENABLE_TOOL_SERVERS` and
    /// `direct.integrations.enable`, `B/main.py`). Servers that don't report it count as on.
    public var directIntegrationsEnabled: Bool

    public init(isAdmin: Bool, toolServersEnabled: Bool, personalPermitted: Bool, directIntegrationsEnabled: Bool = true) {
        self.isAdmin = isAdmin
        self.toolServersEnabled = toolServersEnabled
        self.personalPermitted = personalPermitted
        self.directIntegrationsEnabled = directIntegrationsEnabled
    }

    public init(user: SessionUser, features: ServerFeatures) {
        isAdmin = user.role == .admin
        toolServersEnabled = features.isEnabled("enable_tool_servers")
        personalPermitted = isAdmin || user.permissions.allows(DefaultUserPermissions.personalConnectors)
        directIntegrationsEnabled = features.raw["enable_direct_integrations"]?.boolValue ?? toolServersEnabled
    }

    /// Nothing is known yet: show no controls.
    public static let unknown = ConnectorAccess(isAdmin: false, toolServersEnabled: false, personalPermitted: false, directIntegrationsEnabled: false)

    /// Personal connectors can be added and used.
    public var canUsePersonal: Bool { toolServersEnabled && directIntegrationsEnabled && personalPermitted }

    /// Shared connections can be managed (Server administration › Connectors).
    public var canManageShared: Bool { toolServersEnabled && isAdmin }

    /// Why personal connectors aren't available, for the explanation in Settings › Connectors.
    public var personalUnavailableReason: PersonalUnavailableReason? {
        if !toolServersEnabled { return .toolServersOff }
        if !directIntegrationsEnabled { return .integrationsOff }
        if !personalPermitted { return .notPermitted }
        return nil
    }

    public enum PersonalUnavailableReason: Sendable, Equatable {
        /// The Server has tool servers off altogether.
        case toolServersOff
        /// Direct integrations are off for the whole Server.
        case integrationsOff
        /// The admin hasn't given users `features.direct_tool_servers`.
        case notPermitted
    }
}
