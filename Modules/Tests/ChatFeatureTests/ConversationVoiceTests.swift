@testable import ChatFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing

@Suite("Spoken turns (VOICE-03)", .serialized)
@MainActor
struct ConversationVoiceTests {
    @Test func aSpokenTurnIsAnOrdinaryMessageWithTheVoiceFeature() async throws {
        let fixture = StreamFixture("error")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "error")
        let bodies = Mutex<[Data]>([])
        transport.stub("POST", "api/chat/completions") { request in
            bodies.withLock { $0.append(request.httpBody ?? Data()) }
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        // The assistant id is minted first, so the caller can follow the Response at once.
        model.idGenerator = IDSequence([ids.assistantMessageID, ids.userMessageID]).next
        model.draft = "my unsent draft"

        #expect(model.canSendVoiceMessage)
        #expect(model.sendVoiceMessage("   ") == nil)
        let responseID = model.sendVoiceMessage(" Give me a meal plan. ")
        #expect(responseID == ids.assistantMessageID)
        // Both Messages are in the thread right away, and the next turn has to wait.
        #expect(model.thread.map(\.role) == [.user, .assistant])
        #expect(model.thread.first?.content == "Give me a meal plan.")
        #expect(model.isStreaming)
        #expect(!model.canSendVoiceMessage, "one turn at a time")
        #expect(model.sendVoiceMessage("again") == nil)
        #expect(model.draft == "my unsent draft", "the composer's draft is left alone")
        #expect(await until { bodies.withLock { !$0.isEmpty } })

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.withLock { $0.first }))
        #expect(body[path: "features.voice"] == .bool(true))
        #expect(body[path: "features.web_search"] != nil, "the composer's toggles still apply")
        #expect(services.composer.store.lastUsedModelID == haiku.id)
        #expect(await until { !model.isStreaming })
        await services.stop()
    }
}
