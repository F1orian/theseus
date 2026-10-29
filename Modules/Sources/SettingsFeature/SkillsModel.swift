import ChatDomain
public import Foundation
public import Observation
public import OpenWebUIKit

/// Settings › Skills and Server administration › Skills (#187, ADR 0096).
///
/// - **Settings › Skills** (everyone): *Yours*, the Skills this Account made (private unless
///   shared), to create, edit, enable or disable, delete, and add from a URL or a file; and
///   *From <host>*, Skills others shared with it, read-only.
/// - **Server administration › Skills** (admins): every Skill on the Server with its owner and
///   sharing; change who it's shared with, and create Skills that are shared from the start.
///
/// The Server gates every write (`B/routers/skills.py`); `permissions` mirrors those gates so
/// Theseus never offers what would fail. Its permission errors are 401s, which would also make the
/// app renew the Session, so the gates matter.
@MainActor
@Observable
public final class SkillsModel {
    public enum Mode: Sendable {
        case personal
        case administration
    }

    public let mode: Mode
    /// The Server's host, for "From chat.example.com" and "Everyone on chat.example.com".
    public let host: String
    public private(set) var user: SessionUser?
    public private(set) var skills: [Skill] = []
    public private(set) var groups: [SharingGroup] = []
    /// Admins only: what ordinary users may do by default (for the hint under *Yours*).
    public private(set) var userDefaults: SkillUserDefaults?
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public var errorMessage: String?
    /// The create/edit sheet.
    public var editor: SkillEditorDraft?
    /// The read-only sheet for a shared Skill.
    public var viewing: SkillDetail?
    /// The import review sheet.
    public var importSession: SkillImportSession?
    public private(set) var isWorking = false

    @ObservationIgnored let client: OpenWebUIClient
    @ObservationIgnored let download: @Sendable (URL) async throws -> (Data, String?)

    /// - Parameters:
    ///   - user: the session user if already known (it is reloaded).
    ///   - download: fetches a URL on the device (for users, who can't use the server's
    ///     admin-only `/load/url`); returns the bytes and the MIME type.
    public init(
        mode: Mode = .personal,
        client: OpenWebUIClient,
        host: String,
        user: SessionUser? = nil,
        download: (@Sendable (URL) async throws -> (Data, String?))? = nil
    ) {
        self.mode = mode
        self.client = client
        self.host = host
        self.user = user
        self.download = download ?? SkillsModel.urlSessionDownload
    }

    // MARK: Derived

    public var permissions: SkillPermissions {
        user.map(SkillPermissions.init(user:)) ?? .none
    }

    private var userID: String? { user?.id }

    private func scope(_ skill: Skill) -> SkillScope {
        SkillScope(skill, userID: userID, isAdmin: permissions.isAdmin)
    }

    /// This Account's Skills, A–Z.
    public var yours: [Skill] { skills.filter { scope($0) == .yours }.sorted(by: Self.byName) }

    /// Skills others shared with this Account, A–Z.
    public var shared: [Skill] { skills.filter { scope($0) == .shared }.sorted(by: Self.byName) }

    /// Every Skill on the Server (administration), A–Z.
    public var all: [Skill] { skills.sorted(by: Self.byName) }

    /// Whether *Yours* explains that creating isn't allowed.
    public var showsNoPermission: Bool { hasLoaded && user != nil && !permissions.canCreate }

    /// For admins: the hint that ordinary users can't create Skills yet.
    public var showsUserPermissionsHint: Bool {
        permissions.isAdmin && userDefaults?.usersCanCreate == false && userDefaults?.usersCanImport == false
    }

    public func canEdit(_ skill: Skill) -> Bool {
        permissions.canEdit(skill, userID: userID)
    }

    /// "Only you", "Everyone on host", "Legal, Design", "Specific people".
    public func sharingText(_ skill: Skill) -> String {
        switch skill.sharing {
        case .onlyOwner: skill.isOwned(by: userID) ? "Only you" : "Only \(ownerName(skill))"
        case .everyone: "Everyone on \(host)"
        case .groups(let ids): groupNames(ids)
        case .people: "Specific people"
        }
    }

    public func ownerName(_ skill: Skill) -> String {
        if skill.isOwned(by: userID) { return "You" }
        return skill.owner?.name.nonEmpty ?? skill.owner?.email ?? "Someone"
    }

    public func groupNames(_ ids: [String]) -> String {
        let names = ids.map { id in groups.first { $0.id == id }?.name ?? "" }
        if names.contains("") { return ids.count == 1 ? "1 group" : "\(ids.count) groups" }
        return names.formatted(.list(type: .and))
    }

    public static func displayName(_ skill: Skill) -> String {
        SkillMarkdown.displayName(skill.name)
    }

    private static func byName(_ a: Skill, _ b: Skill) -> Bool {
        displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
    }

    // MARK: Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        async let loadedUser = try? client.send(.sessionUser)
        do {
            skills = try await client.send(.skills)
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.message }
        }
        if let loadedUser = await loadedUser { user = loadedUser }
        hasLoaded = true
        // Group names for sharing; admins also read the users' default permissions (both GET).
        if skills.contains(where: { if case .groups = $0.sharing { true } else { false } }) || mode == .administration {
            if let loaded = try? await client.send(.sharingGroups) { groups = loaded }
        }
        if permissions.isAdmin, userDefaults == nil {
            userDefaults = try? await client.send(.skillUserDefaults)
        }
    }

    private func replace(_ skill: Skill) {
        // Write routes return the Skill without its owner (`SkillModel`); keep the one we had.
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            let old = skills[index]
            skills[index] = Skill(
                id: skill.id, name: skill.name, description: skill.description, isActive: skill.isActive,
                userID: skill.userID ?? old.userID, owner: skill.owner ?? old.owner, accessGrants: skill.accessGrants,
                versionID: skill.versionID, writeAccess: skill.writeAccess ?? old.writeAccess, updatedAt: skill.updatedAt
            )
        } else {
            skills.append(skill)
        }
    }

    private func run(_ work: () async throws(OpenWebUIError) -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            return true
        } catch {
            if !error.isCancellation { errorMessage = Self.message(for: error) }
            return false
        }
    }

    static func message(for error: OpenWebUIError) -> String {
        switch error {
        case .unauthorized(let detail) where detail == "401 Unauthorized":
            "Your Server admin hasn't allowed this."
        default:
            error.message
        }
    }

    // MARK: Yours

    /// Enables or disables `skill` (`/toggle`). A disabled Skill isn't offered to Chats.
    public func setEnabled(_ skill: Skill, _ enabled: Bool) async {
        guard skill.isActive != enabled, canEdit(skill) else { return }
        _ = await run { () throws(OpenWebUIError) in
            replace(try await client.send(.toggleSkill(id: skill.id)))
        }
    }

    /// Deletes `skill` with its version history.
    public func delete(_ skill: Skill) async {
        guard canEdit(skill) else { return }
        _ = await run { () throws(OpenWebUIError) in
            if try await client.send(.deleteSkill(id: skill.id)) {
                skills.removeAll { $0.id == skill.id }
            }
        }
    }

    // MARK: Editor

    /// Opens the editor for a new Skill. In administration it starts shared with everyone.
    public func startCreating() {
        guard permissions.canCreate else { return }
        editor = SkillEditorDraft(sharing: mode == .administration ? .everyone : .onlyOwner)
    }

    /// Loads `skill`'s instructions and opens the editor, or the read-only sheet when this
    /// Account can't edit it.
    public func open(_ skill: Skill) async {
        _ = await run { () throws(OpenWebUIError) in
            let detail = try await client.send(.skill(id: skill.id))
            if canEdit(skill) {
                editor = SkillEditorDraft(detail: detail)
            } else {
                viewing = detail
            }
        }
    }

    /// Creates or updates the Skill in `editor`; closes it on success.
    @discardableResult
    public func saveEditor() async -> Bool {
        guard let draft = editor, draft.canSave else { return false }
        let saved = await run { () throws(OpenWebUIError) in
            if let id = draft.existingID {
                let body = SkillDraft(id: id, name: draft.trimmedName, description: draft.trimmedDescription,
                                      content: draft.content, isActive: draft.isActive, accessGrants: nil)
                replace(try await client.send(.updateSkill(id: id, body)))
            } else {
                let grants = mode == .administration ? draft.sharing.grants() : []
                let body = SkillDraft(id: uniqueID(for: draft.trimmedName), name: draft.trimmedName,
                                      description: draft.trimmedDescription, content: draft.content,
                                      isActive: true, accessGrants: grants)
                var created = try await client.send(.createSkill(body))
                if created.owner == nil, let user {
                    created = Skill(id: created.id, name: created.name, description: created.description,
                                    isActive: created.isActive, userID: created.userID ?? user.id,
                                    owner: SkillOwner(id: user.id, name: user.name, email: user.email),
                                    accessGrants: created.accessGrants, versionID: created.versionID,
                                    writeAccess: true, updatedAt: created.updatedAt)
                }
                replace(created)
            }
        }
        if saved { editor = nil }
        return saved
    }

    /// An id not used by a Skill this Account can see (others' private ids can still clash; the
    /// server then says so).
    func uniqueID(for name: String) -> String {
        let base = SkillDraft.slug(for: name)
        let taken = Set(skills.map(\.id))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    // MARK: Sharing (administration)

    /// Shares `skill` with everyone, some groups, or only its owner (`/access/update`). Grants to
    /// single people made on the web stay.
    public func setSharing(_ skill: Skill, _ sharing: SkillSharing) async {
        guard canEdit(skill) else { return }
        let grants = sharing.grants(keeping: skill.accessGrants)
        _ = await run { () throws(OpenWebUIError) in
            replace(try await client.send(.updateSkillAccess(id: skill.id, grants: grants)))
        }
    }

    // MARK: Import

    /// Adds Skills from a link. Admins: the server downloads it (`/load/url`, GitHub folders too).
    /// Users: Theseus downloads it on the device, then imports the file, or, for a `SKILL.md`
    /// without import permission, opens it in the editor to review and save.
    public func addFromURL(_ text: String) async -> Bool {
        guard let url = SkillLink.url(from: text) else {
            errorMessage = "Enter a link that starts with https://."
            return false
        }
        if permissions.canLoadFromURLOnServer {
            var packages: [SkillPackage] = []
            let loaded = await run { () throws(OpenWebUIError) in
                packages = try await client.send(.loadSkills(fromURL: url))
            }
            guard loaded else { return false }
            guard !packages.isEmpty else {
                errorMessage = "No skills were found at that link."
                return false
            }
            return await preview([.packages(packages)], source: url.host() ?? url.absoluteString)
        }
        guard let fileURL = SkillLink.downloadURL(for: url) else {
            errorMessage = "Use a link to a SKILL.md, .skill or .zip file. Only Server admins can add a whole GitHub repository or folder."
            return false
        }
        let data: Data
        let mimeType: String?
        do {
            (data, mimeType) = try await download(fileURL)
        } catch {
            errorMessage = "Couldn't download the skill. Check that the link is public."
            return false
        }
        if mimeType == "text/html" {
            errorMessage = "The link opened a web page. Use a link to the SKILL.md file itself, or to a .skill or .zip download."
            return false
        }
        let file = SkillLink.importFile(data: data, mimeType: mimeType, url: fileURL)
        return await add(file, source: url.host() ?? url.absoluteString)
    }

    /// Adds Skills from a file picked in Files (`.skill`, `.zip`, `.md`, `.json`).
    public func addFromFile(_ file: SkillImportFile) async -> Bool {
        await add(file, source: file.filename)
    }

    private func add(_ file: SkillImportFile, source: String) async -> Bool {
        if permissions.canImportFiles {
            return await preview([file], source: source)
        }
        // Creating, but not importing: a Markdown file opens in the editor instead.
        if permissions.canCreate, file.isMarkdown, let content = String(data: file.data, encoding: .utf8) {
            editor = SkillEditorDraft(markdown: content, fallbackName: file.baseName)
            return true
        }
        errorMessage = permissions.canCreate
            ? "Your Server admin hasn't allowed importing skill files. You can add a SKILL.md file, or write the skill here."
            : "Your Server admin hasn't allowed creating skills."
        return false
    }

    private func preview(_ files: [SkillImportFile], source: String) async -> Bool {
        var items: [SkillImportPreview] = []
        let ok = await run { () throws(OpenWebUIError) in
            items = try await client.send(.previewSkillImport(files))
        }
        guard ok else { return false }
        guard !items.isEmpty else {
            errorMessage = "No skills were found in \(source)."
            return false
        }
        importSession = SkillImportSession(source: source, files: files, items: items)
        return true
    }

    /// Imports the Skills in `importSession` with the chosen decisions, then reloads.
    @discardableResult
    public func confirmImport() async -> Bool {
        guard let session = importSession, session.selectedCount > 0 else { return false }
        var results: [SkillImportResult] = []
        let ok = await run { () throws(OpenWebUIError) in
            results = try await client.send(.importSkills(session.files, decisions: session.decisions))
        }
        guard ok else { return false }
        if let skills = try? await client.send(.skills) { self.skills = skills }
        let failures = results.filter { $0.status == .error }
        if failures.isEmpty {
            importSession = nil
            return true
        }
        importSession?.results = results
        errorMessage = failures.compactMap(\.error).first ?? "Some skills couldn't be imported."
        return false
    }

    // MARK: Download

    private static let urlSessionDownload: @Sendable (URL) async throws -> (Data, String?) = { url in
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/markdown, application/zip, application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 50 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, http.mimeType)
    }
}

/// The create/edit sheet's fields.
public struct SkillEditorDraft: Sendable, Equatable, Identifiable {
    /// The Skill being edited; `nil` when creating.
    public let existingID: String?
    public var name: String
    public var description: String
    /// The `SKILL.md` instructions (Markdown).
    public var content: String
    public var isActive: Bool
    /// Who a new Skill is shared with (administration only).
    public var sharing: SkillSharing

    public var id: String { existingID ?? "new" }

    public init(
        existingID: String? = nil, name: String = "", description: String = "", content: String = "",
        isActive: Bool = true, sharing: SkillSharing = .onlyOwner
    ) {
        self.existingID = existingID
        self.name = name
        self.description = description
        self.content = content
        self.isActive = isActive
        self.sharing = sharing
    }

    init(detail: SkillDetail) {
        self.init(existingID: detail.skill.id, name: detail.skill.name, description: detail.skill.description ?? "",
                  content: detail.content, isActive: detail.skill.isActive, sharing: detail.skill.sharing)
    }

    /// A `SKILL.md` to review before saving: name and description from its front matter.
    init(markdown: String, fallbackName: String) {
        let fields = SkillMarkdown.frontMatter(markdown)
        self.init(name: SkillMarkdown.displayName(fields["name"] ?? fallbackName),
                  description: fields["description"] ?? "", content: markdown)
    }

    public var isNew: Bool { existingID == nil }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A name and some instructions.
    public var canSave: Bool {
        !trimmedName.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// An import under review: what the server found and what to do with each Skill.
public struct SkillImportSession: Sendable, Equatable, Identifiable {
    public let source: String
    public let files: [SkillImportFile]
    public let items: [SkillImportPreview]
    public var decisions: [SkillImportDecision]
    public var results: [SkillImportResult]?

    public var id: String { source + "\(items.count)" }

    init(source: String, files: [SkillImportFile], items: [SkillImportPreview]) {
        self.source = source
        self.files = files
        self.items = items
        decisions = items.map(\.defaultDecision)
    }

    public var selectedCount: Int { decisions.filter { $0.action != .skip }.count }

    /// The choices for item `index`: Add (unless it clashes), Add as a copy, Replace (when
    /// allowed) and Skip.
    public func actions(for index: Int) -> [SkillImportDecision.Action] {
        let item = items[index]
        var actions: [SkillImportDecision.Action] = item.isTaken ? [.copy] : [.create]
        if item.canReplace, item.expectedVersionID != nil { actions.append(.replace) }
        actions.append(.skip)
        return actions
    }

    public mutating func choose(_ action: SkillImportDecision.Action, for index: Int) {
        let item = items[index]
        decisions[index] = switch action {
        case .create: .create(item)
        case .copy: .copy(of: item)
        case .replace: .replace(item)
        case .skip: .skip(item)
        }
    }
}

/// Links people paste to add a Skill.
enum SkillLink {
    /// `https://…` (or `http://…`); a bare host gets `https://`.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    /// What the device downloads for `url`: GitHub `blob/…/SKILL.md` pages become their raw file;
    /// other GitHub repository and folder pages need the server (`nil`); other links as they are.
    static func downloadURL(for url: URL) -> URL? {
        guard url.host()?.lowercased() == "github.com" else { return url }
        let parts = url.path(percentEncoded: true).split(separator: "/").map(String.init)
        if parts.count >= 3, ["raw", "releases", "archive"].contains(parts[2]) { return url }
        guard parts.count >= 5, parts[2] == "blob" else { return nil }
        let rest = ([parts[0], parts[1], parts[3]] + parts[4...]).joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/" + rest)
    }

    /// The downloaded bytes as a file the import routes can parse (they go by the extension).
    static func importFile(data: Data, mimeType: String?, url: URL) -> SkillImportFile {
        let last = url.lastPathComponent
        let lower = last.lowercased()
        if data.starts(with: Data("PK".utf8)) {
            let name = lower.hasSuffix(".skill") || lower.hasSuffix(".zip") ? last : "skill.zip"
            return SkillImportFile(filename: name, contentType: "application/zip", data: data)
        }
        if mimeType == "application/json" || lower.hasSuffix(".json") {
            return SkillImportFile(filename: lower.hasSuffix(".json") ? last : "skills.json", contentType: "application/json", data: data)
        }
        return SkillImportFile(filename: lower.hasSuffix(".md") ? last : "SKILL.md", contentType: "text/markdown", data: data)
    }
}

extension SkillImportFile {
    var isMarkdown: Bool { filename.lowercased().hasSuffix(".md") }

    /// The file name without its extension ("SKILL.md" in a folder gives nothing useful).
    var baseName: String {
        let base = (filename as NSString).deletingPathExtension
        return base.uppercased() == "SKILL" ? "New skill" : base
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

extension SettingsModel {
    /// The Server's host as people know it ("chat.example.com").
    fileprivate var skillsHost: String {
        ServerDisplay.host(account.server.url, fallback: account.server.name)
    }

    /// Settings › Skills (#187).
    public func makeSkillsModel() -> SkillsModel {
        SkillsModel(client: client, host: skillsHost, user: user)
    }

    /// Server administration › Skills (#187), for the admin section (#186) to push.
    public func makeSkillsAdministrationModel() -> SkillsModel {
        SkillsModel(mode: .administration, client: client, host: skillsHost, user: user)
    }
}
