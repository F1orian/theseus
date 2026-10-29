import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Chats library endpoints: request shape and decoding of recorded fixtures.
@Suite("Chats library endpoints")
struct ChatLibraryEndpointTests {
    private func decode<R>(_ endpoint: Endpoint<R>, fixture: String) throws -> R {
        try endpoint.decode(Fixture.data(fixture))
    }

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    @Test func listCanIncludeStarredAndProjectChats() {
        let url = request(.chats(page: 3, includeStarred: true, includeProjects: true)).url
        #expect(url?.absoluteString == "https://owui.example.com/api/v1/chats/?page=3&include_pinned=true&include_folders=true")
    }

    @Test func starredChatsAreMarkedStarred() throws {
        let chats = try decode(.starredChats, fixture: "chats.pinned.json")
        let first = try #require(chats.first)
        #expect(first.id == "00000000-0000-4000-8000-000000000200")
        #expect(first.title == "[theseus-test] fixture")
        #expect(chats.allSatisfy { $0.isStarred })
    }

    @Test func searchSendsTextAndPageAndDecodesSnippets() throws {
        let url = request(.searchChats(text: "swift ui", page: 2)).url
        #expect(url?.absoluteString == "https://owui.example.com/api/v1/chats/search?text=swift%20ui&page=2")

        let hits = try decode(.searchChats(text: "the", page: 1), fixture: "chats.search.json")
        #expect(hits.count == Endpoint<[ChatSummary]>.searchPageSize)
        #expect(hits.first?.snippet == "...matching text 1...")
        #expect(hits.contains { $0.isStarred } == false, "search rows don't report Starred")
    }

    @Test func toggleStarPostsAndReturnsTheStarredChat() throws {
        let endpoint = Endpoint<ChatSummary>.toggleStar(chatID: "abc")
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/chats/abc/pin")

        let chat = try decode(endpoint, fixture: "chat.pin.json")
        #expect(chat.id == "00000000-0000-4000-8000-000000000200")
        #expect(chat.isStarred)
        #expect(chat.projectID == nil)
        #expect(chat.createdAt == Date(timeIntervalSince1970: 1_792_780_203))
    }

    @Test func renamePatchesOnlyTheTitle() throws {
        let endpoint = Endpoint<ChatSummary>.renameChat(id: "abc", title: "New \"name\"")
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/chats/abc")
        let body = try JSONDecoder().decode([String: [String: String]].self, from: sent.httpBody ?? Data())
        #expect(body == ["chat": ["title": "New \"name\""]])

        let chat = try decode(endpoint, fixture: "chat.rename.json")
        #expect(chat.title == "[theseus-test] renamed")
        #expect(chat.isStarred, "the recorded Chat was starred before the rename")
    }

    @Test func deleteSendsDeleteAndDecodesTheFlag() throws {
        let endpoint = Endpoint<Bool>.deleteChat(id: "abc")
        #expect(request(endpoint).httpMethod == "DELETE")
        #expect(request(endpoint).url?.path() == "/api/v1/chats/abc")
        let deleted = try decode(endpoint, fixture: "chat.delete.json")
        #expect(deleted)
    }
}
