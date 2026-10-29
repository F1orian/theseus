import ChatDomain
import Foundation
@testable import OpenWebUIKit
import Testing

private func json(_ data: Data?) throws -> JSONValue {
    try WireCoding.decoder.decode(JSONValue.self, from: try #require(data))
}

@Suite("Completion bodies: Projects (#127)")
struct ProjectCompletionBodyTests {
    @Test func aNewChatInAProjectNamesItsFolder() throws {
        var request = CompletionRequest(chatID: nil, modelID: "m", prompt: "hi")
        request.folderID = "p1"
        let body = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(body[path: "folder_id"]?.stringValue == "p1")
        #expect(body[path: "chat_id"] == nil)
    }

    @Test func followUpsDontMoveTheChat() throws {
        var request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi", parentMessageID: "a0")
        request.folderID = "p1"
        let body = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(body[path: "folder_id"] == nil)
        #expect(body[path: "chat_id"]?.stringValue == "c1")
    }

    @Test func theSSEFallbackSavesTheNewChatIntoTheProject() throws {
        var request = CompletionRequest(chatID: nil, modelID: "m", prompt: "hi")
        request.folderID = "p1"
        let body = try json(CompletionSession.persist(request, responseText: "hello").body)
        #expect(body[path: "folder_id"]?.stringValue == "p1")
        #expect(body[path: "chat.title"]?.stringValue == "hi")
    }
}

@Suite("Completion bodies: Incognito chats (INCOG-01)")
struct IncognitoCompletionBodyTests {
    private func incognito(history: [CompletionRequest.HistoryEntry] = []) -> CompletionRequest {
        var request = CompletionRequest(
            chatID: nil, modelID: "m", prompt: "and now?", parentMessageID: history.isEmpty ? nil : "a1",
            isIncognito: true, userMessageID: "u2", assistantMessageID: "a2", history: history
        )
        request.folderID = "p1"
        return request
    }

    @Test func theChatIsTemporaryOnThisSocket() throws {
        let body = try json(CompletionSession.socketBody(incognito(), sessionID: "sid-42"))
        #expect(body[path: "chat_id"]?.stringValue == "temporary:sid-42")
        #expect(body[path: "session_id"]?.stringValue == "sid-42")
        // Never saved, so never filed in a Project and never titled.
        #expect(body[path: "folder_id"] == nil)
        #expect(body[path: "background_tasks.title_generation"]?.boolValue == false)
    }

    @Test func theFullHistoryTravelsWithEveryTurn() throws {
        let history: [CompletionRequest.HistoryEntry] = [
            .init(role: .user, content: "Name a colour."),
            .init(role: .assistant, content: "Teal."),
        ]
        let body = try json(CompletionSession.socketBody(incognito(history: history), sessionID: "sid"))
        let messages = body[path: "messages"]?.arrayValue ?? []
        #expect(messages.compactMap { $0[path: "role"]?.stringValue } == ["user", "assistant", "user"])
        #expect(messages.compactMap { $0[path: "content"]?.stringValue } == ["Name a colour.", "Teal.", "and now?"])
    }

    @Test func photosTravelInlineAsImageParts() throws {
        let history: [CompletionRequest.HistoryEntry] = [
            .init(role: .user, content: "Look.", images: ["data:image/png;base64,AAA"]),
            .init(role: .assistant, content: "A square."),
        ]
        var request = incognito(history: history)
        request.inlineImages = ["data:image/jpeg;base64,BBB"]
        let body = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        let messages = body[path: "messages"]?.arrayValue ?? []
        #expect(messages[0][path: "content"]?.arrayValue?.compactMap { $0[path: "type"]?.stringValue } == ["text", "image_url"])
        #expect(messages[0][path: "content"]?.arrayValue?.last?[path: "image_url.url"]?.stringValue == "data:image/png;base64,AAA")
        #expect(messages[1][path: "content"]?.stringValue == "A square.")
        let last = messages[2][path: "content"]?.arrayValue ?? []
        #expect(last.first?[path: "text"]?.stringValue == "and now?")
        #expect(last.last?[path: "image_url.url"]?.stringValue == "data:image/jpeg;base64,BBB")
        // Nothing was uploaded, so there are no file references.
        #expect(body[path: "user_message.files"]?.arrayValue?.isEmpty == true)
    }

    @Test func memoryStaysOff() throws {
        var request = incognito()
        request.personalization = ChatPersonalization(instructions: "Be brief.", preferredName: "Ada", usesMemory: true)
        let body = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(body[path: "features.memory"]?.boolValue != true)
        // Profile Instructions still lead the conversation.
        #expect(body[path: "messages"]?.arrayValue?.first?[path: "role"]?.stringValue == "system")
    }

    @Test func savedChatsStillSendOnlyTheSystemMessage() throws {
        let request = CompletionRequest(
            chatID: "c1", modelID: "m", prompt: "hi", parentMessageID: "a1",
            history: [.init(role: .user, content: "earlier")]
        )
        let body = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(body[path: "messages"]?.arrayValue?.isEmpty == true)
    }
}
