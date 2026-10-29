public import Foundation

/// Content shared into Theseus from other apps (PLAT-04), waiting in the App Group until the app
/// turns it into a new Chat (ADR 0100). The Share extension `add`s an entry; the app reads it,
/// fills the new Chat's composer and `remove`s it.
public struct ShareInbox: Sendable {
    /// One shared thing, as the Share extension hands it over.
    public enum Item: Sendable, Equatable {
        case text(String)
        case url(URL)
        /// A photo or document: its bytes, file name and MIME type (if known).
        case file(Data, filename: String, contentType: String?)
    }

    /// One share: everything the user shared at once, plus what they typed.
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public struct StoredItem: Codable, Sendable, Equatable {
            public enum Kind: String, Codable, Sendable {
                case text
                case url
                case image
                case file
            }

            public var kind: Kind
            /// The text, or the URL's absolute string.
            public var text: String?
            public var filename: String?
            public var contentType: String?
            /// The file's name inside the entry's folder.
            var storedName: String?
        }

        public let id: UUID
        public let createdAt: Date
        /// The Account that was active when the user shared (`Account.id`), if any.
        public var accountID: String?
        /// What the user typed in the share sheet.
        public var note: String
        public var items: [StoredItem]

        /// The note, the shared text and the URLs, as one prompt (blank lines between them).
        public var prompt: String {
            let parts = [note] + items.compactMap { $0.kind == .text || $0.kind == .url ? $0.text : nil }
            return parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        /// The photos and documents.
        public var files: [StoredItem] {
            items.filter { $0.kind == .image || $0.kind == .file }
        }
    }

    /// Entries older than this are dropped unread.
    public static let lifetime: TimeInterval = 7 * 24 * 3600

    public let container: SharedContainer

    public init(container: SharedContainer) {
        self.container = container
    }

    /// The App Group's inbox, or `nil` without the entitlement.
    public static func appGroup() -> ShareInbox? {
        SharedContainer.appGroup().map(ShareInbox.init(container:))
    }

    /// Stores a share and returns its entry. Images are recognised by their MIME type.
    @discardableResult
    public func add(_ items: [Item], note: String = "", accountID: String? = nil, now: Date = Date()) throws -> Entry {
        let id = UUID()
        let folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored: [Entry.StoredItem] = []
        for (index, item) in items.enumerated() {
            switch item {
            case .text(let text):
                stored.append(.init(kind: .text, text: text))
            case .url(let url):
                stored.append(.init(kind: .url, text: url.absoluteString))
            case .file(let data, let filename, let contentType):
                let storedName = "\(index)-\(Self.safeName(filename))"
                try data.write(to: folder.appending(path: storedName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let isImage = contentType?.hasPrefix("image/") == true
                stored.append(.init(kind: isImage ? .image : .file, filename: filename, contentType: contentType, storedName: storedName))
            }
        }
        // Whole seconds, so the entry reads back exactly as written.
        let createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded())
        let entry = Entry(id: id, createdAt: createdAt, accountID: accountID, note: note, items: stored)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entry).write(to: folder.appending(path: "entry.json"), options: .atomic)
        return entry
    }

    /// The entry with `id`, if it's still waiting.
    public func entry(id: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: folder(for: id).appending(path: "entry.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Entry.self, from: data)
    }

    /// Every waiting entry, oldest first.
    public func pending() -> [Entry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: container.inboxDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap(entry(id:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The bytes of a shared photo or document.
    public func data(for item: Entry.StoredItem, in entry: Entry) -> Data? {
        guard let storedName = item.storedName else { return nil }
        return try? Data(contentsOf: folder(for: entry.id).appending(path: storedName))
    }

    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Drops entries nobody opened within `lifetime`.
    public func removeExpired(now: Date = Date()) {
        for entry in pending() where now.timeIntervalSince(entry.createdAt) > Self.lifetime {
            remove(id: entry.id)
        }
    }

    private func folder(for id: UUID) -> URL {
        container.inboxDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// A file-system-safe version of a shared file's name.
    static func safeName(_ filename: String) -> String {
        let cleaned = filename.map { $0 == "/" || $0 == ":" ? "_" : $0 }
        return cleaned.isEmpty ? "file" : String(cleaned)
    }
}
