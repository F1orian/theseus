@testable import AppIntentsFeature
import Foundation
import Persistence
import Testing

@Suite("Deep links (PLAT-03)")
struct DeepLinkTests {
    func link(_ string: String) -> DeepLink? {
        URL(string: string).flatMap(DeepLink.init(url:))
    }

    @Test func parsesTheDocumentedURLs() throws {
        #expect(link("theseus://new") == .newChat)
        #expect(link("theseus://") == .newChat)
        #expect(link("theseus://new?prompt=Hello%20there&send=1") == .newChat(.init(prompt: "Hello there", sendsImmediately: true)))
        #expect(link("theseus://new?start=camera") == .newChat(.init(start: .camera)))
        #expect(link("theseus://new?start=dictation") == .newChat(.init(start: .dictation)))
        #expect(link("theseus://voice") == .newChat(.init(start: .voiceMode)))
        #expect(link("theseus://incognito") == .incognitoChat(prompt: nil))
        #expect(link("theseus://incognito?prompt=psst") == .incognitoChat(prompt: "psst"))
        #expect(link("theseus://chat/0b5c3d1e-1111-4000-8000-000000000001") == .chat(id: "0b5c3d1e-1111-4000-8000-000000000001"))
        #expect(link("theseus://chats") == .chatsList)
        let id = UUID()
        #expect(link("theseus://share/\(id.uuidString)") == .sharedItems(id))
    }

    @Test func rejectsWhatItDoesNotKnow() {
        #expect(link("https://chat.example.com/c/123") == nil)
        #expect(link("theseus://chat") == nil)
        #expect(link("theseus://share/not-a-uuid") == nil)
        #expect(link("theseus://settings/danger") == nil)
    }

    @Test func sendNeedsAPrompt() {
        #expect(link("theseus://new?send=1") == .newChat)
        #expect(DeepLink.NewChat(prompt: "", sendsImmediately: true) == DeepLink.NewChat())
    }

    @Test(arguments: [
        DeepLink.newChat,
        .newChat(.init(prompt: "Plan a trip & pack light?", sendsImmediately: true)),
        .newChat(.init(prompt: "Caption this", start: .photos)),
        .newChat(.init(start: .voiceMode)),
        .incognitoChat(prompt: nil),
        .incognitoChat(prompt: "a/b c"),
        .chat(id: "abc-123"),
        .chatsList,
        .sharedItems(UUID()),
    ])
    func urlsRoundTrip(_ link: DeepLink) {
        #expect(DeepLink(url: link.url) == link)
        #expect(link.url.scheme == "theseus")
    }

    @Test func voiceModeHasAShortURL() {
        #expect(DeepLink.newChat(.init(start: .voiceMode)).url.absoluteString == "theseus://voice")
        #expect(DeepLink.chat(id: "c1").url.absoluteString == "theseus://chat/c1")
    }
}

@MainActor
@Suite("Deep link center")
struct DeepLinkCenterTests {
    @Test func linksWaitForTheAppAndThenArriveInOrder() {
        let center = DeepLinkCenter()
        center.open(.newChat)
        center.open(.chat(id: "c1"))
        var received: [DeepLink] = []
        center.setHandler { received.append($0) }
        #expect(received == [.newChat, .chat(id: "c1")])
        center.open(.chatsList)
        #expect(received.last == .chatsList)
    }
}

@Suite("Chat entities (PLAT-03)")
struct ChatEntityQueryTests {
    let store = SharedSnapshotStore(container: .temporary())

    func write() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.write(SharedSnapshot(
            accountID: "a", accountName: "Ada", serverHost: "chat.example.com", actions: .init(),
            recentChats: [
                .init(id: "c1", title: "Trip to Lisbon", updatedAt: now),
                .init(id: "c2", title: "Sourdough schedule", updatedAt: now.addingTimeInterval(-60)),
            ]
        ))
    }

    @Test func findsChatsByIdAndTitle() async throws {
        try write()
        let query = ChatEntityQuery(store: store)
        #expect(try await query.entities(for: ["c2", "missing"]).map(\.id) == ["c2"])
        #expect(try await query.entities(matching: "lisbon").map(\.id) == ["c1"])
        #expect(try await query.suggestedEntities().map(\.id) == ["c1", "c2"])
    }

    @Test func signedOutThereAreNoChats() async throws {
        let query = ChatEntityQuery(store: store)
        #expect(try await query.suggestedEntities().isEmpty)
        #expect(try await ChatEntityQuery(store: nil).entities(for: ["c1"]).isEmpty)
    }
}
