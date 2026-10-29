import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Projects (server term: folders) and knowledge-file endpoints: request shape and decoding of
/// recorded fixtures (PROJ-01…08).
@Suite("Project endpoints")
struct ProjectEndpointTests {
    private let fixtureProjectID = "00000000-0000-4000-8000-000000000500"
    private let fixtureChatID = "00000000-0000-4000-8000-000000000510"
    private let fixtureFileID = "00000000-0000-4000-8000-000000000520"

    private func decode<R>(_ endpoint: Endpoint<R>, fixture: String) throws -> R {
        try endpoint.decode(Fixture.data(fixture))
    }

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    private func jsonBody(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
    }

    // MARK: List and details

    @Test func listRowsHaveNoDetails() throws {
        #expect(request(.projects).url?.absoluteString == "https://owui.example.com/api/v1/folders/")
        let projects = try decode(.projects, fixture: "projects.json")
        let project = try #require(projects.first)
        #expect(project.id == fixtureProjectID)
        #expect(project.name == "[theseus-test] Fixture project")
        #expect(project.updatedAt == Date(timeIntervalSince1970: 1_792_789_042))
        // The list endpoint only returns meta.icon, so Theseus metadata and data are unknown.
        #expect(project.hasDetails == false)
        #expect(project.isStarred == false)
        #expect(project.knowledge.isEmpty)
    }

    @Test func detailsCarryTheseusMetadataInstructionsAndKnowledge() throws {
        let endpoint = Endpoint<Project>.projectDetails(id: "p1")
        #expect(request(endpoint).url?.path() == "/api/v1/folders/p1")
        let project = try decode(endpoint, fixture: "project.json")
        #expect(project.hasDetails)
        #expect(project.metadata.description == "Plan healthy meals")
        #expect(project.isStarred)
        #expect(project.isArchived == false)
        #expect(project.instructions == "Answer briefly.")
        let file = try #require(project.knowledge.first)
        #expect(file.id == fixtureFileID)
        #expect(file.name == "theseus-test-notes.md")
        #expect(file.size == 52)
        #expect(file.reference[path: "collection_name"]?.stringValue == "file-\(fixtureFileID)")
    }

    @Test func nullMetaAndDataDecodeAsEmpty() throws {
        let json = #"{"id":"p","name":"n","meta":null,"data":null,"parent_id":null,"created_at":1,"updated_at":2}"#
        let project = try Endpoint<Project>.projectDetails(id: "p").decode(Data(json.utf8))
        #expect(project.hasDetails)
        #expect(project.metadata == ProjectMetadata())
        #expect(project.instructions.isEmpty)
    }

    // MARK: Create and update

    @Test func createSendsNameAndNamespacedDescription() throws {
        let endpoint = Endpoint<Project>.createProject(name: "Meal plan", description: "Be healthier")
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/folders/")
        let body = try jsonBody(sent)
        #expect(body == .object([
            "name": .string("Meal plan"),
            "meta": .object(["theseus": .object(["description": .string("Be healthier")])]),
        ]))

        let created = try decode(endpoint, fixture: "project.create.json")
        #expect(created.name == "[theseus-test] Fixture project")
        #expect(created.metadata.description == "Plan healthy meals")
    }

    @Test func createWithoutDescriptionSendsNoMeta() throws {
        let body = try jsonBody(request(.createProject(name: "Plain", description: "  ")))
        #expect(body == .object(["name": .string("Plain")]))
    }

    @Test func updateSendsTheWholeTheseusNamespaceAndKeepsUnknownKeys() throws {
        var metadata = ProjectMetadata(description: "Goal", isStarred: true)
        metadata.extras = ["futureKey": .number(1)]
        let endpoint = Endpoint<Project>.updateProject(id: "p1", ProjectUpdate(metadata: metadata))
        let sent = request(endpoint)
        #expect(sent.url?.path() == "/api/v1/folders/p1/update")
        let body = try jsonBody(sent)
        // meta merges shallowly on the server, so `theseus` is always sent complete.
        #expect(body == .object([
            "meta": .object(["theseus": .object([
                "description": .string("Goal"),
                "starred": .bool(true),
                "futureKey": .number(1),
            ])]),
        ]))
    }

    @Test func updateSendsOnlyTheChangedParts() throws {
        let rename = try jsonBody(request(.updateProject(id: "p", ProjectUpdate(name: "New"))))
        #expect(rename == .object(["name": .string("New")]))

        let instructions = try jsonBody(request(.updateProject(id: "p", ProjectUpdate(instructions: "Be brief"))))
        #expect(instructions == .object(["data": .object(["system_prompt": .string("Be brief")])]))

        let project = try decode(.projectDetails(id: "p"), fixture: "project.json")
        let files = try jsonBody(request(.updateProject(id: "p", ProjectUpdate(knowledge: project.knowledge))))
        let reference = try #require(project.knowledge.first?.reference)
        #expect(files == .object(["data": .object(["files": .array([reference])])]))

        let updated = try decode(.updateProject(id: "p", ProjectUpdate(name: "x")), fixture: "project.update.json")
        #expect(updated.isStarred)
        #expect(updated.instructions == "Answer briefly.")
    }

    @Test func deleteChoosesWhetherChatsGoToo() throws {
        let keep = request(.deleteProject(id: "p", deleteChats: false))
        #expect(keep.httpMethod == "DELETE")
        #expect(keep.url?.absoluteString == "https://owui.example.com/api/v1/folders/p?delete_contents=false")
        let purge = request(.deleteProject(id: "p", deleteChats: true))
        #expect(purge.url?.query() == "delete_contents=true")
        #expect(try decode(.deleteProject(id: "p", deleteChats: true), fixture: "project.delete.json"))
    }

    // MARK: Chats in a Project

    @Test func projectChatsArePagedAndTagged() throws {
        let endpoint = Endpoint<[ChatSummary]>.projectChats(projectID: "p1", page: 2)
        #expect(request(endpoint).url?.absoluteString == "https://owui.example.com/api/v1/chats/folder/p1/list?page=2")
        let chats = try decode(.projectChats(projectID: fixtureProjectID, page: 1), fixture: "project.chats.json")
        #expect(chats.map(\.id) == [fixtureChatID])
        #expect(chats.allSatisfy { $0.projectID == fixtureProjectID })
        #expect(Endpoint<[ChatSummary]>.projectChatsPageSize == 10)
    }

    @Test func moveChatPostsTheFolderAndReturnsTheChat() throws {
        let endpoint = Endpoint<ChatSummary>.moveChat(id: "c1", toProject: "p1")
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/chats/c1/folder")
        #expect(try jsonBody(sent) == .object(["folder_id": .string("p1")]))
        #expect(try jsonBody(request(.moveChat(id: "c1", toProject: nil))) == .object(["folder_id": .null]))

        let chat = try decode(endpoint, fixture: "project.chat-move.json")
        #expect(chat.id == fixtureChatID)
        #expect(chat.projectID == fixtureProjectID)
        #expect(chat.isStarred == false)
    }

    // MARK: Files

    @Test func uploadSendsMultipartAndDecodesTheFile() throws {
        let endpoint = Endpoint<UploadedFile>.uploadFile(
            filename: "Notes \"1\".md",
            contentType: "text/markdown",
            data: Data("# Hi".utf8)
        )
        let sent = request(endpoint)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://owui.example.com/api/v1/files/?process=true&process_in_background=true")
        let contentType = try #require(sent.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.contains(#"Content-Disposition: form-data; name="file"; filename="Notes 1.md""#))
        #expect(body.contains("Content-Type: text/markdown\r\n\r\n# Hi\r\n"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))

        let file = try decode(endpoint, fixture: "file.upload.json")
        #expect(file.id == fixtureFileID)
        #expect(file.name == "theseus-test-notes.md")
        #expect(file.size == 52)
        #expect(file.contentType == "text/markdown")
        #expect(file.collectionName == nil, "the collection exists only after processing")
    }

    @Test func processingStatusAndFileDetails() throws {
        let status = Endpoint<FileProcessingStatus>.fileProcessingStatus(id: "f1")
        #expect(request(status).url?.path() == "/api/v1/files/f1/process/status")
        #expect(try decode(status, fixture: "file.process-status.json") == .completed)
        #expect(try status.decode(Data(#"{"status":"pending"}"#.utf8)) == .pending)
        #expect(try status.decode(Data(#"{"status":"failed","error":"Unsupported"}"#.utf8)) == .failed("Unsupported"))

        let details = try decode(.fileDetails(id: "f1"), fixture: "file.json")
        #expect(details.collectionName == "file-\(fixtureFileID)")
    }

    @Test func knowledgeReferenceFromAnUploadedFile() throws {
        let uploaded = try decode(.fileDetails(id: "f"), fixture: "file.json")
        let file = KnowledgeFile(uploaded: uploaded)
        #expect(file.id == fixtureFileID)
        #expect(file.reference == .object([
            "type": .string("file"),
            "id": .string(fixtureFileID),
            "url": .string(fixtureFileID),
            "name": .string("theseus-test-notes.md"),
            "size": .number(52),
            "content_type": .string("text/markdown"),
            "collection_name": .string("file-\(fixtureFileID)"),
            "status": .string("uploaded"),
        ]))
    }
}
