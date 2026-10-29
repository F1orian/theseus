public import ChatDomain
public import Foundation

/// What the app tells its extensions about the active Account (ADR 0100): who is signed in, which
/// Chat actions the Server allows, and the most recent saved Chats. Written by the app whenever
/// they change; read by the widgets, the Open Chat intent and the Share extension.
///
/// Incognito chats never appear: they're never in the Chats library in the first place
/// (ADR 0070), and when the Server enforces them `recentChats` stays empty.
public struct SharedSnapshot: Codable, Sendable, Equatable {
    /// A saved Chat, as the widget and Shortcuts list it.
    public struct Chat: Codable, Sendable, Hashable, Identifiable {
        public let id: String
        public var title: String
        public var updatedAt: Date

        public init(id: String, title: String, updatedAt: Date) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
        }
    }

    /// The Chat actions the active Account can take, so extensions hide what the Server can't
    /// back (ADR 0006).
    public struct Actions: Codable, Sendable, Equatable {
        public var voiceMode: Bool
        public var dictation: Bool
        public var photos: Bool
        public var incognitoChat: Bool

        public init(voiceMode: Bool = false, dictation: Bool = false, photos: Bool = false, incognitoChat: Bool = false) {
            self.voiceMode = voiceMode
            self.dictation = dictation
            self.photos = photos
            self.incognitoChat = incognitoChat
        }
    }

    /// How many recent Chats extensions get.
    public static let recentChatLimit = 50

    /// The active Account's key (`Account.id`).
    public var accountID: String
    public var accountName: String
    /// The Server's host, e.g. "chat.example.com".
    public var serverHost: String
    /// `serverHost` as the UI may show it (the Server alias when one is set, see `ServerDisplay`).
    public var displayServerHost: String { ServerDisplay.host(serverHost) }
    public var actions: Actions
    /// Newest first, never archived, at most `recentChatLimit`.
    public var recentChats: [Chat]
    /// Whether Theseus Pro is unlocked, which the widgets and the Share extension need (ADR 0173).
    /// Snapshots written before Pro existed decode as unlocked, so nothing locks until the app
    /// writes a fresh one.
    public var isProUnlocked: Bool

    public init(
        accountID: String,
        accountName: String,
        serverHost: String,
        actions: Actions,
        recentChats: [Chat],
        isProUnlocked: Bool = true
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.serverHost = serverHost
        self.actions = actions
        self.recentChats = recentChats
        self.isProUnlocked = isProUnlocked
    }

    private enum CodingKeys: String, CodingKey {
        case accountID, accountName, serverHost, actions, recentChats, isProUnlocked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        accountName = try container.decode(String.self, forKey: .accountName)
        serverHost = try container.decode(String.self, forKey: .serverHost)
        actions = try container.decode(Actions.self, forKey: .actions)
        recentChats = try container.decode([Chat].self, forKey: .recentChats)
        isProUnlocked = try container.decodeIfPresent(Bool.self, forKey: .isProUnlocked) ?? true
    }

    /// A snapshot of `chats` (any order): archived ones are dropped, the rest sorted newest first.
    /// Pass `savesChats: false` when the Server enforces Incognito chats, so no history leaks out.
    public init(
        accountID: String,
        accountName: String,
        serverHost: String,
        actions: Actions,
        chats: [ChatSummary],
        savesChats: Bool = true,
        isProUnlocked: Bool = true
    ) {
        let recent = savesChats
            ? chats
                .filter { !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.recentChatLimit)
                .map { Chat(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            : []
        self.init(
            accountID: accountID, accountName: accountName, serverHost: serverHost, actions: actions,
            recentChats: recent, isProUnlocked: isProUnlocked
        )
    }
}

/// Reads and writes the `SharedSnapshot` in a `SharedContainer`.
public struct SharedSnapshotStore: Sendable {
    public let container: SharedContainer

    public init(container: SharedContainer) {
        self.container = container
    }

    /// The App Group's store, or `nil` without the entitlement.
    public static func appGroup() -> SharedSnapshotStore? {
        SharedContainer.appGroup().map(SharedSnapshotStore.init(container:))
    }

    /// The last snapshot the app wrote, or `nil` when signed out (or never written).
    public func read() -> SharedSnapshot? {
        guard let data = try? Data(contentsOf: container.snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SharedSnapshot.self, from: data)
    }

    public func write(_ snapshot: SharedSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: container.directory, withIntermediateDirectories: true)
        // Widgets refresh while the device is locked: readable after the first unlock.
        try data.write(to: container.snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Forgets the snapshot (sign-out, removing the last Account).
    public func clear() {
        try? FileManager.default.removeItem(at: container.snapshotURL)
    }
}
