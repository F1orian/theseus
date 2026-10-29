public import Foundation
public import Observation
public import OpenWebUIKit

/// Settings > Shared links (SET-08): the Account's shared Chat snapshots, newest first and grouped
/// by when they were shared. Deleting a link keeps the Chat.
@MainActor
@Observable
public final class SharedLinksModel {
    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public let title: String
        public let links: [SharedChatLink]
        public var id: String { title }
    }

    /// The server's page size for `sharedChats(page:)`.
    static let pageSize = 60

    public private(set) var links: [SharedChatLink] = []
    public private(set) var state: LoadState = .idle
    public private(set) var hasMore = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let client: OpenWebUIClient
    @ObservationIgnored private var nextPage = 1

    public init(client: OpenWebUIClient) {
        self.client = client
    }

    public var sections: [Section] {
        Self.sections(for: links, now: .now, calendar: .current)
    }

    public func load() async {
        if links.isEmpty { state = .loading }
        do {
            let page = try await client.send(.sharedChats(page: 1))
            links = Self.sorted(page)
            nextPage = 2
            hasMore = page.count >= Self.pageSize
            state = .loaded
        } catch {
            state = links.isEmpty ? .failed(error.message) : .loaded
            if !links.isEmpty { errorMessage = error.message }
        }
    }

    public func loadMore() async {
        guard hasMore else { return }
        do {
            let page = try await client.send(.sharedChats(page: nextPage))
            let known = Set(links.map(\.id))
            links = Self.sorted(links + page.filter { !known.contains($0.id) })
            nextPage += 1
            hasMore = page.count >= Self.pageSize
        } catch {
            errorMessage = error.message
        }
    }

    /// Deletes the Shared link (the Chat stays). Returns `false` and sets `errorMessage` on failure.
    @discardableResult
    public func delete(_ link: SharedChatLink) async -> Bool {
        do {
            _ = try await client.send(.unshareChat(chatID: link.chatID))
            links.removeAll { $0.id == link.id }
            return true
        } catch {
            errorMessage = "Couldn't delete the link. \(error.message)"
            return false
        }
    }

    /// Deletes every Shared link of the Account.
    public func deleteAll() async {
        do {
            _ = try await client.send(.unshareAllChats)
            links = []
            hasMore = false
        } catch {
            errorMessage = "Couldn't delete your links. \(error.message)"
        }
    }

    /// The read-only snapshot others see.
    public func snapshot(for link: SharedChatLink) async throws(OpenWebUIError) -> SharedChatSnapshot {
        try await client.send(.sharedChatSnapshot(shareID: link.shareID))
    }

    /// The public web address of `link`.
    public func url(for link: SharedChatLink) -> URL {
        link.url(server: client.server)
    }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: Grouping

    private static func sorted(_ links: [SharedChatLink]) -> [SharedChatLink] {
        links.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Today, Yesterday, Previous 7 days, Previous 30 days, then one section per month.
    nonisolated static func sections(for links: [SharedChatLink], now: Date, calendar: Calendar) -> [Section] {
        let startOfToday = calendar.startOfDay(for: now)
        let monthFormat = Date.FormatStyle(locale: calendar.locale ?? .current, timeZone: calendar.timeZone).month(.wide).year()
        func bucket(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
            switch days {
            case ...0: return "Today"
            case 1: return "Yesterday"
            case 2...7: return "Previous 7 days"
            case 8...30: return "Previous 30 days"
            default: return date.formatted(monthFormat)
            }
        }
        var sections: [Section] = []
        for link in links.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let title = bucket(link.updatedAt)
            if let last = sections.last, last.title == title {
                sections[sections.count - 1] = Section(title: title, links: last.links + [link])
            } else {
                sections.append(Section(title: title, links: [link]))
            }
        }
        return sections
    }
}
