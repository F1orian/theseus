public import ChatDomain
public import Foundation
public import Observation
public import OpenWebUIKit

/// Which Projects the Projects list shows (PROJ-01, PROJ-08).
public enum ProjectsFilter: String, CaseIterable, Hashable, Sendable {
    /// Every Project that isn't archived.
    case all
    case starred
    case archived

    var title: String {
        switch self {
        case .all: "All projects"
        case .starred: "Starred"
        case .archived: "Archived"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .starred: "star"
        case .archived: "archivebox"
        }
    }
}

/// A Chat page cursor for one Project's Chats list.
public struct ProjectChatPage: Sendable, Equatable {
    public var chats: [ChatSummary] = []
    public var loadedPages = 0
    public var hasMore = false
    public var isLoading = false
}

/// A Knowledge file on its way to a Project (upload → server processing → attached).
public struct KnowledgeUpload: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case uploading
        case failed(String)
    }

    public let id: UUID
    public let projectID: String
    public let name: String
    public var state: State
}

/// The signed-in Account's Projects (server term: folders) and everything the Projects screens
/// do with them: list, create, star, archive, rename, delete, Instructions, Knowledge files and
/// the Chats inside a Project (PROJ-01…08).
///
/// The Projects list endpoint leaves out `meta` and `data`, so `refresh()` also loads every
/// Project's details (ADR 0020). Mutations are optimistic where the result is predictable and
/// roll back with an `errorMessage` when the Server refuses.
@MainActor
@Observable
public final class ProjectLibrary {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Every Project known locally, in no particular order (see `visibleProjects`).
    public private(set) var projects: [Project] = []
    public private(set) var state: LoadState = .idle
    /// The last failed action, for a dismissible notice. Cleared by `dismissError()`.
    public private(set) var errorMessage: String?
    /// A short confirmation toast ("Chat moved to Meal plan"). Cleared by `dismissNotice()`.
    public private(set) var notice: String?
    /// Account-level Capabilities: `projects` gates everything, `fileUpload` adding Knowledge,
    /// `deleteChat` deleting a Project together with its Chats.
    public var capabilities = Capabilities(enabled: [])
    /// The Server's `features.folder_max_file_count`; `nil` means no limit.
    public var maxKnowledgeFiles: Int?
    /// Called after deleting a Project changed which Chats exist, so the Chats library can refresh.
    public var onChatsChanged: (@MainActor () async -> Void)?

    private var chatPages: [String: ProjectChatPage] = [:]
    private var pendingUploads: [KnowledgeUpload] = []

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let pollInterval: Duration
    /// How long to wait for the Server to process an upload before giving up.
    @ObservationIgnored private let processingTimeout: Duration

    /// Each Project's cover from The Collection, chosen on this device (BRAND-04).
    public let covers: ProjectCovers

    /// - Parameter covers: The Account's cover choices; in memory when `nil`.
    public init(
        client: OpenWebUIClient,
        covers: ProjectCovers? = nil,
        pollInterval: Duration = .seconds(1),
        processingTimeout: Duration = .seconds(180)
    ) {
        self.client = client
        self.covers = covers ?? ProjectCovers()
        self.pollInterval = pollInterval
        self.processingTimeout = processingTimeout
    }

    public var isAvailable: Bool { capabilities.contains(.projects) }
    public var canDeleteChats: Bool { capabilities.contains(.deleteChat) }

    public func project(id: String) -> Project? {
        projects.first { $0.id == id }
    }

    /// The Projects for `filter`, starred first and then most recently updated, narrowed to names
    /// and descriptions matching every word of `query`.
    public func visibleProjects(filter: ProjectsFilter, query: String) -> [Project] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return projects
            .filter { project in
                switch filter {
                case .all: !project.isArchived
                case .starred: project.isStarred && !project.isArchived
                case .archived: project.isArchived
                }
            }
            .filter { project in
                terms.allSatisfy { term in
                    project.name.localizedStandardContains(term)
                        || project.metadata.description.localizedStandardContains(term)
                }
            }
            .sorted { lhs, rhs in
                if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
                return (lhs.updatedAt, lhs.id) > (rhs.updatedAt, rhs.id)
            }
    }

    public func dismissError() { errorMessage = nil }
    public func dismissNotice() { notice = nil }

    /// Reads `features.folder_max_file_count` (a number, a numeric string, or empty for no limit).
    public static func maxFileCount(from features: ServerFeatures) -> Int? {
        switch features.raw["folder_max_file_count"] {
        case .number(let value): value > 0 ? Int(value) : nil
        case .string(let value): Int(value).flatMap { $0 > 0 ? $0 : nil }
        default: nil
        }
    }

    // MARK: Loading

    /// Loads the Projects and then each Project's details.
    public func refresh() async {
        guard isAvailable else { return }
        state = .loading
        let rows: [Project]
        do {
            rows = try await client.send(.projects)
        } catch {
            state = .failed(error.message)
            return
        }
        // Keep known details while the fresh ones load, so filters don't flicker.
        let known = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projects = rows.map { row in
            guard var detailed = known[row.id], detailed.hasDetails else { return row }
            detailed.name = row.name
            detailed.updatedAt = row.updatedAt
            return detailed
        }
        let client = client
        let details = await withTaskGroup(of: Project?.self) { group in
            for row in rows {
                group.addTask { try? await client.send(.projectDetails(id: row.id)) }
            }
            var loaded: [Project] = []
            for await project in group {
                if let project { loaded.append(project) }
            }
            return loaded
        }
        for project in details {
            replace(project)
        }
        state = .loaded
    }

    /// Reloads one Project's details (e.g. when its detail screen appears).
    public func loadDetails(_ id: String) async {
        guard isAvailable else { return }
        do {
            replace(try await client.send(.projectDetails(id: id)))
        } catch {
            if !error.isCancellation { errorMessage = error.message }
        }
    }

    // MARK: Create (PROJ-02)

    /// Creates a Project. Returns `nil` (with an `errorMessage` when the Server refused) if it wasn't created.
    @discardableResult
    public func create(name: String, description: String) async -> Project? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !name.isEmpty else { return nil }
        do {
            let project = try await client.send(.createProject(name: name, description: description))
            replace(project)
            return project
        } catch {
            errorMessage = Self.message(for: error, name: name)
            return nil
        }
    }

    // MARK: Star, archive, rename (PROJ-07, PROJ-08)

    public func setStarred(_ id: String, _ isStarred: Bool) async {
        await updateMetadata(id) { $0.isStarred = isStarred }
    }

    public func setArchived(_ id: String, _ isArchived: Bool) async {
        await updateMetadata(id) { $0.isArchived = isArchived }
    }

    /// Renames a Project. Blank or unchanged names are ignored.
    public func rename(_ id: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = project(id: id), !name.isEmpty, name != original.name else { return }
        var renamed = original
        renamed.name = name
        replace(renamed)
        do {
            merge(try await client.send(.updateProject(id: id, ProjectUpdate(name: name))), into: renamed)
        } catch {
            replace(original)
            errorMessage = Self.message(for: error, name: name)
        }
    }

    // MARK: Instructions (PROJ-04)

    /// Saves the Project Instructions (server term: folder system prompt). Returns `false` on failure.
    @discardableResult
    public func updateInstructions(_ id: String, to instructions: String) async -> Bool {
        guard let original = project(id: id) else { return false }
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            merge(try await client.send(.updateProject(id: id, ProjectUpdate(instructions: instructions))), into: original)
            return true
        } catch {
            errorMessage = error.message
            return false
        }
    }

    // MARK: Delete (PROJ-08)

    /// Deletes a Project. With `deleteChats` its Chats are deleted too (needs the `deleteChat`
    /// Capability); otherwise the Server moves them out of the Project.
    @discardableResult
    public func delete(_ id: String, deleteChats: Bool) async -> Bool {
        guard let original = project(id: id), !deleteChats || canDeleteChats else { return false }
        projects.removeAll { $0.id == id }
        do {
            _ = try await client.send(.deleteProject(id: id, deleteChats: deleteChats))
            chatPages[id] = nil
            covers.forget(id)
            await onChatsChanged?()
            return true
        } catch {
            replace(original)
            errorMessage = error.message
            return false
        }
    }

    // MARK: Chats in a Project (PROJ-03, PROJ-06)

    public func chats(in projectID: String) -> [ChatSummary] {
        chatPages[projectID]?.chats ?? []
    }

    public func chatPage(for projectID: String) -> ProjectChatPage {
        chatPages[projectID] ?? ProjectChatPage()
    }

    /// Loads the first page of a Project's Chats.
    public func loadChats(in projectID: String) async {
        var page = chatPage(for: projectID)
        guard !page.isLoading else { return }
        page.isLoading = true
        chatPages[projectID] = page
        do {
            let chats = try await client.send(.projectChats(projectID: projectID, page: 1))
            chatPages[projectID] = ProjectChatPage(
                chats: chats,
                loadedPages: 1,
                hasMore: chats.count >= Endpoint<[ChatSummary]>.projectChatsPageSize
            )
        } catch {
            page.isLoading = false
            chatPages[projectID] = page
            if !error.isCancellation { errorMessage = error.message }
        }
    }

    /// Loads the next page of a Project's Chats (infinite scroll).
    public func loadMoreChats(in projectID: String) async {
        var page = chatPage(for: projectID)
        guard page.hasMore, !page.isLoading else { return }
        page.isLoading = true
        chatPages[projectID] = page
        do {
            let chats = try await client.send(.projectChats(projectID: projectID, page: page.loadedPages + 1))
            let known = Set(page.chats.map(\.id))
            page.chats += chats.filter { !known.contains($0.id) }
            page.loadedPages += 1
            page.hasMore = chats.count >= Endpoint<[ChatSummary]>.projectChatsPageSize
        } catch {
            if !error.isCancellation { errorMessage = error.message }
        }
        page.isLoading = false
        chatPages[projectID] = page
    }

    /// Moves a Chat into a Project (or out of every Project with `nil`) and confirms it with a
    /// `notice`. Returns the moved Chat, keeping what the local copy knew (e.g. Starred).
    @discardableResult
    public func moveChat(_ chat: ChatSummary, to projectID: String?) async -> ChatSummary? {
        do {
            let server = try await client.send(.moveChat(id: chat.id, toProject: projectID))
            var moved = chat
            moved.projectID = server.projectID
            moved.title = server.title
            moved.updatedAt = max(chat.updatedAt, server.updatedAt)
            for id in chatPages.keys {
                chatPages[id]?.chats.removeAll { $0.id == chat.id }
            }
            if let projectID {
                chatPages[projectID, default: ProjectChatPage()].chats.insert(moved, at: 0)
                notice = "Chat moved to \(project(id: projectID)?.name ?? "project")"
            } else {
                notice = "Chat removed from project"
            }
            return moved
        } catch {
            errorMessage = error.message
            return nil
        }
    }

    // MARK: Knowledge (PROJ-05)

    /// Whether the Account may add Knowledge to this Project now (permission and Server file limit).
    public func canAddKnowledge(to projectID: String) -> Bool {
        guard isAvailable, capabilities.contains(.fileUpload) else { return false }
        guard let limit = maxKnowledgeFiles else { return true }
        let count = (project(id: projectID)?.knowledge.count ?? 0) + uploads(for: projectID).count { $0.state == .uploading }
        return count < limit
    }

    /// Uploads and processes in-flight or failed for `projectID`.
    public func uploads(for projectID: String) -> [KnowledgeUpload] {
        pendingUploads.filter { $0.projectID == projectID }
    }

    public func dismissUpload(_ id: UUID) {
        pendingUploads.removeAll { $0.id == id }
    }

    /// "Add Text": stores the text as a Markdown file and attaches it.
    @discardableResult
    public func addText(to projectID: String, title: String, content: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !content.isEmpty else { return false }
        let markdown = "# \(title)\n\n\(content)"
        return await addFile(to: projectID, filename: "\(title).md", contentType: "text/markdown", data: Data(markdown.utf8))
    }

    /// Uploads a file, waits for the Server to process it and adds it to the Project's Knowledge.
    @discardableResult
    public func addFile(to projectID: String, filename: String, contentType: String, data: Data) async -> Bool {
        guard canAddKnowledge(to: projectID) else { return false }
        let upload = KnowledgeUpload(id: UUID(), projectID: projectID, name: filename, state: .uploading)
        pendingUploads.append(upload)
        do {
            let uploaded = try await client.send(.uploadFile(filename: filename, contentType: contentType, data: data))
            try await waitUntilProcessed(uploaded.id)
            let processed = try await client.send(.fileDetails(id: uploaded.id))
            // Append to the Server's current list so concurrent changes aren't lost.
            let current = try await client.send(.projectDetails(id: projectID))
            var knowledge = current.knowledge.filter { $0.id != processed.id }
            knowledge.append(KnowledgeFile(uploaded: processed))
            replace(try await client.send(.updateProject(id: projectID, ProjectUpdate(knowledge: knowledge))))
            pendingUploads.removeAll { $0.id == upload.id }
            return true
        } catch {
            let message = (error as? UploadError)?.message ?? (error as? OpenWebUIError)?.message ?? "The file couldn't be added."
            if let index = pendingUploads.firstIndex(where: { $0.id == upload.id }) {
                pendingUploads[index].state = .failed(message)
            }
            return false
        }
    }

    /// Removes a file from the Project's Knowledge. The file itself stays on the Server.
    public func removeKnowledge(_ fileID: String, from projectID: String) async {
        guard let original = project(id: projectID) else { return }
        var trimmed = original
        trimmed.knowledge.removeAll { $0.id == fileID }
        replace(trimmed)
        do {
            merge(try await client.send(.updateProject(id: projectID, ProjectUpdate(knowledge: trimmed.knowledge))), into: trimmed)
        } catch {
            replace(original)
            errorMessage = error.message
        }
    }

    // MARK: Private

    private enum UploadError: Error {
        case processing(String?)
        case timedOut

        var message: String {
            switch self {
            case .processing(let reason): reason ?? "The server couldn't read this file."
            case .timedOut: "The server took too long to process this file."
            }
        }
    }

    private func waitUntilProcessed(_ fileID: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: processingTimeout)
        while true {
            switch try await client.send(.fileProcessingStatus(id: fileID)) {
            case .completed: return
            case .failed(let reason): throw UploadError.processing(reason)
            case .pending:
                guard ContinuousClock.now < deadline else { throw UploadError.timedOut }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Changes `meta.theseus` (always written whole, ADR 0020), optimistically.
    private func updateMetadata(_ id: String, _ change: (inout ProjectMetadata) -> Void) async {
        if project(id: id)?.hasDetails == false { await loadDetails(id) }
        guard let original = project(id: id), original.hasDetails else { return }
        var updated = original
        change(&updated.metadata)
        guard updated != original else { return }
        replace(updated)
        do {
            merge(try await client.send(.updateProject(id: id, ProjectUpdate(metadata: updated.metadata))), into: updated)
        } catch {
            replace(original)
            errorMessage = error.message
        }
    }

    /// Applies a Server response, falling back to the local copy if the response lacks details.
    private func merge(_ server: Project, into local: Project) {
        replace(server.hasDetails ? server : local)
    }

    private func replace(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    private static func message(for error: OpenWebUIError, name: String) -> String {
        if case .server(400, let detail?) = error, detail.localizedCaseInsensitiveContains("already exists") {
            return "A project named “\(name)” already exists."
        }
        return error.message
    }
}
