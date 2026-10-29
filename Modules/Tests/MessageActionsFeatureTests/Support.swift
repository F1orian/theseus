import ChatDomain
import ChatFeature
import Fixtures
import Foundation
@testable import MessageActionsFeature
import OpenWebUIKit
import Synchronization
import Testing

final class StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

/// Ids of the recorded `branches` scenario.
struct BranchIDs: Decodable {
    let chatID: String
    let first: [String]
    let regenerate: [String]
    let edit: [String]
    let feedbackID: String
    let shareID: String

    static func load() throws -> BranchIDs {
        try JSONDecoder().decode(BranchIDs.self, from: StreamFixture("branches").data("ids.json"))
    }
}

func makeClient(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
}

/// The JSON bodies sent for `method path`, in order.
func sentBodies(_ transport: StubTransport, _ method: String, _ path: String) -> [JSONValue] {
    transport.requests
        .filter { $0.httpMethod == method && $0.url?.path() == "/\(path)" }
        .compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } }
}

/// A loaded Conversation for the recorded Chat `chat`.
@MainActor
func loadedConversation(_ transport: StubTransport, chat: String, capabilities: Set<Capability> = Set(Capability.allCases)) async throws -> (ChatServices, ConversationModel) {
    let ids = try BranchIDs.load()
    transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try StreamFixture("branches").data(chat))
    let model = Model(id: "claude-haiku-5-5", name: "Claude Haiku")
    let client = makeClient(transport)
    let services = ChatServices(
        client: client,
        session: CompletionSession(client: client, socket: nil),
        models: [model],
        defaultModelID: model.id
    ) { _ in Capabilities(enabled: capabilities) }
    let conversation = services.conversation(chatID: ids.chatID)
    await conversation.load()
    return (services, conversation)
}

/// Polls the main actor until `condition` holds (bounded).
@MainActor
func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A speech output that records what it was asked to say and finishes when told to.
@MainActor
final class FakeSpeech: SpeechOutput {
    var spoken: [String] = []
    var stopCount = 0
    var failure: (any Error)?
    private var waiting: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async throws {
        spoken.append(text)
        if let failure { throw failure }
        await withCheckedContinuation { waiting = $0 }
    }

    func stop() {
        stopCount += 1
        finish()
    }

    func finish() {
        waiting?.resume()
        waiting = nil
    }

    var isSpeaking: Bool { waiting != nil }
}
