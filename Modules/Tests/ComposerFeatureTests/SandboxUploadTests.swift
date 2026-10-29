@testable import ComposerFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Attachments into the sandbox (OT-05): when the model's terminal takes uploads
/// (`chat_uploads: "filesystem"`), files go to `files/upload` in the Chat's session and the
/// Message refers to them by path; otherwise the normal pipeline runs.
@MainActor
@Suite("Sandbox uploads")
struct SandboxUploadTests {
    private var coder: Model {
        var coder = model("coder", capabilities: ["file_upload": true, "terminal": true])
        coder.terminalID = "demo-sandbox"
        return coder
    }

    private func composer(_ transport: StubTransport, uploadMode: TerminalServer.UploadMode) -> ComposerModel {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
        // Capabilities here don't come from a terminal list, so stand in for the resolved sandbox.
        let services = ComposerServices(client: client, models: [coder], defaultModelIDs: []) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        services.setTerminals([TerminalServer(id: "demo-sandbox", name: "Sandbox", uploadMode: uploadMode)])
        let composer = ComposerModel(services: services, selectedModelID: "coder")
        composer.chatID = "c1"
        return composer
    }

    @Test func filesystemTerminalsTakeAttachmentsIntoTheChatsSession() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/terminals/demo-sandbox/chats/c1/files/cwd", body: try StreamFixture("sandbox").data("files.cwd.json"))
        transport.stub("POST", "api/v1/terminals/demo-sandbox/chats/c1/files/upload", body: Data(#"{"path":"/home/user/data.csv","size":4}"#.utf8))
        let composer = composer(transport, uploadMode: .filesystem)
        #expect(composer.sandboxUploadTerminal?.id == "demo-sandbox")
        composer.attach([PendingAttachment(data: Data("a,b\n".utf8), filename: "data.csv", contentType: "text/csv", source: .files)])
        #expect(await until { composer.attachments.first?.phase == .ready })

        let upload = try #require(transport.requests.first { $0.url?.path().hasSuffix("/files/upload") == true })
        #expect(upload.url?.query()?.contains("directory=/home/user") == true)
        #expect(!transport.requests.contains { $0.url?.path() == "/api/v1/files/" }, "nothing reaches the Server's file store")

        let reference = try #require(composer.attachments.first?.file)
        #expect(reference.sandbox == SandboxPlacement(terminalID: "demo-sandbox", path: "/home/user/data.csv", sessionID: "c1"))
        #expect(reference.jsonValue[path: "type"]?.stringValue == "filesystem")
        #expect(reference.jsonValue[path: "path"]?.stringValue == "/home/user/data.csv")
        #expect(reference.jsonValue[path: "terminal_id"]?.stringValue == "demo-sandbox")
        #expect(reference.jsonValue[path: "session_id"]?.stringValue == "c1")

        // Sandbox files are read in the sandbox: they never join retrieval.
        var request = CompletionRequest(chatID: "c1", modelID: "coder", prompt: "analyse it")
        request.files = [reference]
        #expect(request.retrievalFiles.isEmpty)
        // Removing it doesn't touch the Server's file store.
        if let id = composer.attachments.first?.id { composer.remove(id) }
        #expect(!transport.requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test func defaultTerminalsKeepTheNormalPipeline() {
        let composer = composer(StubTransport(), uploadMode: .default)
        #expect(composer.sandboxUploadTerminal == nil)
        composer.set(.codeInterpreter, on: false)
        let filesystem = self.composer(StubTransport(), uploadMode: .filesystem)
        filesystem.set(.codeInterpreter, on: false)
        #expect(filesystem.sandboxUploadTerminal == nil, "with Code execution off, uploads take the normal path")
    }
}
