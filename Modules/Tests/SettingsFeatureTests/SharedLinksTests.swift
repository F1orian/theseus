import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import Testing

@MainActor
@Suite("Shared links (SET-08)")
struct SharedLinksTests {
    let transport = StubTransport()
    let fixtureLinkID = "00000000-0000-4000-8000-000000000210"

    func makeModel() -> SharedLinksModel {
        SharedLinksModel(client: makeClient(transport))
    }

    func link(_ id: String, sharedAgo days: Double, now: Date) -> SharedChatLink {
        let date = now.addingTimeInterval(-days * 86_400)
        return SharedChatLink(chatID: id, shareID: "s-\(id)", title: "Chat \(id)", updatedAt: date, createdAt: date)
    }

    nonisolated static func page(_ count: Int, offset: Int = 0) -> Data {
        let rows = (0..<count).map { index -> JSONValue in
            .object([
                "id": .string("c\(offset + index)"), "chat_id": .string("c\(offset + index)"),
                "share_id": .string("s\(offset + index)"), "title": .string("Chat \(offset + index)"),
                "updated_at": .number(1_792_784_079 - Double(offset + index)), "created_at": .number(1_792_784_079),
            ])
        }
        return (try? JSONEncoder().encode(JSONValue.array(rows))) ?? Data()
    }

    @Test func loadsTheAccountsSharedLinks() async throws {
        try transport.stub("GET", "api/v1/chats/shared", fixture: "chats.shared.json")
        let model = makeModel()
        await model.load()
        #expect(model.links.map(\.chatID) == [fixtureLinkID])
        #expect(model.state == .loaded)
        #expect(!model.hasMore)
    }

    @Test func linksAreGroupedByWhenTheyWereShared() {
        let now = Date(timeIntervalSince1970: 1_792_784_079)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        let sections = SharedLinksModel.sections(
            for: [
                link("today", sharedAgo: 0.01, now: now),
                link("yesterday", sharedAgo: 1, now: now),
                link("week", sharedAgo: 4, now: now),
                link("month", sharedAgo: 20, now: now),
                link("older", sharedAgo: 90, now: now),
            ],
            now: now,
            calendar: calendar
        )
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "July 2026"])
        #expect(sections.map { $0.links.map(\.chatID) } == [["today"], ["yesterday"], ["week"], ["month"], ["older"]])
    }

    @Test func aFullPageMeansThereIsMore() async throws {
        transport.stub("GET", "api/v1/chats/shared") { request in
            let page = request.url?.query()?.contains("page=2") == true ? Self.page(3, offset: 60) : Self.page(60)
            return (200, page)
        }
        let model = makeModel()
        await model.load()
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.links.count == 63)
        #expect(!model.hasMore)
    }

    @Test func deletingALinkRemovesItAndKeepsTheChat() async throws {
        try transport.stub("GET", "api/v1/chats/shared", fixture: "chats.shared.json")
        try transport.stub("DELETE", "api/v1/chats/\(fixtureLinkID)/share", fixture: "chat.unshare.json")
        let model = makeModel()
        await model.load()
        let shared = try #require(model.links.first)

        #expect(await model.delete(shared))
        #expect(model.links.isEmpty)
        #expect(transport.requests.last?.httpMethod == "DELETE")
        #expect(transport.requests.last?.url?.path() == "/api/v1/chats/\(fixtureLinkID)/share")
    }

    @Test func aFailedDeleteKeepsTheLinkAndExplains() async throws {
        try transport.stub("GET", "api/v1/chats/shared", fixture: "chats.shared.json")
        transport.stub("DELETE", "api/v1/chats/\(fixtureLinkID)/share", status: 500, body: Data(#"{"detail":"Nope"}"#.utf8))
        let model = makeModel()
        await model.load()
        let shared = try #require(model.links.first)

        #expect(await model.delete(shared) == false)
        #expect(model.links.count == 1)
        #expect(model.errorMessage != nil)
    }

    @Test func deleteAllClearsTheList() async throws {
        try transport.stub("GET", "api/v1/chats/shared", fixture: "chats.shared.json")
        transport.stub("DELETE", "api/v1/chats/share/all", body: Data("true".utf8))
        let model = makeModel()
        await model.load()
        await model.deleteAll()
        #expect(model.links.isEmpty)
    }

    @Test func theSnapshotShowsTheSharedMessages() async throws {
        try transport.stub("GET", "api/v1/chats/share/s1", fixture: "chat.shared-snapshot.json")
        let model = makeModel()
        let snapshot = try await model.snapshot(for: SharedChatLink(
            chatID: "c", shareID: "s1", title: "T", updatedAt: .now, createdAt: .now
        ))
        #expect(snapshot.messages.count == 2)
        #expect(model.url(for: SharedChatLink(chatID: "c", shareID: "s1", title: "T", updatedAt: .now, createdAt: .now))
            .absoluteString == "https://owui.example.com/s/s1")
    }
}
