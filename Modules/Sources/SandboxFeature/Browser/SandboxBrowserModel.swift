public import Foundation
public import Observation
public import OpenWebUIKit

/// A Chat's sandbox files (OT-04): browse the terminal's workspace from the Chat's session,
/// preview files and download folders as ZIPs. Read-only: nothing is moved or deleted here.
@MainActor
@Observable
public final class SandboxBrowserModel {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public let terminalID: String
    public let chatID: String
    public let files: SandboxFiles

    /// The browsing root (`root.path`, else home, else the working directory).
    public private(set) var root: String?
    public private(set) var rootLabel = "Sandbox"
    public private(set) var state: LoadState = .idle
    /// Listed folders by absolute path.
    public private(set) var directories: [String: SandboxDirectory] = [:]
    public private(set) var folderErrors: [String: String] = [:]
    public private(set) var searchResults: [SandboxSearchResult] = []
    public private(set) var isSearching = false
    /// Shown once per Account: the sandbox may be shared with every user of the Server.
    public private(set) var showsSharedNotice: Bool

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let noticeKey: String
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(client: OpenWebUIClient, terminalID: String, chatID: String, files: SandboxFiles, accountKey: String, defaults: UserDefaults = .standard) {
        self.client = client
        self.terminalID = terminalID
        self.chatID = chatID
        self.files = files
        self.defaults = defaults
        noticeKey = "theseus.sandbox.\(accountKey).sharedNoticeSeen"
        showsSharedNotice = !defaults.bool(forKey: noticeKey)
    }

    public func dismissSharedNotice() {
        showsSharedNotice = false
        defaults.set(true, forKey: noticeKey)
    }

    /// Finds the root and lists it.
    public func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let location = try await client.send(.sandboxLocation(terminalID: terminalID, chatID: chatID))
            let root = location.rootPath ?? location.home ?? location.cwd
            self.root = root
            rootLabel = location.rootLabel ?? "Sandbox"
            directories[root] = try await client.send(.sandboxDirectory(terminalID: terminalID, chatID: chatID, path: root))
            state = .loaded
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Lists `path` (again).
    public func open(_ path: String) async {
        do {
            directories[path] = try await client.send(.sandboxDirectory(terminalID: terminalID, chatID: chatID, path: path))
            folderErrors[path] = nil
        } catch {
            folderErrors[path] = Self.describe(error)
        }
    }

    /// Entries of `path`: folders first, then files, each A–Z; hidden files last.
    public func entries(of path: String) -> [SandboxDirectory.Entry]? {
        directories[path]?.entries.sorted { lhs, rhs in
            let left = (lhs.name.hasPrefix(".") ? 1 : 0, lhs.isDirectory ? 0 : 1, lhs.name.lowercased())
            let right = (rhs.name.hasPrefix(".") ? 1 : 0, rhs.isDirectory ? 0 : 1, rhs.name.lowercased())
            return left < right
        }
    }

    public func path(of entry: SandboxDirectory.Entry, in folder: String) -> String {
        folder.hasSuffix("/") ? folder + entry.name : folder + "/" + entry.name
    }

    /// The title for a folder: the root's label, else its name.
    public func title(of path: String) -> String {
        path == root ? rootLabel : (path as NSString).lastPathComponent
    }

    /// Searches file names under `path` (debounced).
    public func search(_ query: String, in path: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let results = (try? await client.send(.sandboxSearch(terminalID: terminalID, chatID: chatID, query: trimmed, path: path))) ?? []
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }

    // MARK: Downloads

    public func download(_ path: String) async throws(SandboxFiles.Failure) -> URL {
        try await files.download(path: path, terminalID: terminalID, chatID: chatID)
    }

    public func downloadArchive(of folder: String) async throws(SandboxFiles.Failure) -> URL {
        let name = (folder as NSString).lastPathComponent
        return try await files.downloadArchive(paths: [folder], name: name.isEmpty ? "sandbox" : name, terminalID: terminalID, chatID: chatID)
    }

    private static func describe(_ error: OpenWebUIError) -> String {
        switch error {
        case .forbidden: "This Server's sandbox isn't available to your account."
        case .server(status: 404, _): "This folder no longer exists."
        default: error.message
        }
    }
}
