@testable import ArtifactsFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

@Suite("Artifacts library (ART-04)", .serialized)
@MainActor
struct ArtifactLibraryTests {
    /// An export with the recorded artifacts Chat and one plain Chat, one JSON object per line.
    private func exportBody() throws -> Data {
        let recorded = try JSONSerialization.jsonObject(with: StreamFixture("artifacts").data("chat.final.json"))
        let plain: [String: Any] = [
            "id": "plain", "title": "No artifacts", "updated_at": 1, "created_at": 1,
            "chat": ["history": ["currentId": "p1", "messages": ["p1": ["id": "p1", "role": "assistant", "content": "Just text.", "done": true]]]],
        ]
        let lines = try [recorded, plain].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "artifact-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func rebuildIndexesTheExportAndPersistsIt() async throws {
        let ids = try ArtifactIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/all", body: try exportBody())
        let directory = temporaryDirectory()
        let library = ArtifactLibrary(client: makeClient(transport), accountID: "server|user-1", directory: directory)

        await library.open()
        #expect(library.state == .ready)
        #expect(library.items.map(\.artifact.title) == ["Flowchart", "Sun icon", "Tip Calculator"])
        #expect(library.items.last?.versionCount == 2)
        #expect(library.items.last?.artifact.version == 2)
        #expect(Set(library.items.map(\.chatID)) == [ids.chatID])
        #expect(library.catalog(chatID: ids.chatID).count == 4)

        // A second launch shows the saved index and only catches up (no second full export); the
        // saved items stay even when the Server can't be reached.
        let offline = StubTransport()
        let reopened = ArtifactLibrary(client: makeClient(offline), accountID: "server|user-1", directory: directory)
        await reopened.open()
        #expect(reopened.items.map(\.artifact.title) == library.items.map(\.artifact.title))
        #expect(offline.requests.map { $0.url?.path() } == ["/api/v1/chats/"])
        // Another Account on the same device has its own (empty) index.
        let other = ArtifactLibrary(client: makeClient(offline), accountID: "server|user-2", directory: directory)
        await other.open()
        #expect(other.items.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    /// #180: an index built by older detection rules (e.g. with blank snippet "Web pages") is
    /// rebuilt rather than shown.
    @Test func indexesFromOlderDetectionRulesAreRebuilt() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = #"{"version":1,"indexedAt":\#(Date().timeIntervalSinceReferenceDate),"chats":{"old":{"title":"Old","updatedAt":0,"dates":{},"artifacts":[{"id":"m/0","messageID":"m","index":0,"kind":"webPage","origin":"codeBlock","language":"html","title":"Web page","content":"<script></script>","isComplete":true,"version":1}]}}}"#
        try Data(stale.utf8).write(to: directory.appending(path: "a.json"))
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/all", body: try exportBody())
        let library = ArtifactLibrary(client: makeClient(transport), accountID: "a", directory: directory)
        await library.open()
        #expect(!library.items.contains { $0.chatID == "old" })
        #expect(transport.requests.contains { $0.url?.path() == "/api/v1/chats/all" })
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func recordAndRemoveUpdateOneChat() async throws {
        let chat = try await recordedArtifactsChat()
        let library = ArtifactLibrary(client: makeClient(StubTransport()), accountID: "a", directory: nil)
        library.record(chat)
        #expect(library.items.count == 3)
        library.remove(chatID: chat.id)
        #expect(library.items.isEmpty)
    }

    @Test func failuresKeepTheScreenUsable() async {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/all", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        let library = ArtifactLibrary(client: makeClient(transport), accountID: "a", directory: nil)
        await library.open()
        guard case .failed = library.state else {
            Issue.record("expected a failure, got \(library.state)")
            return
        }
    }

    @Test func exportLinesAreFilteredBeforeDecoding() {
        #expect(ArtifactLibrary.mayHoldArtifacts(#"{"content":"```html\n<p>"}"#))
        #expect(ArtifactLibrary.mayHoldArtifacts(#"{"embeds":["<p>x</p>"]}"#))
        #expect(!ArtifactLibrary.mayHoldArtifacts(#"{"content":"plain","embeds":[]}"#))
    }
}

@Suite("Artifacts library catch-up (ART-04)", .serialized)
@MainActor
struct ArtifactLibraryCatchUpTests {
    @Test func openingAFreshIndexOnlyReadsChangedChats() async throws {
        let ids = try ArtifactIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/all", body: Data())
        let library = ArtifactLibrary(client: makeClient(transport), accountID: "a", directory: nil)
        await library.rebuild()
        #expect(library.items.isEmpty)

        // The recorded Chat changed after the rebuild: the next open fetches just that one.
        let summary = #"[{"id":"\#(ids.chatID)","title":"Tip Calculator","updated_at":\#(Int(Date().timeIntervalSince1970) + 60),"created_at":1}]"#
        transport.stub("GET", "api/v1/chats/", body: Data(summary.utf8))
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try StreamFixture("artifacts").data("chat.final.json"))
        await library.open()
        #expect(library.state == .ready)
        #expect(library.items.count == 3)
        #expect(transport.requests.filter { $0.url?.path() == "/api/v1/chats/all" }.count == 1)

        // Deleted on the Server (gone from the Chat list): the next catch-up drops its Artifacts.
        transport.stub("GET", "api/v1/chats/", body: Data("[]".utf8))
        await library.catchUp()
        #expect(library.items.isEmpty)
    }
}
