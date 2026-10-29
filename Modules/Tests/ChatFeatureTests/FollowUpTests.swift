@testable import ChatFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Follow-up suggestions (#141, ADR 0121): requested only when the user turned them on
/// (`ui.autoFollowUps`), shown under the latest Response, and sent with one tap.
@Suite("Follow-up suggestions", .serialized)
@MainActor
struct FollowUpTests {
    private func run(followUpsOn: Bool) async throws -> (ConversationModel, StubTransport, ChatServices, StreamFixture.IDs) {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        transport.stub("GET", "api/v1/users/user/settings", body: Data(#"{"ui":{"autoFollowUps":\#(followUpsOn)}}"#.utf8))
        let services = makeServices(transport: transport, replay: replay)
        await services.composer.refresh()
        services.start()
        let model = services.newConversation()
        let followUp = try #require(ids.followUp)
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID, followUp.user, followUp.assistant]).next
        await send(model, "[theseus-test] In two short sentences, what is a maze?")
        return (model, transport, services, ids)
    }

    private func completionBodies(_ transport: StubTransport) throws -> [JSONValue] {
        try transport.requests.filter { $0.url?.path() == "/api/chat/completions" }.map { request in
            try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        }
    }

    @Test func suggestionsShowUnderTheLatestResponseAndSendOnTap() async throws {
        let (model, transport, services, ids) = try await run(followUpsOn: true)
        #expect(try completionBodies(transport).first?[path: "background_tasks.follow_up_generation"] == .bool(true))
        let first = try #require(model.message(id: ids.assistantMessageID))
        #expect(await until { !model.followUps(for: first).isEmpty })
        let suggestions = model.followUps(for: first)
        #expect(suggestions.first == "Now define a labyrinth in two short sentences, with one **bold** word.")

        await model.sendFollowUp(suggestions[1])
        let bodies = try completionBodies(transport)
        #expect(bodies.count == 2)
        #expect(bodies.last?[path: "user_message.content"]?.stringValue == suggestions[1])
        // Once a newer turn exists, the older Response shows none.
        #expect(model.followUps(for: first).isEmpty)
        await services.stop()
    }

    @Test func offMeansNotRequestedAndNotShown() async throws {
        let (model, transport, services, ids) = try await run(followUpsOn: false)
        #expect(try completionBodies(transport).first?[path: "background_tasks.follow_up_generation"] == .bool(false))
        #expect(await until { !model.isStreaming })
        let first = try #require(model.message(id: ids.assistantMessageID))
        #expect(model.followUps(for: first).isEmpty)
        await services.stop()
    }
}
