import ArtCollection
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
@testable import ProjectsFeature
import Synchronization
import Testing

/// Static token so `.required` endpoints are sent.
struct StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

/// A folder as `GET /api/v1/folders/{id}` returns it.
func folderJSON(
    _ id: String,
    name: String? = nil,
    updated: Int = 100,
    theseus: String = "{}",
    data: String = "null"
) -> Data {
    Data("""
    {"id":"\(id)","name":"\(name ?? "Project \(id)")","parent_id":null,"meta":{"theseus":\(theseus)},
     "data":\(data),"created_at":1,"updated_at":\(updated)}
    """.utf8)
}

/// A list row as `GET /api/v1/folders/` returns it (no Theseus metadata, no data).
func folderRowJSON(_ id: String, name: String? = nil, updated: Int = 100) -> String {
    #"{"id":"\#(id)","name":"\#(name ?? "Project \(id)")","meta":{"icon":null},"parent_id":null,"created_at":1,"updated_at":\#(updated)}"#
}

func body(_ request: URLRequest) -> JSONValue? {
    request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
}

@MainActor
@Suite("ProjectLibrary")
struct ProjectLibraryTests {
    let transport = StubTransport()

    func makeLibrary(capabilities: Set<Capability> = [.projects, .fileUpload, .deleteChat]) -> ProjectLibrary {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
        let library = ProjectLibrary(client: client, pollInterval: .milliseconds(1))
        library.capabilities = Capabilities(enabled: capabilities)
        return library
    }

    /// Three Projects: `a` (plain, oldest), `s` (starred, oldest-but-one), `z` (archived, newest).
    func stubThreeProjects() {
        let rows = [folderRowJSON("a", updated: 10), folderRowJSON("s", updated: 20), folderRowJSON("z", updated: 30)]
        transport.stub("GET", "api/v1/folders/", body: Data("[\(rows.joined(separator: ","))]".utf8))
        transport.stub("GET", "api/v1/folders/a", body: folderJSON("a", name: "Alpha", updated: 10, theseus: #"{"description":"Goal A"}"#))
        transport.stub("GET", "api/v1/folders/s", body: folderJSON("s", name: "Starry", updated: 20, theseus: #"{"starred":true}"#))
        transport.stub("GET", "api/v1/folders/z", body: folderJSON("z", name: "Zed", updated: 30, theseus: #"{"archived":true}"#))
    }

    // MARK: Loading and the list (PROJ-01)

    @Test func refreshLoadsDetailsAndHidesArchivedProjects() async {
        stubThreeProjects()
        let library = makeLibrary()
        await library.refresh()
        #expect(library.state == .loaded)
        #expect(library.projects.allSatisfy { $0.hasDetails })
        // Starred first, then newest first; archived only under the Archived filter.
        #expect(library.visibleProjects(filter: .all, query: "").map(\.id) == ["s", "a"])
        #expect(library.visibleProjects(filter: .starred, query: "").map(\.id) == ["s"])
        #expect(library.visibleProjects(filter: .archived, query: "").map(\.id) == ["z"])
        #expect(library.project(id: "a")?.metadata.description == "Goal A")
    }

    @Test func searchMatchesNamesAndDescriptions() async {
        stubThreeProjects()
        let library = makeLibrary()
        await library.refresh()
        #expect(library.visibleProjects(filter: .all, query: "alp").map(\.id) == ["a"])
        #expect(library.visibleProjects(filter: .all, query: "goal").map(\.id) == ["a"])
        #expect(library.visibleProjects(filter: .all, query: "nothing").isEmpty)
    }

    @Test func nothingLoadsWithoutTheCapability() async {
        stubThreeProjects()
        let library = makeLibrary(capabilities: [])
        await library.refresh()
        #expect(library.projects.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func aFailedListKeepsWhatWasShown() async {
        stubThreeProjects()
        let library = makeLibrary()
        await library.refresh()
        transport.stub("GET", "api/v1/folders/", status: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        await library.refresh()
        #expect(library.state == .failed("boom"))
        #expect(library.projects.count == 3)
    }

    // MARK: Create (PROJ-02)

    @Test func createAddsTheProjectWithItsDescription() async throws {
        transport.stub("POST", "api/v1/folders/") { request in
            #expect(body(request)?[path: "meta.theseus.description"]?.stringValue == "Be healthier")
            return (200, folderJSON("new", name: "Meal plan", theseus: #"{"description":"Be healthier"}"#))
        }
        let library = makeLibrary()
        let created = try #require(await library.create(name: "  Meal plan ", description: "Be healthier"))
        #expect(created.name == "Meal plan")
        #expect(library.visibleProjects(filter: .all, query: "").map(\.id) == ["new"])
        #expect(body(transport.requests[0])?[path: "name"]?.stringValue == "Meal plan")
    }

    @Test func createRefusesBlankNamesAndExplainsDuplicates() async {
        let library = makeLibrary()
        #expect(await library.create(name: "   ", description: "x") == nil)
        #expect(transport.requests.isEmpty)

        transport.stub("POST", "api/v1/folders/", status: 400, body: Data(#"{"detail":"[ERROR: Folder already exists]"}"#.utf8))
        #expect(await library.create(name: "Taken", description: "") == nil)
        #expect(library.errorMessage == "A project named “Taken” already exists.")
    }

    // MARK: Star, archive, rename (PROJ-07, PROJ-08)

    @Test func starringWritesTheWholeTheseusNamespace() async {
        stubThreeProjects()
        transport.stub("POST", "api/v1/folders/a/update") { request in
            (200, folderJSON("a", name: "Alpha", updated: 10, theseus: #"{"description":"Goal A","starred":true}"#))
        }
        let library = makeLibrary()
        await library.refresh()
        await library.setStarred("a", true)
        let sent = transport.requests.last { $0.url?.path() == "/api/v1/folders/a/update" }
        #expect(sent.flatMap(body) == .object(["meta": .object(["theseus": .object([
            "description": .string("Goal A"),
            "starred": .bool(true),
        ])])]))
        #expect(library.project(id: "a")?.isStarred == true)
        #expect(library.visibleProjects(filter: .starred, query: "").map(\.id) == ["s", "a"])
    }

    @Test func aRefusedStarRollsBack() async {
        stubThreeProjects()
        transport.stub("POST", "api/v1/folders/a/update", status: 500, body: Data(#"{"detail":"nope"}"#.utf8))
        let library = makeLibrary()
        await library.refresh()
        await library.setStarred("a", true)
        #expect(library.project(id: "a")?.isStarred == false)
        #expect(library.errorMessage == "nope")
    }

    @Test func archivingHidesTheProjectFromTheDefaultList() async {
        stubThreeProjects()
        transport.stub("POST", "api/v1/folders/a/update") { _ in
            (200, folderJSON("a", name: "Alpha", updated: 10, theseus: #"{"description":"Goal A","archived":true}"#))
        }
        let library = makeLibrary()
        await library.refresh()
        await library.setArchived("a", true)
        #expect(library.visibleProjects(filter: .all, query: "").map(\.id) == ["s"])
        #expect(library.visibleProjects(filter: .archived, query: "").map(\.id) == ["z", "a"])
    }

    @Test func renameSendsOnlyTheName() async {
        stubThreeProjects()
        transport.stub("POST", "api/v1/folders/a/update") { _ in (200, folderJSON("a", name: "Renamed", updated: 50)) }
        let library = makeLibrary()
        await library.refresh()
        await library.rename("a", to: " Renamed ")
        let sent = transport.requests.last { $0.url?.path() == "/api/v1/folders/a/update" }
        #expect(sent.flatMap(body) == .object(["name": .string("Renamed")]))
        #expect(library.project(id: "a")?.name == "Renamed")
    }

    // MARK: Instructions (PROJ-04)

    @Test func instructionsAreSavedAsTheFolderSystemPrompt() async {
        stubThreeProjects()
        transport.stub("POST", "api/v1/folders/a/update") { _ in
            (200, folderJSON("a", name: "Alpha", data: #"{"system_prompt":"Be brief"}"#))
        }
        let library = makeLibrary()
        await library.refresh()
        #expect(await library.updateInstructions("a", to: "Be brief"))
        let sent = transport.requests.last { $0.url?.path() == "/api/v1/folders/a/update" }
        #expect(sent.flatMap(body) == .object(["data": .object(["system_prompt": .string("Be brief")])]))
        #expect(library.project(id: "a")?.instructions == "Be brief")
    }

    // MARK: Delete (PROJ-08)

    @Test func deletingCanKeepTheChats() async {
        stubThreeProjects()
        transport.stub("DELETE", "api/v1/folders/a", body: Data("true".utf8))
        let library = makeLibrary()
        let changed = Mutex(0)
        library.onChatsChanged = { changed.withLock { $0 += 1 } }
        await library.refresh()
        #expect(await library.delete("a", deleteChats: false))
        #expect(transport.requests.last?.url?.query() == "delete_contents=false")
        #expect(library.project(id: "a") == nil)
        #expect(changed.withLock { $0 } == 1)
    }

    @Test func deletingAProjectForgetsItsCover() async throws {
        stubThreeProjects()
        transport.stub("DELETE", "api/v1/folders/a", body: Data("true".utf8))
        let library = makeLibrary()
        await library.refresh()
        let other = try #require(library.covers.choices.first { $0 != Artwork.projectCover(for: "a") })
        library.covers.setCover(other, for: "a")
        #expect(library.covers.isChosen(for: "a"))
        #expect(await library.delete("a", deleteChats: false))
        #expect(library.covers.isChosen(for: "a") == false)
    }

    @Test func deletingChatsNeedsTheDeleteChatCapability() async {
        stubThreeProjects()
        transport.stub("DELETE", "api/v1/folders/a", body: Data("true".utf8))
        let library = makeLibrary(capabilities: [.projects])
        await library.refresh()
        #expect(library.canDeleteChats == false)
        #expect(await library.delete("a", deleteChats: true) == false)
        #expect(library.project(id: "a") != nil)
    }

    // MARK: Chats in a Project (PROJ-03, PROJ-06)

    @Test func projectChatsLoadPageByPage() async throws {
        let page: @Sendable (Int) -> Data = { count in
            let rows = (0..<count).map { i in
                #"{"id":"c\#(i)","title":"Chat \#(i)","updated_at":\#(100 - i),"created_at":1}"#
            }
            return Data("[\(rows.joined(separator: ","))]".utf8)
        }
        transport.stub("GET", "api/v1/chats/folder/p/list") { request in
            request.url?.query() == "page=1" ? (200, page(10)) : (200, page(3))
        }
        let library = makeLibrary()
        await library.loadChats(in: "p")
        #expect(library.chats(in: "p").count == 10)
        #expect(library.chatPage(for: "p").hasMore)
        await library.loadMoreChats(in: "p")
        #expect(library.chatPage(for: "p").hasMore == false)
        #expect(library.chats(in: "p").allSatisfy { $0.projectID == "p" })
    }

    @Test func movingAChatConfirmsWithANotice() async throws {
        stubThreeProjects()
        try transport.stub("POST", "api/v1/chats/c1/folder", fixture: "project.chat-move.json")
        let library = makeLibrary()
        await library.refresh()
        let chat = ChatSummary(id: "c1", title: "Lunch", createdAt: .now, updatedAt: .now, isStarred: true)
        let moved = try #require(await library.moveChat(chat, to: "a"))
        #expect(body(transport.requests.last ?? URLRequest(url: Fixture.serverURL)) == .object(["folder_id": .string("a")]))
        #expect(moved.isStarred, "Starred is kept from the local Chat")
        #expect(library.notice == "Chat moved to Alpha")
        #expect(library.chats(in: "a").map(\.id) == ["c1"])
    }

    // MARK: Knowledge (PROJ-05)

    @Test func addingTextUploadsAMarkdownFileAndAttachesIt() async throws {
        stubThreeProjects()
        try transport.stub("POST", "api/v1/files/", fixture: "file.upload.json")
        let polls = Mutex(0)
        transport.stub("GET", "api/v1/files/00000000-0000-4000-8000-000000000520/process/status") { _ in
            let count = polls.withLock { $0 += 1; return $0 }
            return (200, Data(count < 2 ? #"{"status":"pending"}"#.utf8 : #"{"status":"completed"}"#.utf8))
        }
        try transport.stub("GET", "api/v1/files/00000000-0000-4000-8000-000000000520", fixture: "file.json")
        transport.stub("POST", "api/v1/folders/a/update") { request in
            let files = body(request)?[path: "data.files"] ?? .null
            return (200, folderJSON("a", name: "Alpha", data: #"{"files":\#(String(decoding: (try? JSONEncoder().encode(files)) ?? Data(), as: UTF8.self))}"#))
        }
        let library = makeLibrary()
        await library.refresh()

        #expect(await library.addText(to: "a", title: "Meal ideas", content: "Oats"))
        let upload = try #require(transport.requests.first { $0.url?.path() == "/api/v1/files/" })
        let multipart = String(decoding: upload.httpBody ?? Data(), as: UTF8.self)
        #expect(multipart.contains(#"filename="Meal ideas.md""#))
        #expect(multipart.contains("Content-Type: text/markdown\r\n\r\n# Meal ideas\n\nOats\r\n"))
        #expect(polls.withLock { $0 } == 2)
        let knowledge = try #require(library.project(id: "a")?.knowledge)
        #expect(knowledge.map(\.id) == ["00000000-0000-4000-8000-000000000520"])
        #expect(knowledge.first?.reference[path: "collection_name"]?.stringValue == "file-00000000-0000-4000-8000-000000000520")
        #expect(library.uploads(for: "a").isEmpty)
    }

    @Test func aFailedProcessingStaysVisibleAsAFailedUpload() async throws {
        stubThreeProjects()
        try transport.stub("POST", "api/v1/files/", fixture: "file.upload.json")
        transport.stub("GET", "api/v1/files/00000000-0000-4000-8000-000000000520/process/status") { _ in
            (200, Data(#"{"status":"failed","error":"Unsupported file"}"#.utf8))
        }
        let library = makeLibrary()
        await library.refresh()
        #expect(await library.addFile(to: "a", filename: "x.bin", contentType: "application/octet-stream", data: Data([1])) == false)
        #expect(library.uploads(for: "a").map(\.state) == [.failed("Unsupported file")])
        #expect(transport.requests.contains { $0.url?.path() == "/api/v1/folders/a/update" } == false)
    }

    @Test func theServerFileLimitIsRespected() async {
        stubThreeProjects()
        transport.stub("GET", "api/v1/folders/a", body: folderJSON("a", data: #"{"files":[{"type":"file","id":"f1","name":"one.md"}]}"#))
        let library = makeLibrary()
        library.maxKnowledgeFiles = 1
        await library.refresh()
        #expect(library.canAddKnowledge(to: "a") == false)
        #expect(library.canAddKnowledge(to: "s"))
        #expect(makeLibrary(capabilities: [.projects]).canAddKnowledge(to: "s") == false)
    }

    @Test func removingAFileSendsTheRemainingReferences() async {
        stubThreeProjects()
        let files = #"[{"type":"file","id":"f1","name":"one.md"},{"type":"file","id":"f2","name":"two.md","extra":1}]"#
        transport.stub("GET", "api/v1/folders/a", body: folderJSON("a", data: #"{"files":\#(files)}"#))
        transport.stub("POST", "api/v1/folders/a/update") { _ in
            (200, folderJSON("a", data: #"{"files":[{"type":"file","id":"f2","name":"two.md","extra":1}]}"#))
        }
        let library = makeLibrary()
        await library.refresh()
        await library.removeKnowledge("f1", from: "a")
        let sent = transport.requests.last { $0.url?.path() == "/api/v1/folders/a/update" }
        #expect(sent.flatMap(body) == .object(["data": .object(["files": .array([.object([
            "type": .string("file"), "id": .string("f2"), "name": .string("two.md"), "extra": .number(1),
        ])])])]))
        #expect(library.project(id: "a")?.knowledge.map(\.id) == ["f2"])
    }

    @Test func maxFileCountReadsNumbersAndNumericStrings() {
        #expect(ProjectLibrary.maxFileCount(from: ServerFeatures(raw: ["folder_max_file_count": .number(5)])) == 5)
        #expect(ProjectLibrary.maxFileCount(from: ServerFeatures(raw: ["folder_max_file_count": .string("3")])) == 3)
        #expect(ProjectLibrary.maxFileCount(from: ServerFeatures(raw: ["folder_max_file_count": .string("")])) == nil)
        #expect(ProjectLibrary.maxFileCount(from: ServerFeatures(raw: [:])) == nil)
    }
}
