import ChatDomain
import ChatFeature
import Fixtures
import Foundation
@testable import MessageActionsFeature
import OpenWebUIKit
import Testing

@Suite("Feedback (MSG-06)")
struct FeedbackServiceTests {
    let fixture = StreamFixture("branches")

    @Test func ratingSendsFeedbackThenAnnotatesTheStoredMessage() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.switched.json"))
        transport.stub("POST", "api/v1/evaluations/feedback", body: try fixture.data("feedback.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.annotated.json"))
        let service = FeedbackService(client: makeClient(transport))

        let annotation = try await service.submit(.init(
            chatID: ids.chatID,
            messageID: ids.first[1],
            rating: .good,
            comment: " Short and right ",
            modelID: "claude-haiku-5-5",
            siblingModelIDs: ["claude-haiku-5-5"]
        ))
        #expect(annotation == MessageAnnotation(rating: .good, comment: "Short and right", feedbackID: ids.feedbackID))

        let feedback = try #require(sentBodies(transport, "POST", "api/v1/evaluations/feedback").first)
        #expect(feedback[path: "data.rating"] == .number(1))
        #expect(feedback[path: "data.comment"] == .string("Short and right"))
        #expect(feedback[path: "data.reason"] == nil, "only reports carry a reason (ADR 0172)")
        #expect(feedback[path: "meta.message_id"]?.stringValue == ids.first[1])
        #expect(feedback[path: "snapshot.chat.id"]?.stringValue == ids.chatID, "the Chat goes along as a snapshot")

        let update = try #require(sentBodies(transport, "POST", "api/v1/chats/\(ids.chatID)").first)
        let message = try #require(update[path: "chat.history.messages"]?.objectValue?[ids.first[1]])
        #expect(message[path: "annotation.rating"] == .number(1))
        #expect(message[path: "annotation.comment"] == .string("Short and right"))
        #expect(message[path: "feedbackId"]?.stringValue == ids.feedbackID)
        // The rest of the stored Message is sent back untouched (the server replaces it whole).
        #expect(message[path: "content"] == .string("Blue"))
        #expect(message[path: "model"] == .string("claude-haiku-5-5"))
        #expect(message[path: "parentId"]?.stringValue == ids.first[0])
        #expect(update[path: "chat.history.currentId"] == nil, "doesn't move the shown Branch")
    }

    @Test func changingARatingUpdatesTheEarlierRecord() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.annotated.json"))
        transport.stub("POST", "api/v1/evaluations/feedback/\(ids.feedbackID)", body: try fixture.data("feedback.updated.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.annotated.json"))
        let service = FeedbackService(client: makeClient(transport))
        let annotation = try await service.submit(.init(
            chatID: ids.chatID, messageID: ids.first[1], rating: .bad, comment: "", modelID: nil, feedbackID: ids.feedbackID
        ))
        #expect(annotation.rating == .bad)
        #expect(annotation.comment == nil)
        #expect(sentBodies(transport, "POST", "api/v1/evaluations/feedback").isEmpty, "no second record")
        let message = try #require(sentBodies(transport, "POST", "api/v1/chats/\(ids.chatID)").first?[path: "chat.history.messages"]?.objectValue?[ids.first[1]])
        #expect(message[path: "annotation.rating"] == .number(-1))
        #expect(message[path: "annotation.comment"] == .null)
    }

    @Test func aDeletedRecordIsRecreated() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.annotated.json"))
        transport.stub("POST", "api/v1/evaluations/feedback", body: try fixture.data("feedback.json"))
        let service = FeedbackService(client: makeClient(transport))
        let annotation = try await service.submit(.init(
            chatID: ids.chatID, messageID: ids.first[1], rating: .good, comment: "", modelID: nil, feedbackID: "gone"
        ))
        #expect(annotation.feedbackID == ids.feedbackID)
    }

    @Test func refusedFeedbackThrows() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.switched.json"))
        transport.stub("POST", "api/v1/evaluations/feedback", status: 403, body: Data(#"{"detail":"Nope"}"#.utf8))
        let service = FeedbackService(client: makeClient(transport))
        await #expect(throws: OpenWebUIError.forbidden(detail: "Nope")) {
            try await service.submit(.init(chatID: ids.chatID, messageID: ids.first[1], rating: .good, comment: "", modelID: nil))
        }
    }
}

@Suite("Chat link (MSG-08)")
@MainActor
struct ChatLinkSharingTests {
    let fixture = StreamFixture("branches")

    @Test func aChatWithoutLinkIsOnlyYours() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.after-edit.json"))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()
        #expect(sharing.state == .ready)
        #expect(sharing.access == .onlyYou)
        #expect(await sharing.freshLink() == nil, "no link while private")
    }

    @Test func anOpenLinkIsAnyoneWithTheLink() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("share.json"))
        transport.stub("GET", "api/v1/chats/shared/\(ids.chatID)/access", body: try fixture.data("share.access.json"))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()
        #expect(sharing.access == .anyoneWithLink)
    }

    @Test func aLinkWithoutGrantsIsStillOnlyYours() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("share.json"))
        transport.stub("GET", "api/v1/chats/shared/\(ids.chatID)/access", body: Data("[]".utf8))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()
        #expect(sharing.access == .onlyYou)
    }

    @Test func openingAndClosingTheLink() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.after-edit.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)/share", body: try fixture.data("share.json"))
        transport.stub("POST", "api/v1/chats/shared/\(ids.chatID)/access/update", body: try fixture.data("share.access-update.json"))
        transport.stub("DELETE", "api/v1/chats/\(ids.chatID)/share", body: try fixture.data("unshare.json"))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()

        await sharing.setAccess(.anyoneWithLink)
        #expect(sharing.access == .anyoneWithLink)
        #expect(sentBodies(transport, "POST", "api/v1/chats/shared/\(ids.chatID)/access/update").last?[path: "access_grants"]
            == .array([.object(["principal_type": .string("user"), "principal_id": .string("*"), "permission": .string("read")])]))

        // Share link re-snapshots, then hands out the web URL.
        let link = await sharing.freshLink()
        #expect(link?.absoluteString == "https://owui.example.com/s/\(ids.shareID)")
        #expect(transport.requests.filter { $0.httpMethod == "POST" && $0.url?.path() == "/api/v1/chats/\(ids.chatID)/share" }.count == 2)

        await sharing.setAccess(.onlyYou)
        #expect(sharing.access == .onlyYou)
        #expect(sentBodies(transport, "POST", "api/v1/chats/shared/\(ids.chatID)/access/update").last?[path: "access_grants"] == .array([]))
        #expect(transport.requests.last?.httpMethod == "DELETE")
        #expect(sharing.errorMessage == nil)
    }

    @Test func failuresKeepTheOldAccessAndExplain() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.after-edit.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)/share", status: 401, body: Data(#"{"detail":"Not allowed"}"#.utf8))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()
        await sharing.setAccess(.anyoneWithLink)
        #expect(sharing.access == .onlyYou)
        #expect(sharing.errorMessage?.hasPrefix("Couldn't create the link.") == true)
    }

    @Test func loadFailuresAreShown() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", status: 500, body: Data(#"{"detail":"down"}"#.utf8))
        let sharing = ChatLinkSharing(chatID: ids.chatID, title: "Colours", client: makeClient(transport))
        await sharing.load()
        #expect(sharing.state == .failed("down"))
    }
}

@Suite("Message actions (MSG-01/02/05/06)", .serialized)
@MainActor
struct MessageActionsTests {
    private func makeActions(_ transport: StubTransport, copied: @escaping @MainActor (String) -> Void = { _ in }) -> MessageActions {
        let actions = MessageActions(client: makeClient(transport), readAloud: ReadAloudController { FakeSpeech() }, copyText: copied)
        actions.confirmationDuration = .milliseconds(50)
        return actions
    }

    @Test func copyFlipsTheIconAndShowsAToast() async {
        var clipboard: [String] = []
        let actions = makeActions(StubTransport()) { clipboard.append($0) }
        actions.copy("**Blue**", messageID: "a1")
        #expect(clipboard == ["**Blue**"])
        #expect(actions.copiedMessageID == "a1")
        #expect(actions.toast?.text == "Message copied")
        #expect(await until { actions.copiedMessageID == nil })
        #expect(await until { actions.toast == nil })
    }

    @Test func thumbsOpenFeedbackPrefilledForTheSameRating() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        let (services, conversation) = try await loadedConversation(transport, chat: "chat.annotated.json")
        let actions = makeActions(transport)
        let message = try #require(conversation.message(id: ids.first[1]))

        actions.rate(message, .good, in: conversation)
        guard case .feedback(let draft)? = actions.sheet else {
            Issue.record("expected the Feedback sheet")
            return
        }
        #expect(draft.rating == .good)
        #expect(draft.comment == "[theseus-test] short and right")

        actions.rate(message, .bad, in: conversation)
        guard case .feedback(let other)? = actions.sheet else { return }
        #expect(other.comment.isEmpty)
        await services.stop()
    }

    @Test func submittedFeedbackFillsTheThumb() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        let (services, conversation) = try await loadedConversation(transport, chat: "chat.switched.json")
        transport.stub("POST", "api/v1/evaluations/feedback", body: try StreamFixture("branches").data("feedback.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", body: try StreamFixture("branches").data("chat.annotated.json"))
        let actions = makeActions(transport)
        let message = try #require(conversation.message(id: ids.first[1]))
        actions.rate(message, .good, in: conversation)
        guard case .feedback(let draft)? = actions.sheet else { return }

        #expect(await actions.submit(draft, comment: "Nice"))
        #expect(conversation.message(id: ids.first[1])?.annotation?.rating == .good)
        #expect(conversation.thread.last?.annotation?.feedbackID == ids.feedbackID)
        #expect(actions.toast?.text == "Thanks for your feedback")
        let sibling = sentBodies(transport, "POST", "api/v1/evaluations/feedback").first?[path: "data.sibling_model_ids"]
        #expect(sibling == .array([.string("claude-haiku-5-5")]), "the retry is a sibling Branch")
        await services.stop()
    }

    @Test func failedFeedbackLeavesTheThumbEmpty() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        let (services, conversation) = try await loadedConversation(transport, chat: "chat.switched.json")
        transport.stub("POST", "api/v1/evaluations/feedback", status: 500, body: Data(#"{"detail":"down"}"#.utf8))
        let actions = makeActions(transport)
        let message = try #require(conversation.message(id: ids.first[1]))
        actions.rate(message, .bad, in: conversation)
        guard case .feedback(let draft)? = actions.sheet else { return }
        #expect(await actions.submit(draft, comment: "") == false)
        #expect(conversation.message(id: ids.first[1])?.annotation == nil)
        #expect(actions.toast?.text.contains("down") == true)
        await services.stop()
    }

    @Test func editAndShareOpenTheirSheets() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        let (services, conversation) = try await loadedConversation(transport, chat: "chat.after-first.json")
        let actions = makeActions(transport)
        let user = try #require(conversation.message(id: ids.first[0]))
        actions.edit(user, in: conversation)
        guard case .edit(let draft)? = actions.sheet else {
            Issue.record("expected the Edit sheet")
            return
        }
        #expect(draft.text == user.content)

        actions.share(chatID: ids.chatID, title: "Colours")
        guard case .share(let sharing)? = actions.sheet else {
            Issue.record("expected the Share sheet")
            return
        }
        #expect(sharing.chatID == ids.chatID)
        #expect(sharing.serverHost == "owui.example.com")
        await services.stop()
    }

    @Test func accessoriesAreProvided() {
        let accessories = makeActions(StubTransport()).accessories
        #expect(accessories.response != nil)
        #expect(accessories.userMessage != nil)
        #expect(accessories.userMessageMenu != nil)
    }
}
