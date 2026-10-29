@testable import ArtifactsFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Ids of the recorded `artifacts` scenario: four turns (HTML page, the page in pink, SVG, Mermaid).
struct ArtifactIDs: Decodable {
    let chatID: String
    let turns: [[String]]

    static func load() throws -> ArtifactIDs {
        try JSONDecoder().decode(ArtifactIDs.self, from: StreamFixture("artifacts").data("ids.json"))
    }
}

/// The recorded `artifacts` Chat, decoded like the app does.
func recordedArtifactsChat() async throws -> Chat {
    let ids = try ArtifactIDs.load()
    let transport = StubTransport()
    transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try StreamFixture("artifacts").data("chat.final.json"))
    let client = makeClient(transport)
    return try await client.send(.chat(id: ids.chatID)).chat
}

@Suite("Artifact versions (ART-03)")
struct ArtifactCatalogTests {
    @Test func recordedChatHasAPageInTwoVersionsAnImageAndADiagram() async throws {
        let ids = try ArtifactIDs.load()
        let chat = try await recordedArtifactsChat()
        let catalog = ArtifactCatalog(responses: ArtifactCatalog.responses(thread: chat.tree.activePath))

        #expect(catalog.count == 4)
        #expect(catalog.artifacts.map(\.kind) == [.webPage, .webPage, .image, .diagram])
        #expect(catalog.artifacts.map(\.title) == ["Tip Calculator", "Tip Calculator", "Sun icon", "Flowchart"])
        #expect(catalog.artifacts.map(\.version) == [1, 2, 1, 1])
        #expect(catalog.artifacts.map(\.messageID) == ids.turns.map { $0[1] })

        let pink = try #require(catalog.artifacts.dropFirst().first)
        #expect(pink.content.lowercased().contains("#fdf2f8"))
        #expect(catalog.versions(of: pink).map(\.version) == [1, 2])
        #expect(catalog.latestVersions.map(\.title) == ["Flowchart", "Sun icon", "Tip Calculator"])
        #expect(catalog.latestVersions.last?.version == 2)
        #expect(!pink.referencesNetwork)
    }

    @Test func renderedCodeBlocksFindTheirArtifact() async throws {
        let chat = try await recordedArtifactsChat()
        let catalog = ArtifactCatalog(responses: ArtifactCatalog.responses(thread: chat.tree.activePath))
        let diagram = try #require(catalog.artifacts.last)
        #expect(catalog.artifact(messageID: diagram.messageID, language: "mermaid", code: diagram.content) == diagram)
        #expect(catalog.artifact(messageID: "other", language: "mermaid", code: diagram.content) == nil)
    }

    @Test func versionsFollowTheActivePathOnly() {
        let page = "```html\n<html><title>Counter</title></html>\n```"
        let catalog = ArtifactCatalog(responses: [
            .init(messageID: "a", text: page),
            .init(messageID: "b", text: "No artifact here."),
            .init(messageID: "c", text: page + "\n\n" + page),
        ])
        #expect(catalog.artifacts.map(\.version) == [1, 2, 3])
        #expect(catalog.artifacts.map(\.id) == ["a/0", "c/0", "c/1"])
        // A different kind with the same title is a different Artifact.
        let mixed = ArtifactCatalog(responses: [
            .init(messageID: "a", text: page),
            .init(messageID: "b", text: "```svg\n<svg><title>Counter</title></svg>\n```"),
        ])
        #expect(mixed.artifacts.map(\.version) == [1, 1])
    }

    @Test func streamingResponsesMatchTheOpenArtifact() {
        let catalog = ArtifactCatalog(responses: [
            .init(messageID: "a", text: "Sure.\n\n```html\n<!doctype html>\n<p>Hel", isStreaming: true),
        ])
        let open = try? #require(catalog.artifacts.first)
        #expect(open?.isComplete == false)
        // The renderer may hand over a slightly different tail while the fence is open.
        #expect(catalog.artifact(messageID: "a", language: "html", code: "<!doctype html>\n<p>He") == open)
    }

    @Test func embedsAreDecodedFromStoredMessages() async throws {
        let json = """
        {"id":"c1","title":"t","chat":{"history":{"currentId":"m1","messages":{
          "m1":{"id":"m1","role":"assistant","content":"Done.","done":true,"embeds":["<html><title>Board</title></html>",{"x":1}]}
        }}},"updated_at":0,"created_at":0}
        """
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/c1", body: Data(json.utf8))
        let client = makeClient(transport)
        let chat = try await client.send(.chat(id: "c1")).chat
        let message = try #require(chat.tree.activePath.first)
        #expect(message.embeds == ["<html><title>Board</title></html>"])
        #expect(message.response.embeds == message.embeds)
        let catalog = ArtifactCatalog(responses: ArtifactCatalog.responses(thread: chat.tree.activePath))
        #expect(catalog.artifacts.first?.title == "Board")
    }

    @Test func liveEmbedEventsAppendOrReplace() {
        var state = ResponseState()
        state.apply(.embeds(["<p>a</p>"], replace: false))
        state.apply(.embeds(["<p>b</p>"], replace: false))
        #expect(state.embeds == ["<p>a</p>", "<p>b</p>"])
        state.apply(.embeds(["<p>c</p>"], replace: true))
        #expect(state.embeds == ["<p>c</p>"])

        let envelope = JSONValue.object([
            "chat_id": .string("c"), "message_id": .string("m"),
            "data": .object(["type": .string("chat:message:embeds"), "data": .object(["embeds": .array([.string("<p>x</p>")])])]),
        ])
        #expect(ChatEventDecoder.decode(envelope).map(\.kind) == [.response(.embeds(["<p>x</p>"], replace: false))])
    }
}
