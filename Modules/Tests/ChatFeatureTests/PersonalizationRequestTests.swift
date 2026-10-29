@testable import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Sends carry the Account's personalization (PERS-01..03): Instructions as the system message,
/// `features.memory` and the `{{USER_NAME}}` variable.
@Suite("Personalized requests", .serialized)
@MainActor
struct PersonalizationRequestTests {
    @Test func sendsCarryInstructionsMemoryAndTheUserName() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        var askedFor: String?
        services.personalization = { model in
            askedFor = model?.id
            return ChatPersonalization(instructions: "Be brief.", preferredName: "Ada", usesMemory: true)
        }
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next
        await send(model, "[theseus-test] What is a maze?")

        let request = try #require(transport.requests.first { $0.url?.path() == "/api/chat/completions" })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(askedFor == haiku.id)
        #expect(body[path: "features.memory"] == .bool(true))
        #expect(body[path: "variables"] == .object(["{{USER_NAME}}": .string("Ada")]))
        #expect(body[path: "messages"] == .array([.object(["role": .string("system"), "content": .string("Be brief.")])]))
        #expect(await until { !model.isStreaming })
        await services.stop()
    }
}
