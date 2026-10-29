public import Foundation

// Memory & personalization endpoints (PERS-*): the profile, Instructions, the Memory switch,
// Memory entries, and what a Chat sends from them. Paths follow docs/research/open-webui-api.md §1.1,
// §2 and §9.5; storage rules are ADR 0012 (`theseus.*`) and ADR 0030 (shared `ui.*` keys).

// MARK: Profile (PERS-01)

/// The editable part of the Account's server profile (`UpdateProfileForm`). The server writes every
/// field of the form, so an update must carry the current avatar, bio, gender and date of birth
/// back unchanged; `OpenWebUIClient.updateProfileName(_:)` does that read-modify-write.
public struct UserProfile: Sendable, Equatable, Codable {
    /// The full name (`user.name`).
    public var name: String
    /// A data URL, `/user.png`, or an http(s) URL. Empty falls back to the default avatar.
    public var profileImageURL: String
    public var bio: String?
    public var gender: String?
    /// `YYYY-MM-DD`.
    public var dateOfBirth: String?

    public init(name: String, profileImageURL: String, bio: String? = nil, gender: String? = nil, dateOfBirth: String? = nil) {
        self.name = name
        self.profileImageURL = profileImageURL
        self.bio = bio
        self.gender = gender
        self.dateOfBirth = dateOfBirth
    }

    enum CodingKeys: String, CodingKey {
        case name, bio, gender
        case profileImageURL = "profile_image_url"
        case dateOfBirth = "date_of_birth"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        profileImageURL = try container.decodeIfPresent(String.self, forKey: .profileImageURL) ?? ""
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        gender = try container.decodeIfPresent(String.self, forKey: .gender)
        dateOfBirth = try container.decodeIfPresent(String.self, forKey: .dateOfBirth)
    }

    // Optional fields are sent as explicit nulls so the body always names every form field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(profileImageURL, forKey: .profileImageURL)
        try container.encode(bio, forKey: .bio)
        try container.encode(gender, forKey: .gender)
        try container.encode(dateOfBirth, forKey: .dateOfBirth)
    }
}

extension Endpoint where Response == UserProfile {
    /// `GET /api/v1/auths/`: the signed-in user, read as an editable profile.
    public static var userProfile: Self {
        Endpoint(method: .get, path: "api/v1/auths/", authentication: .required)
    }

    /// `POST /api/v1/auths/update/profile`. Prefer `OpenWebUIClient.updateProfileName(_:)`.
    public static func updateProfile(_ profile: UserProfile) -> Self {
        let body = try? WireCoding.encoder.encode(profile)
        return Endpoint(method: .post, path: "api/v1/auths/update/profile", body: body ?? Data(), authentication: .required)
    }
}

extension OpenWebUIClient {
    /// Renames the Account (`user.name`) and keeps the rest of its profile. Returns what the
    /// server stored.
    @discardableResult
    public func updateProfileName(_ name: String) async throws(OpenWebUIError) -> UserProfile {
        var profile = try await send(.userProfile)
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await send(.updateProfile(profile))
    }
}

/// Profile choices with no server field, stored at `theseus.profile` (ADR 0012).
public struct ProfilePreferences: Sendable, Equatable, Codable {
    /// The key inside the `theseus` namespace.
    public static let namespaceKey = "profile"

    /// What Theseus calls the user in Chats (`{{USER_NAME}}`) and greetings. `nil` = the full name.
    public var nickname: String?

    public init(nickname: String? = nil) {
        self.nickname = nickname
    }

    /// The value as stored in the `theseus` namespace.
    public func jsonValue() throws -> JSONValue {
        try WireCoding.decoder.decode(JSONValue.self, from: WireCoding.encoder.encode(self))
    }
}

// MARK: Shared web-client settings (PERS-02, PERS-03; ADR 0030)

/// The only `ui.*` keys Theseus writes. Each has the same meaning as in the Open WebUI web client,
/// so Instructions and the Memory switch are shared across both clients (ADR 0030).
public enum SharedInterfaceSetting: String, Sendable, Hashable, CaseIterable {
    /// Profile Instructions for every Chat (`ui.system`). The server drops it from updates unless
    /// the Account has `chat.controls` and `chat.system_prompt`.
    case instructions = "system"
    /// Whether Chats use and build Memory (`ui.memory`, sent as `features.memory`).
    case memory
    /// Whether Responses come with follow-up suggestions (`ui.autoFollowUps`, sent as
    /// `background_tasks.follow_up_generation`; #141, ADR 0121).
    case followUps = "autoFollowUps"
    /// Personal connectors: the user's direct tool servers (`ui.toolServers`, #186, ADR 0095).
    /// The server drops it from updates unless the Account may use direct tool servers.
    case personalConnectors = "toolServers"
}

extension UserSettings {
    /// Profile Instructions (`ui.system`), empty when unset.
    public var instructions: String {
        raw["ui"]?[path: SharedInterfaceSetting.instructions.rawValue]?.stringValue ?? ""
    }

    /// The Memory switch (`ui.memory`); `nil` when the user never chose, which means on.
    public var memoryPreference: Bool? {
        raw["ui"]?[path: SharedInterfaceSetting.memory.rawValue]?.boolValue
    }

    /// The follow-up suggestions switch (`ui.autoFollowUps`); `nil` when the user never chose,
    /// which Theseus treats as off (#141).
    public var followUpsPreference: Bool? {
        raw["ui"]?[path: SharedInterfaceSetting.followUps.rawValue]?.boolValue
    }

    /// Profile choices at `theseus.profile`.
    public var profilePreferences: ProfilePreferences {
        theseusValue(ProfilePreferences.self, forKey: ProfilePreferences.namespaceKey) ?? ProfilePreferences()
    }

    /// The nickname (`theseus.profile.nickname`), trimmed; `nil` when unset or blank. The home
    /// greeting (HOME-01) and `{{USER_NAME}}` use it instead of the full name.
    public var nickname: String? {
        let value = profilePreferences.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

extension Endpoint where Response == UserSettings {
    /// `POST /api/v1/users/user/settings/update` with `{"ui": {key: value}}` for the named keys only.
    /// The server patches `ui` field by field, so the web client's other settings are untouched.
    public static func updateSharedInterfaceSettings(_ values: [SharedInterfaceSetting: JSONValue]) -> Self {
        let patch = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        let body = try? WireCoding.encoder.encode(JSONValue.object(["ui": .object(patch)]))
        return Endpoint(method: .post, path: "api/v1/users/user/settings/update", body: body ?? Data(), authentication: .required)
    }
}

extension OpenWebUIClient {
    /// Saves profile Instructions (`ui.system`). An empty string clears them.
    @discardableResult
    public func updateInstructions(_ text: String) async throws(OpenWebUIError) -> UserSettings {
        try await send(.updateSharedInterfaceSettings([.instructions: .string(text)]))
    }

    /// Turns follow-up suggestions on or off (`ui.autoFollowUps`, #141).
    @discardableResult
    public func updateFollowUpsPreference(_ isOn: Bool) async throws(OpenWebUIError) -> UserSettings {
        try await send(.updateSharedInterfaceSettings([.followUps: .bool(isOn)]))
    }

    /// Turns Memory on or off for new Chats (`ui.memory`).
    @discardableResult
    public func updateMemoryPreference(_ isOn: Bool) async throws(OpenWebUIError) -> UserSettings {
        try await send(.updateSharedInterfaceSettings([.memory: .bool(isOn)]))
    }
}

// MARK: Memory entries (PERS-04)

/// One remembered fact in the Account's Memory (server term: memory). `path` files it under a
/// topic such as `work/projects`.
public struct MemoryEntry: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        /// A durable fact about the user; the server adds every one of these to each Chat.
        case user
        /// Other context; the server retrieves it when it seems relevant.
        case context
    }

    public let id: String
    public let content: String
    public let path: String?
    public let kind: Kind
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, content: String, path: String? = nil, kind: Kind = .user, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.content = content
        self.path = path
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, content, path, type
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        self.path = path?.isEmpty == true ? nil : path
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .type)) ?? .context
        createdAt = Date(timeIntervalSince1970: try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0)
        updatedAt = Date(timeIntervalSince1970: try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0)
    }
}

extension Endpoint where Response == [MemoryEntry] {
    /// `GET /api/v1/memories/`: every Memory entry of the Account.
    public static var memories: Self {
        Endpoint(method: .get, path: "api/v1/memories/", authentication: .required)
    }
}

extension Endpoint where Response == MemoryEntry {
    /// `POST /api/v1/memories/add`.
    public static func addMemory(content: String, kind: MemoryEntry.Kind, path: String?) -> Self {
        var form: [String: JSONValue] = ["content": .string(content), "type": .string(kind.rawValue)]
        if let path, !path.isEmpty { form["path"] = .string(path) }
        let body = try? WireCoding.encoder.encode(JSONValue.object(form))
        return Endpoint(method: .post, path: "api/v1/memories/add", body: body ?? Data(), authentication: .required)
    }

    /// `POST /api/v1/memories/{id}/update`. The path is always sent; `nil` clears it.
    public static func updateMemory(id: String, content: String, path: String?) -> Self {
        let form: [String: JSONValue] = ["content": .string(content), "path": .string(path ?? "")]
        let body = try? WireCoding.encoder.encode(JSONValue.object(form))
        return Endpoint(method: .post, path: "api/v1/memories/\(id)/update", body: body ?? Data(), authentication: .required)
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/memories/{id}`.
    public static func deleteMemory(id: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/memories/\(id)", authentication: .required) { data in
            (try? WireCoding.decoder.decode(Bool.self, from: data)) ?? true
        }
    }

    /// `DELETE /api/v1/memories/delete/user`: forgets every Memory entry of the Account.
    public static var forgetAllMemories: Self {
        Endpoint(method: .delete, path: "api/v1/memories/delete/user", authentication: .required) { data in
            (try? WireCoding.decoder.decode(Bool.self, from: data)) ?? true
        }
    }
}

// MARK: What a Chat sends

/// The personalization a completion request carries: profile Instructions as the system message,
/// `features.memory`, and the `{{USER_NAME}}` variable (nickname, else full name). The Chat and
/// home screens build this from the user settings; it mirrors what the web client sends.
public struct ChatPersonalization: Sendable, Equatable {
    /// Instructions for the system message, or `nil` when there are none.
    public let instructions: String?
    /// What to call the user: the nickname, else the full name.
    public let preferredName: String
    /// Whether to send `features.memory: true`.
    public let usesMemory: Bool
    /// The chosen Style's instructions (PERS-05), added after the Instructions in the system
    /// prompt; `nil` for Normal.
    public var styleInstructions: String?

    public init(instructions: String?, preferredName: String, usesMemory: Bool, styleInstructions: String? = nil) {
        self.instructions = instructions
        self.preferredName = preferredName
        self.usesMemory = usesMemory
        self.styleInstructions = styleInstructions
    }

    /// The system prompt: Profile Instructions, then the Style (ADR 0111). `nil` when both are empty.
    public var systemPrompt: String? {
        let parts = [instructions, styleInstructions]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Whether a Style adds to the system prompt.
    public var hasStyle: Bool {
        !(styleInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// - Parameter capabilities: resolved for the Chat's Model, so `.memory` covers the Server flag,
    ///   the `features.memories` permission and the model's `memory` capability.
    public init(settings: UserSettings, user: SessionUser, capabilities: Capabilities) {
        let instructions = settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            instructions: instructions.isEmpty ? nil : settings.instructions,
            preferredName: settings.nickname ?? user.name,
            usesMemory: capabilities.contains(.memory) && (settings.memoryPreference ?? true)
        )
    }

    /// The `variables` of a completion request.
    public var variables: [String: String] {
        ["{{USER_NAME}}": preferredName]
    }
}
