import Foundation

/// The default permissions every non-admin user gets (`GET/POST /api/v1/users/default/permissions`,
/// admin only; `UserPermissions` in `B/routers/users.py`). Groups can add to them; admins bypass
/// them. Settings › Server administration › User permissions changes two keys (#186).
///
/// The tree stays a `JSONValue`, so a write sends back every key Theseus doesn't know as it was
/// read. Writes are read-modify-write (`OpenWebUIClient.updateDefaultUserPermission(_:to:)`).
public struct DefaultUserPermissions: Sendable, Equatable, Decodable {
    /// `features.direct_tool_servers`: users may add personal connectors (direct tool servers).
    public static let personalConnectors = "features.direct_tool_servers"
    /// `workspace.skills`: users may create Skills in their workspace (#187).
    public static let createSkills = "workspace.skills"

    public private(set) var raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(JSONValue.self)
    }

    /// The value at the dotted `path` (e.g. `"features.direct_tool_servers"`); missing is `false`.
    public func allows(_ path: String) -> Bool {
        raw[path: path]?.boolValue ?? false
    }

    /// Sets the value at the dotted `path`, creating intermediate objects; everything else stays.
    public mutating func set(_ path: String, to value: Bool) {
        raw = Self.setting(raw, keys: path.split(separator: ".").map(String.init)[...], to: .bool(value))
    }

    private static func setting(_ node: JSONValue, keys: ArraySlice<String>, to value: JSONValue) -> JSONValue {
        guard let key = keys.first else { return value }
        var object = node.objectValue ?? [:]
        object[key] = setting(object[key] ?? .object([:]), keys: keys.dropFirst(), to: value)
        return .object(object)
    }
}

extension Endpoint where Response == DefaultUserPermissions {
    /// `GET /api/v1/users/default/permissions` (admin): the defaults, with the Server's own
    /// defaults filled in for missing keys.
    public static var defaultUserPermissions: Self {
        Endpoint(method: .get, path: "api/v1/users/default/permissions", authentication: .required)
    }

    /// `POST /api/v1/users/default/permissions` (admin) with the whole tree. The Server replaces
    /// the stored tree, so always send one you just read (`updateDefaultUserPermission`).
    public static func updateDefaultUserPermissions(_ permissions: DefaultUserPermissions) -> Self {
        let body = try? WireCoding.encoder.encode(permissions.raw)
        return Endpoint(method: .post, path: "api/v1/users/default/permissions", body: body ?? Data(), authentication: .required)
    }
}

extension OpenWebUIClient {
    /// Read-modify-write of one default permission: re-reads the tree right before writing and
    /// changes only `path`, so a concurrent change to another key in the web admin isn't reverted.
    @discardableResult
    public func updateDefaultUserPermission(_ path: String, to value: Bool) async throws(OpenWebUIError) -> DefaultUserPermissions {
        var permissions = try await send(.defaultUserPermissions)
        permissions.set(path, to: value)
        return try await send(.updateDefaultUserPermissions(permissions))
    }
}
