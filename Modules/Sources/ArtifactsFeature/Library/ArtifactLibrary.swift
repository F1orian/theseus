public import ChatDomain
public import Foundation
public import Observation
public import OpenWebUIKit

/// The Account's Artifacts across all Chats (ART-04): a local index, since Open WebUI keeps no
/// Artifact list. It's rebuilt from the Chat export (`GET /api/v1/chats/all`) when it's missing
/// or stale and on pull to refresh, and kept per Account on disk so the screen opens instantly.
@MainActor
@Observable
public final class ArtifactLibrary {
    public enum State: Equatable, Sendable {
        case idle
        /// Reading the Chats; `items` shows the previous index meanwhile.
        case indexing
        case ready
        case failed(String)
    }

    /// One Artifact (its newest version) in the library grid.
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { artifact.id }
        public let chatID: String
        public let chatTitle: String
        public let artifact: Artifact
        public let versionCount: Int
        public let date: Date
    }

    /// Newest first.
    public private(set) var items: [Item] = []
    public private(set) var state: State = .idle
    /// When the index was last rebuilt from the Server.
    public private(set) var indexedAt: Date?

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private let storeURL: URL?
    @ObservationIgnored private var index = Index()
    @ObservationIgnored private var loadedFromDisk = false
    /// Chats per page of `GET /api/v1/chats/`.
    static let chatListPageSize = 60
    /// How old the index may get before opening the library rebuilds it.
    @ObservationIgnored var staleAfter: TimeInterval = 6 * 60 * 60

    /// - Parameters:
    ///   - accountID: Keeps each Account's index apart on disk.
    ///   - directory: Where indexes live; `nil` keeps it in memory only.
    public init(client: OpenWebUIClient, accountID: String, directory: URL? = ArtifactLibrary.defaultDirectory) {
        self.client = client
        let safe = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        storeURL = directory?.appending(path: "\(safe).json")
    }

    /// Application Support/Theseus/Artifacts.
    public nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Theseus/Artifacts", directoryHint: .isDirectory)
    }

    /// Shows the saved index, then rebuilds it when it's missing or stale, or else catches up
    /// with the Chats that changed since.
    public func open() async {
        loadFromDiskIfNeeded()
        if let indexedAt = index.indexedAt, Date().timeIntervalSince(indexedAt) < staleAfter {
            await catchUp()
        } else {
            await rebuild()
        }
    }

    /// Re-reads the Chats changed since the last update (from the newest page of the Chat list).
    func catchUp() async {
        guard state != .indexing, let since = index.updatedAt ?? index.indexedAt else { return }
        state = .indexing
        do {
            let recent = try await client.send(.chats(page: 1, includeStarred: true, includeProjects: true))
            // Chats that should be on this page but aren't were deleted (or archived) since.
            let listed = Set(recent.map(\.id))
            let isWholeList = recent.count < Self.chatListPageSize
            let oldest = recent.map(\.updatedAt).min() ?? .distantFuture
            for (chatID, entry) in index.chats where !listed.contains(chatID) && (isWholeList || entry.updatedAt >= oldest) {
                index.chats[chatID] = nil
            }
            for summary in recent where summary.updatedAt > since {
                let chat = try await client.send(.chat(id: summary.id)).chat
                let entry = Self.entry(for: chat)
                index.chats[chat.id] = entry.artifacts.isEmpty ? nil : entry
            }
            index.updatedAt = Date()
            publish()
            save()
            state = .ready
        } catch {
            state = .failed(error.message)
        }
    }

    /// Re-reads every Chat from the Server.
    public func rebuild() async {
        guard state != .indexing else { return }
        loadFromDiskIfNeeded()
        state = .indexing
        do {
            let chats = try await client.exportChats(keepingLinesWhere: Self.mayHoldArtifacts)
            var rebuilt = Index(indexedAt: Date())
            for chat in chats {
                let entry = Self.entry(for: chat)
                if !entry.artifacts.isEmpty { rebuilt.chats[chat.id] = entry }
            }
            index = rebuilt
            publish()
            save()
            state = .ready
        } catch {
            state = .failed(error.message)
        }
    }

    /// Updates one Chat's Artifacts (e.g. after it was loaded or changed in the app).
    public func record(_ chat: Chat) {
        loadFromDiskIfNeeded()
        let entry = Self.entry(for: chat)
        index.chats[chat.id] = entry.artifacts.isEmpty ? nil : entry
        publish()
        save()
    }

    /// Forgets a deleted Chat's Artifacts.
    public func remove(chatID: String) {
        loadFromDiskIfNeeded()
        guard index.chats.removeValue(forKey: chatID) != nil else { return }
        publish()
        save()
    }

    /// All versions in one Chat, for the viewer's version picker.
    public func catalog(chatID: String) -> ArtifactCatalog {
        ArtifactCatalog(artifacts: index.chats[chatID]?.artifacts ?? [])
    }

    // MARK: Index

    struct Entry: Codable, Sendable {
        var title: String
        var updatedAt: Date
        /// Every Artifact on the Chat's active path, with the date of its Response.
        var artifacts: [Artifact]
        var dates: [String: Date]
    }

    struct Index: Codable, Sendable {
        /// Bumped when detection changes, so indexes built by older rules are rebuilt (#180).
        static let currentVersion = 2
        var version = Index.currentVersion
        /// The last full rebuild from the export.
        var indexedAt: Date?
        /// The last catch-up with recently changed Chats.
        var updatedAt: Date?
        var chats: [String: Entry] = [:]
    }

    /// A cheap test on the raw export line: fenced code, tool embeds, or Claude `artifacts` calls
    /// (imported Chats, where the quotes of `name="artifacts"` are JSON-escaped).
    nonisolated static func mayHoldArtifacts(_ line: String) -> Bool {
        line.contains("```") || line.contains("~~~") || line.contains("\"embeds\": [\"") || line.contains("\"embeds\":[\"")
            || line.contains(#"name=\"artifacts\""#)
    }

    static func entry(for chat: Chat) -> Entry {
        let catalog = ArtifactCatalog(responses: ArtifactCatalog.responses(thread: chat.tree.activePath))
        return Entry(title: chat.title, updatedAt: chat.updatedAt, artifacts: catalog.artifacts, dates: catalog.dates)
    }

    private func publish() {
        indexedAt = index.indexedAt
        items = index.chats.flatMap { chatID, entry -> [Item] in
            let catalog = ArtifactCatalog(artifacts: entry.artifacts)
            return catalog.latestVersions.map { artifact in
                Item(
                    chatID: chatID,
                    chatTitle: entry.title,
                    artifact: artifact,
                    versionCount: catalog.versions(of: artifact).count,
                    date: entry.dates[artifact.messageID] ?? entry.updatedAt
                )
            }
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode(Index.self, from: data),
              saved.version == Index.currentVersion
        else { return }
        index = saved
        publish()
        if state == .idle { state = .ready }
    }

    private func save() {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            try JSONEncoder().encode(index).write(to: storeURL, options: options)
        } catch {
            // The index is a cache; it's rebuilt next time.
        }
    }
}
