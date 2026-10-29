import ChatDomain
import ChatFeature
import Fixtures
import Foundation
@testable import MessageActionsFeature
import OpenWebUIKit
import Testing

/// App Review 1.2, ADR 0172: a Response can be reported as harmful or offensive to the people who
/// run its Server.
@Suite("Report a Response")
@MainActor
struct ReportTests {
    let fixture = StreamFixture("branches")

    @Test func aReportIsAThumbsDownWithAReasonAndTag() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.switched.json"))
        transport.stub("POST", "api/v1/evaluations/feedback", body: try fixture.data("feedback.json"))
        transport.stub("POST", "api/v1/chats/\(ids.chatID)", body: try fixture.data("chat.annotated.json"))
        let service = FeedbackService(client: makeClient(transport))
        _ = try await service.submit(.init(
            chatID: ids.chatID, messageID: ids.first[1], rating: .bad, comment: "Insulting", modelID: nil, isReport: true
        ))
        let feedback = try #require(sentBodies(transport, "POST", "api/v1/evaluations/feedback").first)
        #expect(feedback[path: "data.rating"] == .number(-1))
        #expect(feedback[path: "data.reason"] == .string(FeedbackService.reportReason))
        #expect(feedback[path: "data.tags"] == .array([.string("reported")]))
        #expect(feedback[path: "data.comment"] == .string("Insulting"))
    }

    @Test func reportOnASavedChatOpensTheSheetWithReportOn() async throws {
        let ids = try BranchIDs.load()
        let transport = StubTransport()
        let (services, conversation) = try await loadedConversation(transport, chat: "chat.switched.json")
        let actions = MessageActions(client: services.client)
        let message = try #require(conversation.message(id: ids.first[1]))
        let mail = await actions.report(message, text: "Blue", in: conversation)
        #expect(mail == nil)
        guard case .feedback(let draft) = actions.sheet else {
            Issue.record("Expected the Feedback sheet")
            return
        }
        #expect(draft.isReport)
        #expect(draft.rating == .bad)
    }

    @Test func withoutRatingAReportIsAnEmailToTheAdmin() throws {
        let url = try #require(MessageActions.reportMail(to: "admin@example.org", host: "chat.example.org", model: "m1", text: "Bad words"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "admin@example.org")
        let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("Bad words"))
        #expect(body.contains("chat.example.org"))
        let fallback = try #require(MessageActions.reportMail(to: nil, host: "h", model: nil, text: "x"))
        #expect(URLComponents(url: fallback, resolvingAgainstBaseURL: false)?.path.contains("@") == true)
    }
}
