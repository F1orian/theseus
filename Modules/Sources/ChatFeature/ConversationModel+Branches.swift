public import ChatDomain
import Foundation
import OpenWebUIKit

/// Message tree operations behind the Message actions (MSG-03…06): retry and edit as new
/// Branches, switching Branches, and the user's feedback on a Response. The action UI lives in
/// `MessageActionsFeature`; it calls these through `MessageAccessories`.
extension ConversationModel {
    /// Whether the thread can change now: loaded, nothing streaming, no question pending, and
    /// the Server reachable.
    public var canChangeThread: Bool {
        loadState == .loaded && !isStreaming && pendingQuestion == nil && services.connection.allowsSending
    }

    /// The stored Message with `id`, on any Branch.
    public func message(id: String) -> Message? {
        tree[id]
    }

    /// The "2 / 3" position of a Message among its siblings; `nil` when it has none.
    public func branchPosition(of messageID: String) -> MessageTree.BranchPosition? {
        guard let position = tree.branchPosition(of: messageID), position.count > 1 else { return nil }
        return position
    }

    /// Models of the other Branches next to `messageID` (sent with feedback).
    public func siblingModelIDs(of messageID: String) -> [String] {
        tree.siblingIDs(of: messageID).filter { $0 != messageID }.compactMap { tree[$0]?.modelID }
    }

    /// Shows the previous (`-1`) or next (`+1`) Branch at `messageID` and saves the choice, so
    /// the web client and other devices open the same Branch (MSG-04).
    public func showBranch(of messageID: String, offset: Int) async {
        guard !isStreaming, let shown = try? tree.selectSibling(of: messageID, offset: offset), shown != nil else { return }
        thread = tree.activePath
        guard let chatID, let currentID = tree.currentID else { return }
        do {
            _ = try await services.client.send(.selectBranch(chatID: chatID, currentID: currentID))
        } catch {
            notice = "Couldn't save the branch you picked. \(error.message)"
        }
    }

    /// Retry (MSG-03): streams a new Response to the same user Message as a new Branch, in place
    /// of the one on screen. Failed sends are resent instead (CHAT-13).
    public func regenerate(_ assistantID: String) async {
        guard canChangeThread, tree[assistantID]?.role == .assistant else { return }
        await retry(assistantID)
    }

    /// Edit (MSG-05): sends `content` as a new user Message next to `userMessageID` (same parent),
    /// so the original and its Responses stay reachable as another Branch.
    public func edit(_ userMessageID: String, to content: String) async {
        let prompt = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canChangeThread, !prompt.isEmpty, let original = tree[userMessageID], original.role == .user,
              let modelID = selectedModelID ?? services.preferredModelID
        else { return }
        notice = nil
        // The edited Message keeps the original's Attachments (ATT-04).
        await submit(
            prompt: prompt, modelID: modelID, parentID: original.parentID, existingUserID: nil,
            attachments: original.attachments, files: original.attachments.compactMap(\.fileReference)
        )
    }

    /// Records the user's feedback on a Response locally, after the Server stored it (MSG-06).
    public func setAnnotation(_ annotation: MessageAnnotation?, for messageID: String) {
        guard (try? tree.update(messageID, { $0.annotation = annotation })) != nil else { return }
        if let index = thread.firstIndex(where: { $0.id == messageID }), let updated = tree[messageID] {
            thread[index] = updated
        }
    }
}
