@testable import ArtifactsFeature
import ChatDomain
@testable import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

@Suite("Artifacts in Incognito chats (ADR 0070)")
@MainActor
struct IncognitoTests {
    @Test func incognitoArtifactsShowButAreNeverCached() {
        let model = Model(id: "claude-haiku-5-5", name: "Claude Haiku")
        let client = makeClient(StubTransport())
        let services = ChatServices(
            client: client,
            session: CompletionSession(client: client, socket: nil),
            models: [model],
            defaultModelID: model.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        let page = "```html\n<!doctype html><title>Secret page</title>\n```"
        for incognito in [true, false] {
            let conversation = incognito ? services.newIncognitoConversation() : services.newConversation()
            let id = "assistant-\(incognito)"
            conversation.thread = [
                Message(id: "user-\(incognito)", parentID: nil, role: .user, content: "Make a page", createdAt: .now),
                Message(id: id, parentID: "user-\(incognito)", role: .assistant, content: page, createdAt: .now),
            ]
            let catalog = ArtifactsCache.shared.catalog(for: conversation)
            #expect(catalog.artifacts.map(\.title) == ["Secret page"])
            #expect(ArtifactsCache.shared.hasEntry(for: id) == !incognito)
        }
    }
}
