public import Foundation
public import Observation
public import OpenWebUIKit

/// The Share sheet's state for one Chat (MSG-08, ADR 0050). "Only you" means the Chat has no
/// link; "Anyone with the link" means a snapshot link every signed-in user of the Server can open.
/// "Share link" re-snapshots the Chat first, so the link shows it as it is now.
@MainActor
@Observable
public final class ChatLinkSharing {
    public enum Access: Sendable, Equatable {
        case onlyYou
        case anyoneWithLink
    }

    public enum LoadState: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public let chatID: String
    public let title: String
    public private(set) var access: Access = .onlyYou
    public private(set) var state: LoadState = .loading
    /// A request is running (changing access or refreshing the link).
    public private(set) var isWorking = false
    /// The last failed change, shown under the options.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let client: OpenWebUIClient

    /// The Server the link points to.
    public var serverURL: URL { client.server }

    public init(chatID: String, title: String, client: OpenWebUIClient) {
        self.chatID = chatID
        self.title = title
        self.client = client
    }

    /// Reads whether the Chat has a link and whether it's open to everyone signed in.
    public func load() async {
        state = .loading
        do {
            if try await client.send(.chatShareID(id: chatID)) != nil {
                let grants = try await client.send(.sharedChatAccess(chatID: chatID))
                access = grants.contains(.everyoneSignedIn) ? .anyoneWithLink : .onlyYou
            } else {
                access = .onlyYou
            }
            state = .ready
        } catch {
            state = .failed(error.message)
        }
    }

    /// Opens the link to everyone signed in, or deletes it.
    public func setAccess(_ newAccess: Access) async {
        guard newAccess != access, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch newAccess {
            case .anyoneWithLink:
                _ = try await client.send(.shareChat(id: chatID))
                _ = try await client.send(.updateSharedChatAccess(chatID: chatID, grants: [.everyoneSignedIn]))
            case .onlyYou:
                // Clear the grant first so a later link doesn't silently reopen to everyone.
                _ = try await client.send(.updateSharedChatAccess(chatID: chatID, grants: []))
                _ = try await client.send(.unshareChat(chatID: chatID))
            }
            access = newAccess
        } catch {
            errorMessage = newAccess == .anyoneWithLink
                ? "Couldn't create the link. \(error.message)"
                : "Couldn't remove the link. \(error.message)"
        }
    }

    /// Re-snapshots the Chat and returns its link, ready for the system share sheet.
    public func freshLink() async -> URL? {
        guard access == .anyoneWithLink, !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            return try await client.send(.shareChat(id: chatID)).url(server: client.server)
        } catch {
            errorMessage = "Couldn't update the link. \(error.message)"
            return nil
        }
    }
}
