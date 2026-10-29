public import Foundation

/// A signed-in user as returned by sign-in (`SessionUserResponse`) and `GET /api/v1/auths/`.
public struct SessionUser: Sendable, Equatable {
    public let id: String
    public let name: String
    public let email: String
    public let role: UserRole
    /// Server-relative avatar path, e.g. `/api/v1/users/{id}/profile/image`.
    public let profileImagePath: String?
    /// The Session token (JWT). Present on sign-in; also echoed by `GET /api/v1/auths/`.
    public let token: String?
    public let expiresAt: Date?
    public let permissions: UserPermissions

    public init(
        id: String,
        name: String,
        email: String,
        role: UserRole,
        profileImagePath: String? = nil,
        token: String? = nil,
        expiresAt: Date? = nil,
        permissions: UserPermissions = UserPermissions(raw: .object([:]))
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.profileImagePath = profileImagePath
        self.token = token
        self.expiresAt = expiresAt
        self.permissions = permissions
    }
}

extension SessionUser: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, name, email, role, token, permissions
        case profileImageURL = "profile_image_url"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        role = try container.decodeIfPresent(UserRole.self, forKey: .role) ?? .pending
        profileImagePath = try container.decodeIfPresent(String.self, forKey: .profileImageURL)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
            .map { Date(timeIntervalSince1970: $0) }
        permissions = UserPermissions(raw: try container.decodeIfPresent(JSONValue.self, forKey: .permissions) ?? .object([:]))
    }
}

public enum UserRole: Sendable, Hashable, Decodable {
    case admin
    case user
    /// Awaiting admin approval: can sign in, but every user-level endpoint returns 401.
    case pending
    case other(String)

    public init(from decoder: any Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "admin": self = .admin
        case "user": self = .user
        case "pending": self = .pending
        case let other: self = .other(other)
        }
    }
}

/// The per-user permission tree (`workspace.*`, `sharing.*`, `chat.*`, `features.*`, …).
/// Defaults live in the server's `DEFAULT_USER_PERMISSIONS`; admins bypass it (see `Capabilities`).
public struct UserPermissions: Sendable, Equatable {
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    /// Whether the dotted permission `path` (e.g. `"chat.file_upload"`) is granted. Missing is `false`.
    public func allows(_ path: String) -> Bool {
        raw[path: path]?.boolValue ?? false
    }
}
