@testable import ArtifactsFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// The hand-written Chat imported from Claude (`synthetic/chat.claude-import.json`, made by
/// `scripts/fixtures/make_claude_import_fixture.py`): Artifacts as `artifacts` tool calls.
enum ImportedChat {
    static let id = "00000000-0000-4000-8000-0000000c1a00"

    static func data() throws -> Data {
        try Fixture.data("synthetic/chat.claude-import.json")
    }

    static func load() async throws -> Chat {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(id)", body: try data())
        return try await makeClient(transport).send(.chat(id: id)).chat
    }

    /// The fixture as one line of the NDJSON export.
    static func exportLine() throws -> String {
        let object = try JSONSerialization.jsonObject(with: data())
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// #180: the library missed every Artifact of the Chats imported from Claude.
@Suite("Artifacts imported from Claude")
@MainActor
struct ImportedArtifactsTests {
    @Test func toolCallsBecomeVersionedArtifacts() async throws {
        let chat = try await ImportedChat.load()
        let catalog = ArtifactCatalog(responses: ArtifactCatalog.responses(thread: chat.tree.activePath))
        #expect(catalog.artifacts.map(\.title) == ["Garden Plan", "Garden Plan", "Garden Plan", "Watering Timer", "water.py", "Watering Timer"])
        #expect(catalog.artifacts.map(\.kind) == [.document, .document, .document, .webPage, .code, .webPage])
        #expect(catalog.artifacts.allSatisfy { $0.origin == .importedTool && $0.isComplete })

        // create → update (applied) → update whose `old_str` isn't there: kept and marked.
        let plan = catalog.artifacts.filter { $0.identifier == "garden_plan" }
        #expect(plan.map(\.version) == [1, 2, 3])
        #expect(!plan[0].content.contains("basil"))
        #expect(plan[1].content.contains("- Tomatoes along the fence, basil between them"))
        #expect(plan[2].content == plan[1].content)
        #expect(plan.map(\.isStale) == [false, false, true])

        // rewrite: a new version with the new content, the title and kind carried over.
        let page = catalog.artifacts.filter { $0.identifier == "watering_timer" }
        #expect(page.map(\.version) == [1, 2])
        #expect(page[1].content.contains("Bewässerungs-Timer"))
        #expect(page.allSatisfy { $0.hasPreview && $0.language == "html" })

        let script = try #require(catalog.artifacts.first { $0.identifier == "water_script" })
        #expect(script.language == "python")
        #expect(!script.hasPreview)
        #expect(script.fileExtension == "py")
        #expect(script.typeLabel == "Code")

        #expect(catalog.latestVersions.map(\.title) == ["Watering Timer", "water.py", "Garden Plan"])
        // Each call's card finds its version.
        let callID = try #require(plan[1].callID)
        #expect(catalog.artifact(messageID: plan[1].messageID, callID: callID) == plan[1])
    }

    @Test func malformedOrForeignCallsAreSkipped() {
        let steps = [
            ToolActivity(id: "a", name: "artifacts", arguments: "not json", isRunning: false),
            ToolActivity(id: "b", name: "artifacts", arguments: #"{"command":"update","id":"never_created","old_str":"x","new_str":"y"}"#, isRunning: false),
            ToolActivity(id: "c", name: "web_search", arguments: #"{"command":"create","id":"x","content":"y"}"#, isRunning: false),
            ToolActivity(id: "d", name: "artifacts", arguments: #"{"command":"create","id":"svg","type":"image/svg+xml","title":"","content":"<svg/>"}"#, isRunning: false),
        ]
        let catalog = ArtifactCatalog(responses: [ArtifactCatalog.Response(messageID: "m", text: "", toolCalls: steps)])
        #expect(catalog.artifacts.map(\.kind) == [.image])
        #expect(catalog.artifacts.first?.title == "Artifact")
        #expect(catalog.artifacts.first?.id == "m/0")
    }

    @Test func theLibraryIndexesImportedChats() async throws {
        let line = try ImportedChat.exportLine()
        #expect(ArtifactLibrary.mayHoldArtifacts(line))
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/all", body: Data((line + "\n").utf8))
        let library = ArtifactLibrary(client: makeClient(transport), accountID: "a", directory: nil)
        await library.rebuild()
        #expect(library.state == .ready)
        #expect(library.items.map(\.artifact.title) == ["Watering Timer", "water.py", "Garden Plan"])
        #expect(library.items.map(\.versionCount) == [2, 1, 3])
        #expect(library.catalog(chatID: ImportedChat.id).count == 6)
    }
}
