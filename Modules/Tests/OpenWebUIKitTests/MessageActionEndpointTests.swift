import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Message actions (MSG-03…08): the Message tree with Branches, branch selection, feedback,
/// Chat links and speech. Request shapes and decoding of the recorded `branches` scenario.
@Suite("Message action endpoints")
struct MessageActionEndpointTests {
    private let fixture = StreamFixture("branches")

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    }

    private struct BranchIDs: Decodable {
        let chatID: String
        let first: [String]
        let regenerate: [String]
        let edit: [String]
        let feedbackID: String
        let shareID: String
    }

    private func ids() throws -> BranchIDs {
        try JSONDecoder().decode(BranchIDs.self, from: fixture.data("ids.json"))
    }

    // MARK: Message tree

    @Test func retryAndEditDecodeAsSiblingBranches() throws {
        let ids = try ids()
        let chat = try Endpoint<ChatDocument>.chat(id: ids.chatID).decode(fixture.data("chat.after-edit.json")).chat
        let tree = chat.tree
        // The edit (a new root) is the newest Branch and is shown.
        #expect(tree.currentID == ids.edit[1])
        #expect(tree.activePath.map(\.id) == ids.edit)
        #expect(tree.branchPosition(of: ids.edit[0]) == .init(index: 1, count: 2))
        // The retry is the second assistant Branch under the first user Message.
        #expect(tree.siblingIDs(of: ids.first[1]) == [ids.first[1], ids.regenerate[1]])
        #expect(tree.branchPosition(of: ids.regenerate[1]) == .init(index: 1, count: 2))
    }

    @Test func selectingABranchSendsOnlyCurrentID() throws {
        let ids = try ids()
        let endpoint = Endpoint<ChatDocument>.selectBranch(chatID: ids.chatID, currentID: ids.first[1])
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/chats/\(ids.chatID)")
        #expect(try body(sent) == .object(["chat": .object(["history": .object(["currentId": .string(ids.first[1])])])]))
        let chat = try endpoint.decode(fixture.data("chat.switched.json")).chat
        #expect(chat.tree.currentID == ids.first[1])
        #expect(chat.tree.activePath.map(\.id) == ids.first)
    }

    // MARK: Feedback (MSG-06)

    @Test func annotationsDecodeFromTheChat() throws {
        let ids = try ids()
        let chat = try Endpoint<ChatDocument>.chat(id: ids.chatID).decode(fixture.data("chat.annotated.json")).chat
        let annotation = try #require(chat.tree[ids.first[1]]?.annotation)
        #expect(annotation.rating == .good)
        #expect(annotation.comment == "[theseus-test] short and right")
        #expect(annotation.feedbackID == ids.feedbackID)
        #expect(chat.tree[ids.regenerate[1]]?.annotation == nil)
    }

    @Test func feedbackCarriesRatingModelCommentAndSnapshot() throws {
        let ids = try ids()
        let snapshot: JSONValue = .object(["id": .string(ids.chatID)])
        let feedback = FeedbackSubmission(
            rating: .bad,
            modelID: "claude-haiku-5-5",
            comment: "Too long",
            chatID: ids.chatID,
            messageID: ids.first[1],
            siblingModelIDs: ["claude-haiku-5-5"],
            snapshot: snapshot
        )
        let created = request(.submitFeedback(feedback))
        #expect(created.httpMethod == "POST")
        #expect(created.url?.path() == "/api/v1/evaluations/feedback")
        let sent = try body(created)
        #expect(sent[path: "type"] == .string("rating"))
        #expect(sent[path: "data.rating"] == .number(-1))
        #expect(sent[path: "data.model_id"] == .string("claude-haiku-5-5"))
        #expect(sent[path: "data.comment"] == .string("Too long"))
        #expect(sent[path: "data.sibling_model_ids"] == .array([.string("claude-haiku-5-5")]))
        #expect(sent[path: "meta.chat_id"] == .string(ids.chatID))
        #expect(sent[path: "meta.message_id"] == .string(ids.first[1]))
        #expect(sent[path: "snapshot.chat"] == snapshot)

        let record = try Endpoint<FeedbackRecord>.submitFeedback(feedback).decode(fixture.data("feedback.json"))
        #expect(record.id == ids.feedbackID)
        #expect(record.rating == .good)

        let updated = request(.updateFeedback(id: ids.feedbackID, feedback))
        #expect(updated.url?.path() == "/api/v1/evaluations/feedback/\(ids.feedbackID)")
        let changed = try Endpoint<FeedbackRecord>.updateFeedback(id: ids.feedbackID, feedback).decode(fixture.data("feedback.updated.json"))
        #expect(changed.rating == .bad)
    }

    @Test func emptyCommentsAreOmitted() throws {
        let feedback = FeedbackSubmission(rating: .good, modelID: nil, comment: "  ", chatID: "c", messageID: "m")
        let sent = try body(request(.submitFeedback(feedback)))
        #expect(sent[path: "data.comment"] == nil)
        #expect(sent[path: "data.model_id"] == nil)
        #expect(sent[path: "snapshot"] == nil)
    }

    @Test func messageUpdatesReplaceOneHistoryEntry() throws {
        let message: JSONValue = .object(["id": .string("m"), "content": .string("Blue")])
        let sent = request(.updateChatMessage(chatID: "c", messageID: "m", message: message))
        #expect(sent.url?.path() == "/api/v1/chats/c")
        #expect(try body(sent) == .object(["chat": .object(["history": .object(["messages": .object(["m": message])])])]))
    }

    @Test func rawChatKeepsUnknownFields() throws {
        let ids = try ids()
        let raw = try Endpoint<JSONValue>.rawChat(id: ids.chatID).decode(fixture.data("chat.after-edit.json"))
        #expect(request(.rawChat(id: ids.chatID)).url?.path() == "/api/v1/chats/\(ids.chatID)")
        #expect(raw[path: "chat.history.messages"]?.objectValue?[ids.first[1]]?[path: "model"] == .string("claude-haiku-5-5"))
    }

    // MARK: Chat links (MSG-08)

    @Test func sharingReturnsTheSnapshotLink() throws {
        let ids = try ids()
        let share = request(.shareChat(id: ids.chatID))
        #expect(share.httpMethod == "POST")
        #expect(share.url?.path() == "/api/v1/chats/\(ids.chatID)/share")
        let link = try Endpoint<ChatShareLink>.shareChat(id: ids.chatID).decode(fixture.data("share.json"))
        #expect(link.shareID == ids.shareID)
        #expect(link.url(server: Fixture.serverURL).absoluteString == "https://owui.example.com/s/\(ids.shareID)")
    }

    @Test func shareStatusComesFromTheChat() throws {
        let ids = try ids()
        let shared = try Endpoint<String?>.chatShareID(id: ids.chatID).decode(fixture.data("share.json"))
        #expect(shared == ids.shareID)
        let unshared = try Endpoint<String?>.chatShareID(id: ids.chatID).decode(fixture.data("chat.after-edit.json"))
        #expect(unshared == nil)
    }

    @Test func accessGrantsOpenTheLinkToSignedInUsers() throws {
        let ids = try ids()
        let grants = try Endpoint<[ShareAccessGrant]>.sharedChatAccess(chatID: ids.chatID).decode(fixture.data("share.access.json"))
        #expect(grants == [.everyoneSignedIn])
        #expect(request(.sharedChatAccess(chatID: ids.chatID)).url?.path() == "/api/v1/chats/shared/\(ids.chatID)/access")

        let update = request(.updateSharedChatAccess(chatID: ids.chatID, grants: [.everyoneSignedIn]))
        #expect(update.url?.path() == "/api/v1/chats/shared/\(ids.chatID)/access/update")
        #expect(try body(update) == .object(["access_grants": .array([.object([
            "principal_type": .string("user"), "principal_id": .string("*"), "permission": .string("read"),
        ])])]))
    }

    // MARK: Read aloud (MSG-07)

    @Test func audioConfigTellsWhetherTheServerSpeaks() throws {
        let config = try Endpoint<AudioConfig>.audioConfig.decode(Fixture.data("config.json"))
        #expect(config.ttsEngine == nil, "the test Server has no TTS engine")
        #expect(!config.hasServerSpeech)
        let configured = try Endpoint<AudioConfig>.audioConfig.decode(Data(#"{"audio":{"tts":{"engine":"openai","voice":"alloy"}}}"#.utf8))
        #expect(configured.hasServerSpeech)
        #expect(configured.ttsVoice == "alloy")
        #expect(try Endpoint<AudioConfig>.audioConfig.decode(Data("{}".utf8)) == AudioConfig(ttsEngine: nil, ttsVoice: nil))
    }

    @Test func speechPostsTheTextAndReturnsAudio() throws {
        let speech = request(.speech(text: "Blue", voice: "alloy"))
        #expect(speech.httpMethod == "POST")
        #expect(speech.url?.path() == "/api/v1/audio/speech")
        #expect(try body(speech) == .object(["input": .string("Blue"), "voice": .string("alloy")]))
        let audio = Data([0x49, 0x44, 0x33])
        #expect(try Endpoint<Data>.speech(text: "Blue", voice: nil).decode(audio) == audio)
        #expect(try body(request(.speech(text: "Blue", voice: nil))) == .object(["input": .string("Blue")]))
    }
}
