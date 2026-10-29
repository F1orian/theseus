public import AppIntents
public import Foundation
import Persistence

/// A saved Chat of the active Account, for Shortcuts and Siri ("Open chat"). Built from the
/// `SharedSnapshot` the app keeps current, so Incognito chats and other Accounts' Chats never
/// appear. Its `id` is the Server's Chat id, stable across launches and devices.
public struct ChatEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat", numericFormat: "\(placeholder: .int) chats")
    public static let defaultQuery = ChatEntityQuery()

    public let id: String
    @Property(title: "Title")
    public var title: String
    @Property(title: "Last updated")
    public var updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    init(_ chat: SharedSnapshot.Chat) {
        self.init(id: chat.id, title: chat.title, updatedAt: chat.updatedAt)
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// Finds the active Account's recent Chats in the shared snapshot.
public struct ChatEntityQuery: EntityStringQuery {
    /// Where the snapshot lives; the App Group by default.
    let store: SharedSnapshotStore?

    public init() {
        store = SharedSnapshotStore.appGroup()
    }

    init(store: SharedSnapshotStore?) {
        self.store = store
    }

    private var chats: [SharedSnapshot.Chat] {
        store?.read()?.recentChats ?? []
    }

    public func entities(for identifiers: [String]) async throws -> [ChatEntity] {
        let wanted = Set(identifiers)
        return chats.filter { wanted.contains($0.id) }.map(ChatEntity.init)
    }

    public func suggestedEntities() async throws -> [ChatEntity] {
        chats.prefix(10).map(ChatEntity.init)
    }

    public func entities(matching string: String) async throws -> [ChatEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return chats
            .filter { $0.title.localizedStandardContains(query) }
            .map(ChatEntity.init)
    }
}
