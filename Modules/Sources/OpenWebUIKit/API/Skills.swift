public import Foundation

// Skills (`/api/v1/skills`, #140, #187, ADR 0096). Shapes from `B/models/skills.py`
// (`SkillResponse`, `SkillUserResponse`, `SkillAccessResponse`, `SkillDetailResponse`, `SkillForm`),
// routes from `B/routers/skills.py`, sharing from `B/models/access_grants.py` and
// `B/utils/access_control` (`filter_allowed_access_grants`). See docs/research/open-webui-api.md
// § "Skills: personal and shared (#187)".

/// One of the Server's workspace Skills (`GET /api/v1/skills/`, #140): reusable instructions the
/// model can load. A Chat can pick Skills for its Messages (`skill_ids`); with native function
/// calling the model may also read one on its own (`view_skill`).
///
/// A Skill belongs to the user who made it (`user_id`) and is private until it is shared through
/// access grants (#187): with everyone on the Server, with groups, or with people.
public struct Skill: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let description: String?
    public let isActive: Bool
    /// The owner's user id (`user_id`); `nil` in old fixtures.
    public let userID: String?
    /// The owner, when the Server joined it in (`user`, on the list routes).
    public let owner: SkillOwner?
    /// Who else may read or edit it (`access_grants`); empty = only the owner.
    public let accessGrants: [SkillAccessGrant]
    /// The current version (`version_id`); a file import that replaces it must name it.
    public let versionID: String?
    /// Whether this Account may edit it (`write_access`, `/list` and detail only).
    public let writeAccess: Bool?
    public let updatedAt: Date?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        isActive: Bool = true,
        userID: String? = nil,
        owner: SkillOwner? = nil,
        accessGrants: [SkillAccessGrant] = [],
        versionID: String? = nil,
        writeAccess: Bool? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isActive = isActive
        self.userID = userID
        self.owner = owner
        self.accessGrants = accessGrants
        self.versionID = versionID
        self.writeAccess = writeAccess
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, user
        case isActive = "is_active"
        case userID = "user_id"
        case accessGrants = "access_grants"
        case versionID = "version_id"
        case writeAccess = "write_access"
        case updatedAt = "updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        self.name = (name?.isEmpty ?? true) ? id : name ?? id
        let description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        self.description = description?.isEmpty == true ? nil : description
        isActive = ((try? container.decodeIfPresent(Bool.self, forKey: .isActive)) ?? nil) ?? true
        userID = (try? container.decodeIfPresent(String.self, forKey: .userID)) ?? nil
        owner = (try? container.decodeIfPresent(SkillOwner.self, forKey: .user)) ?? nil
        accessGrants = ((try? container.decodeIfPresent([SkillAccessGrant].self, forKey: .accessGrants)) ?? nil) ?? []
        versionID = (try? container.decodeIfPresent(String.self, forKey: .versionID)) ?? nil
        writeAccess = (try? container.decodeIfPresent(Bool.self, forKey: .writeAccess)) ?? nil
        updatedAt = ((try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil)
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// How it is shared, read from its access grants.
    public var sharing: SkillSharing { SkillSharing(grants: accessGrants) }

    /// Whether `userID` made it.
    public func isOwned(by userID: String?) -> Bool {
        guard let userID, let owner = self.userID else { return false }
        return owner == userID
    }
}

/// A Skill's owner (`UserResponse` joined in by `GET /api/v1/skills/` and `/list`).
public struct SkillOwner: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    public let email: String?

    public init(id: String, name: String, email: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
    }
}

/// One access grant (`AccessGrantModel`): a principal and a permission on a Skill.
/// `principal_type` is `user` (with `*` for everyone signed in), `group` or `anyone`.
public struct SkillAccessGrant: Sendable, Hashable, Codable {
    public let principalType: String
    public let principalID: String
    /// `read` or `write`.
    public let permission: String

    public init(principalType: String, principalID: String, permission: String = "read") {
        self.principalType = principalType
        self.principalID = principalID
        self.permission = permission
    }

    /// Everyone signed in to the Server may read it (`user` / `*` / `read`).
    public static let everyone = SkillAccessGrant(principalType: "user", principalID: "*")

    public static func group(_ id: String, permission: String = "read") -> Self {
        SkillAccessGrant(principalType: "group", principalID: id, permission: permission)
    }

    public var isEveryone: Bool { principalType == "user" && principalID == "*" }
    public var isGroup: Bool { principalType == "group" }
    /// A grant to one person (not the `*` wildcard).
    public var isPerson: Bool { principalType == "user" && principalID != "*" }

    private enum CodingKeys: String, CodingKey {
        case principalType = "principal_type"
        case principalID = "principal_id"
        case permission
    }
}

/// How a Skill is shared, the way Theseus offers it (#187): only its owner, everyone on the
/// Server, or some groups. Grants to single people (set in the web client) show as `.people`.
public enum SkillSharing: Sendable, Hashable {
    case onlyOwner
    case everyone
    case groups([String])
    case people

    public init(grants: [SkillAccessGrant]) {
        let groups = grants.filter(\.isGroup).map(\.principalID)
        if grants.contains(where: \.isEveryone) {
            self = .everyone
        } else if !groups.isEmpty {
            var unique: [String] = []
            for id in groups where !unique.contains(id) { unique.append(id) }
            self = .groups(unique)
        } else if grants.contains(where: \.isPerson) {
            self = .people
        } else {
            self = .onlyOwner
        }
    }

    /// The grants for this sharing. Grants to single people in `existing` stay (the web client
    /// sets them; Theseus doesn't offer them), as do write grants of groups that stay selected.
    /// `.onlyOwner` removes every grant.
    public func grants(keeping existing: [SkillAccessGrant] = []) -> [SkillAccessGrant] {
        switch self {
        case .onlyOwner:
            return []
        case .people:
            return existing
        case .everyone:
            return existing.filter(\.isPerson) + [.everyone]
        case .groups(let ids):
            var grants = existing.filter(\.isPerson)
            for id in ids {
                grants.append(.group(id))
                if existing.contains(.group(id, permission: "write")) { grants.append(.group(id, permission: "write")) }
            }
            return grants
        }
    }
}

/// `SkillDetailResponse`: a Skill with its `SKILL.md` (`content`).
public struct SkillDetail: Sendable, Equatable, Identifiable, Decodable {
    public let skill: Skill
    public var id: String { skill.id }
    /// The Markdown instructions (the `SKILL.md` file, front matter included).
    public let content: String

    public init(skill: Skill, content: String) {
        self.skill = skill
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case content }

    public init(from decoder: any Decoder) throws {
        skill = try Skill(from: decoder)
        content = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .content) ?? ""
    }
}

/// `SkillForm` for `POST /create` and `POST /id/{id}/update`: name, description and the
/// `SKILL.md` instructions (`content`). Other files of a Skill stay as they are on update.
public struct SkillDraft: Sendable, Equatable, Encodable {
    public var id: String
    public var name: String
    public var description: String
    /// The Markdown instructions, sent as `content` (the server stores it as `SKILL.md`).
    public var content: String
    public var isActive: Bool
    /// Sent on create; omitted (`nil`) on update so the grants stay. Use `updateSkillAccess` to
    /// change them. Users without `sharing.public_skills` get `*` grants stripped by the server.
    public var accessGrants: [SkillAccessGrant]?

    public init(
        id: String? = nil,
        name: String,
        description: String = "",
        content: String,
        isActive: Bool = true,
        accessGrants: [SkillAccessGrant]? = []
    ) {
        self.id = id ?? SkillDraft.slug(for: name)
        self.name = name
        self.description = description
        self.content = content
        self.isActive = isActive
        self.accessGrants = accessGrants
    }

    /// The id the server would accept for `name`: lower-case `[a-z0-9_-]` (the create route
    /// lower-cases, swaps spaces for `-` and rejects anything else with 400 "Invalid skill ID").
    public static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for character in folded.unicodeScalars {
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "_" {
                slug.unicodeScalars.append(character)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "skill" : slug
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, content
        case isActive = "is_active"
        case accessGrants = "access_grants"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(content, forKey: .content)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(accessGrants, forKey: .accessGrants)
    }
}

/// `SkillAccessListResponse` from `GET /api/v1/skills/list` (30 per page).
public struct SkillPage: Sendable, Equatable, Decodable {
    public let items: [Skill]
    public let total: Int
}

/// What `GET /api/v1/skills/list` lists (`view_option`).
public enum SkillListView: String, Sendable {
    /// Made by this Account.
    case created
    /// Made by others and shared with this Account.
    case shared
}

/// A group of users on the Server (`GET /api/v1/groups/`), to share a Skill with.
public struct SharingGroup: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

// MARK: Import

/// A Skill package parsed by the server (`POST /load/url`, `parse_import` in
/// `B/utils/skill_files.py`): `id`, `name`, `description`, `meta` and its `files`. Kept as raw
/// JSON so it can go back to `/import` unchanged.
public struct SkillPackage: Sendable, Equatable, Decodable {
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        raw = try JSONValue(from: decoder)
    }

    public var id: String { raw[path: "id"]?.stringValue ?? "" }
    public var name: String { raw[path: "name"]?.stringValue ?? id }
    public var description: String? { raw[path: "description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
}

/// A file to import (`/import/preview`, `/import`): `.skill` and `.zip` archives, `SKILL.md` or
/// `.md` files and JSON packages. The server picks the parser by the file name's extension.
public struct SkillImportFile: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let data: Data

    public init(filename: String, contentType: String = "application/octet-stream", data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    /// Packages from `/load/url` as one `skills.json` file, the way the web client imports them.
    public static func packages(_ packages: [SkillPackage]) -> Self {
        let data = (try? WireCoding.encoder.encode(JSONValue.array(packages.map(\.raw)))) ?? Data("[]".utf8)
        return SkillImportFile(filename: "skills.json", contentType: "application/json", data: data)
    }
}

/// One Skill found in an import (`POST /import/preview`), and whether its id or name is taken.
public struct SkillImportPreview: Sendable, Equatable, Identifiable, Decodable {
    public let index: Int
    public let id: String
    public let name: String
    public let description: String?
    public let fileCount: Int
    /// A Skill with this id exists.
    public let idTaken: Bool
    /// A Skill with this name exists (names are unique on the Server).
    public let nameTaken: Bool
    /// The existing Skill may be replaced by this Account.
    public let canReplace: Bool
    /// The version a replacement must name.
    public let expectedVersionID: String?

    public init(
        index: Int, id: String, name: String, description: String? = nil, fileCount: Int = 1,
        idTaken: Bool = false, nameTaken: Bool = false, canReplace: Bool = false, expectedVersionID: String? = nil
    ) {
        self.index = index
        self.id = id
        self.name = name
        self.description = description
        self.fileCount = fileCount
        self.idTaken = idTaken
        self.nameTaken = nameTaken
        self.canReplace = canReplace
        self.expectedVersionID = expectedVersionID
    }

    private enum CodingKeys: String, CodingKey {
        case index, id, name, description, files
        case idTaken = "id_taken"
        case nameTaken = "name_taken"
        case canReplace = "can_replace"
        case expectedVersionID = "expected_version_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        let description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        self.description = description?.isEmpty == true ? nil : description
        fileCount = ((try? container.decodeIfPresent([JSONValue].self, forKey: .files)) ?? nil)?.count ?? 1
        idTaken = try container.decodeIfPresent(Bool.self, forKey: .idTaken) ?? false
        nameTaken = try container.decodeIfPresent(Bool.self, forKey: .nameTaken) ?? false
        canReplace = try container.decodeIfPresent(Bool.self, forKey: .canReplace) ?? false
        expectedVersionID = try container.decodeIfPresent(String.self, forKey: .expectedVersionID)
    }

    /// Whether adding it as is would clash with an existing Skill.
    public var isTaken: Bool { idTaken || nameTaken }

    /// What to do with it unless the user picks otherwise: add it when nothing clashes, else
    /// add a copy under a new id and name. Never replace without asking.
    public var defaultDecision: SkillImportDecision {
        isTaken ? .copy(of: self) : .create(self)
    }
}

/// What to do with one previewed Skill (`decisions` of `POST /import`, one per Skill, in order).
public struct SkillImportDecision: Sendable, Equatable, Encodable {
    public enum Action: String, Sendable {
        case create, copy, replace, skip
    }

    public var action: Action
    public var id: String
    public var name: String
    /// Required by `replace`.
    public var expectedVersionID: String?

    public init(action: Action, id: String, name: String, expectedVersionID: String? = nil) {
        self.action = action
        self.id = id
        self.name = name
        self.expectedVersionID = expectedVersionID
    }

    public static func create(_ preview: SkillImportPreview) -> Self {
        SkillImportDecision(action: .create, id: preview.id, name: preview.name)
    }

    /// A copy next to the existing Skill: `<id>-copy` and "<name> (copy)".
    public static func copy(of preview: SkillImportPreview) -> Self {
        SkillImportDecision(action: .copy, id: preview.id + "-copy", name: preview.name + " (copy)")
    }

    public static func replace(_ preview: SkillImportPreview) -> Self {
        SkillImportDecision(action: .replace, id: preview.id, name: preview.name, expectedVersionID: preview.expectedVersionID)
    }

    public static func skip(_ preview: SkillImportPreview) -> Self {
        SkillImportDecision(action: .skip, id: preview.id, name: preview.name)
    }

    private enum CodingKeys: String, CodingKey {
        case action, id, name
        case expectedVersionID = "expected_version_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(expectedVersionID, forKey: .expectedVersionID)
    }
}

/// The outcome for one Skill of `POST /import`.
public struct SkillImportResult: Sendable, Equatable, Decodable {
    public enum Status: String, Sendable, Decodable {
        case saved, skipped, error
    }

    public let status: Status
    public let id: String
    public let error: String?

    public init(status: Status, id: String, error: String? = nil) {
        self.status = status
        self.id = id
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case status, id, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(Status.self, forKey: .status)) ?? .error
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        // `error` is the HTTPException detail: usually a string, sometimes an object.
        if let text = try? container.decodeIfPresent(String.self, forKey: .error) {
            error = text
        } else if let value = try? container.decodeIfPresent(JSONValue.self, forKey: .error), value != .null {
            error = value[path: "message"]?.stringValue ?? value[path: "code"]?.stringValue ?? "The skill couldn't be saved."
        } else {
            error = nil
        }
    }
}

/// `SKILL.md` helpers: the YAML front matter the server reads `name` and `description` from on
/// import (`frontmatter` in `B/utils/skill_files.py`), for Skills Theseus creates from a
/// downloaded file.
public enum SkillMarkdown {
    /// The flat `key: value` pairs of a leading `---` block (quotes stripped). Nested YAML is
    /// skipped; `[:]` without front matter.
    public static func frontMatter(_ content: String) -> [String: String] {
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return fields }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return [:]
    }

    /// A readable name from a front-matter slug ('pdf-tools' → "Pdf tools"). Names with spaces
    /// or capitals stay as written.
    public static func displayName(_ name: String) -> String {
        guard name == name.lowercased(), !name.contains(" ") else { return name }
        let spaced = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

// MARK: Permissions

/// What this Account may do with Skills (#187). The server's gates:
/// - create (`POST /create`): admin, `workspace.skills` or `workspace.skills_import`;
/// - import a file (`/import/preview`, `/import`): admin or `workspace.skills_import`;
/// - load from a URL (`POST /load/url`): admins only (`get_admin_user`);
/// - share with everyone (`*` grants): admin or `sharing.public_skills`, else the server strips it;
/// - share with groups: admin or `access_grants.allow_groups`.
/// Editing, toggling, deleting and sharing a Skill needs ownership or a write grant (or admin).
public struct SkillPermissions: Sendable, Equatable {
    public let isAdmin: Bool
    public let canCreate: Bool
    public let canImportFiles: Bool
    public let canLoadFromURLOnServer: Bool
    public let canShareWithEveryone: Bool
    public let canShareWithGroups: Bool

    public init(user: SessionUser) {
        let admin = user.role == .admin
        let permissions = user.permissions
        isAdmin = admin
        canCreate = admin || permissions.allows("workspace.skills") || permissions.allows("workspace.skills_import")
        canImportFiles = admin || permissions.allows("workspace.skills_import")
        canLoadFromURLOnServer = admin
        canShareWithEveryone = admin || permissions.allows("sharing.public_skills")
        canShareWithGroups = admin || permissions.allows("access_grants.allow_groups")
    }

    /// Nothing allowed (not loaded yet).
    public static let none = SkillPermissions(user: SessionUser(id: "", name: "", email: "", role: .pending))

    /// Whether this Account may edit, toggle, delete or share `skill`.
    public func canEdit(_ skill: Skill, userID: String?) -> Bool {
        isAdmin || skill.isOwned(by: userID) || skill.writeAccess == true
            || skill.accessGrants.contains { $0.permission == "write" && $0.principalType == "user" && $0.principalID == userID }
    }
}

/// Where a Skill sits for one Account (#187): its own, shared with it, or, for admins (who see
/// every Skill), someone else's private Skill.
public enum SkillScope: Sendable, Hashable {
    case yours
    case shared
    case othersPrivate

    public init(_ skill: Skill, userID: String?, isAdmin: Bool) {
        if skill.isOwned(by: userID) {
            self = .yours
        } else if isAdmin, skill.accessGrants.isEmpty {
            // Admins list every Skill (`BYPASS_ADMIN_ACCESS_CONTROL`); ungranted ones aren't shared.
            self = .othersPrivate
        } else {
            self = .shared
        }
    }
}

// MARK: Endpoints

extension Endpoint where Response == [Skill] {
    /// `GET /api/v1/skills/`: the Skills this Account can read (its own and shared ones), with
    /// their owners and grants. Admins get every Skill on the Server.
    public static var skills: Self {
        Endpoint(method: .get, path: "api/v1/skills/", authentication: .required)
    }
}

extension Endpoint where Response == SkillPage {
    /// `GET /api/v1/skills/list?view_option=&query=&page=`: one page of 30, newest first, with
    /// `write_access` per Skill.
    public static func skillList(view: SkillListView? = nil, query: String? = nil, page: Int = 1) -> Self {
        var items: [URLQueryItem] = []
        if let view { items.append(URLQueryItem(name: "view_option", value: view.rawValue)) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
        return Endpoint(method: .get, path: "api/v1/skills/list", query: items, authentication: .required)
    }
}

extension Endpoint where Response == SkillDetail {
    /// `GET /api/v1/skills/id/{id}`: one Skill with its instructions.
    public static func skill(id: String) -> Self {
        Endpoint(method: .get, path: "api/v1/skills/id/\(id)", authentication: .required)
    }
}

extension Endpoint where Response == Skill {
    /// `POST /api/v1/skills/create`. 401 without permission, 400 when the id is taken, 409 when
    /// the name is.
    public static func createSkill(_ draft: SkillDraft) -> Self {
        Endpoint(method: .post, path: "api/v1/skills/create", body: SkillWire.encode(draft), authentication: .required)
    }

    /// `POST /api/v1/skills/id/{id}/update`: name, description, instructions and enabled state.
    /// Grants stay unless `draft.accessGrants` is set.
    public static func updateSkill(id: String, _ draft: SkillDraft) -> Self {
        var draft = draft
        draft.id = id
        return Endpoint(method: .post, path: "api/v1/skills/id/\(id)/update", body: SkillWire.encode(draft), authentication: .required)
    }

    /// `POST /api/v1/skills/id/{id}/toggle`: flips `is_active`. A disabled Skill isn't offered
    /// to Chats.
    public static func toggleSkill(id: String) -> Self {
        Endpoint(method: .post, path: "api/v1/skills/id/\(id)/toggle", authentication: .required)
    }

    /// `POST /api/v1/skills/id/{id}/access/update` with `{"access_grants": […]}`: replaces every
    /// grant. `[]` makes it private to its owner.
    public static func updateSkillAccess(id: String, grants: [SkillAccessGrant]) -> Self {
        Endpoint(
            method: .post,
            path: "api/v1/skills/id/\(id)/access/update",
            body: SkillWire.encode(SkillWire.AccessForm(accessGrants: grants)),
            authentication: .required
        )
    }
}

extension Endpoint where Response == Bool {
    /// `DELETE /api/v1/skills/id/{id}/delete`: the Skill, its grants and its version history.
    public static func deleteSkill(id: String) -> Self {
        Endpoint(method: .delete, path: "api/v1/skills/id/\(id)/delete", authentication: .required)
    }
}

extension Endpoint where Response == [SkillPackage] {
    /// `POST /api/v1/skills/load/url` with `{"url": …}` (**admins only**): the server downloads a
    /// `SKILL.md`, `.skill`/ZIP or JSON (GitHub repository and folder links too) and returns the
    /// Skills it found. Nothing is saved; import them with `previewSkillImport`/`importSkills`.
    public static func loadSkills(fromURL url: URL) -> Self {
        Endpoint(
            method: .post,
            path: "api/v1/skills/load/url",
            body: SkillWire.encode(["url": url.absoluteString]),
            authentication: .required
        )
    }
}

extension Endpoint where Response == [SkillImportPreview] {
    /// `POST /api/v1/skills/import/preview` (multipart `files`): what an import would add.
    /// Needs `workspace.skills_import` (or admin); 403 otherwise.
    public static func previewSkillImport(_ files: [SkillImportFile]) -> Self {
        let form = SkillWire.multipart(files: files, decisions: nil)
        return Endpoint(
            method: .post,
            path: "api/v1/skills/import/preview",
            body: form.body,
            contentType: form.contentType,
            authentication: .required
        )
    }
}

extension Endpoint where Response == [SkillImportResult] {
    /// `POST /api/v1/skills/import` (multipart `files` + `decisions` JSON, one per previewed
    /// Skill). New Skills are private (`access_grants: []`).
    public static func importSkills(_ files: [SkillImportFile], decisions: [SkillImportDecision]) -> Self {
        let form = SkillWire.multipart(files: files, decisions: decisions)
        return Endpoint(
            method: .post,
            path: "api/v1/skills/import",
            body: form.body,
            contentType: form.contentType,
            authentication: .required
        )
    }
}

/// What the Server lets ordinary users do with Skills by default (`GET /api/v1/users/default/permissions`,
/// admins only; group permissions can add to it). Read-only here: admins change it on the web or
/// in Server administration › User permissions.
public struct SkillUserDefaults: Sendable, Equatable, Decodable {
    /// `workspace.skills`.
    public let usersCanCreate: Bool
    /// `workspace.skills_import`.
    public let usersCanImport: Bool
    /// `sharing.public_skills`.
    public let usersCanShareWithEveryone: Bool

    public init(usersCanCreate: Bool, usersCanImport: Bool, usersCanShareWithEveryone: Bool = false) {
        self.usersCanCreate = usersCanCreate
        self.usersCanImport = usersCanImport
        self.usersCanShareWithEveryone = usersCanShareWithEveryone
    }

    public init(from decoder: any Decoder) throws {
        let permissions = UserPermissions(raw: try JSONValue(from: decoder))
        usersCanCreate = permissions.allows("workspace.skills")
        usersCanImport = permissions.allows("workspace.skills_import")
        usersCanShareWithEveryone = permissions.allows("sharing.public_skills")
    }
}

extension Endpoint where Response == SkillUserDefaults {
    /// `GET /api/v1/users/default/permissions` (admins only; 401 for others).
    public static var skillUserDefaults: Self {
        Endpoint(method: .get, path: "api/v1/users/default/permissions", authentication: .required)
    }
}

extension Endpoint where Response == [SharingGroup] {
    /// `GET /api/v1/groups/`: the Server's groups (admins see all; users the ones they're in).
    public static var sharingGroups: Self {
        Endpoint(method: .get, path: "api/v1/groups/", authentication: .required)
    }
}

private enum SkillWire {
    struct AccessForm: Encodable {
        let accessGrants: [SkillAccessGrant]
        private enum CodingKeys: String, CodingKey { case accessGrants = "access_grants" }
    }

    static func encode(_ value: some Encodable) -> Data? {
        try? WireCoding.encoder.encode(value)
    }

    static func multipart(files: [SkillImportFile], decisions: [SkillImportDecision]?) -> (body: Data, contentType: String) {
        let boundary = "theseus-\(UUID().uuidString)"
        var body = Data()
        for file in files {
            // Quotes and line breaks would break the part header.
            let name = file.filename.filter { $0 != "\"" && !$0.isNewline }
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\n".utf8))
            body.append(Data("Content-Type: \(file.contentType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        if let decisions {
            let json = (try? WireCoding.encoder.encode(decisions)) ?? Data("[]".utf8)
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"decisions\"\r\n\r\n".utf8))
            body.append(json)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
