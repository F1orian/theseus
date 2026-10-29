import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

private final class Token: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

private func client(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: Token())
}

@Suite("Files (ATT-01/02/04)")
struct FileEndpointTests {
    @Test func uploadSendsOneMultipartFileAndDecodesTheRecordedDocument() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.document.json")
        let file = try await client(transport).send(.uploadFile(filename: "notes \"draft\".txt", contentType: "text/plain", data: Data("hello".utf8)))

        #expect(file.name == "[theseus-test] atlas.txt")
        #expect(file.contentType == "text/plain")
        #expect(file.size == 65)
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(request.url?.query()?.contains("process=true") == true)
        #expect(request.url?.query()?.contains("process_in_background=true") == true)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"notes draft.txt\""))
        #expect(body.contains("Content-Type: text/plain\r\n\r\nhello\r\n--"))
    }

    @Test func imagesUploadWithoutProcessing() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.image.json")
        let file = try await client(transport).send(.uploadFile(filename: "a.png", contentType: "image/png", data: Data([1]), process: false))
        #expect(file.reference.isImage)
        #expect(transport.requests.first?.url?.query() == "process=false")
    }

    @Test func processingStatusDecodesCompletedAndFailed() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/files/f1/process/status", fixture: "stream/attachments.status.document.json")
        transport.stub("GET", "api/v1/files/f2/process/status", body: Data(#"{"status":"failed","error":"Unsupported"}"#.utf8))
        let completed = try await client(transport).send(.fileProcessingStatus(id: "f1"))
        let failed = try await client(transport).send(.fileProcessingStatus(id: "f2"))
        #expect(completed == .completed)
        #expect(failed == .failed("Unsupported"))
    }

    @Test func fileContentReturnsRawBytes() async throws {
        let transport = StubTransport()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        transport.stub("GET", "api/v1/files/f1/content", body: png)
        #expect(try await client(transport).send(.fileContent(id: "f1")) == png)
    }

    @Test func storedUserMessagesCarryTheirAttachments() throws {
        let data = try StreamFixture("attachments").data("chat.final.json")
        let chat = try WireCoding.decoder.decode(ChatWire.self, from: data).domain
        let user = try #require(chat.tree.activePath.first { $0.role == .user })
        #expect(user.attachments.map(\.kind) == [.document, .image])
        #expect(user.attachments[0].name == "[theseus-test] atlas.txt")
        #expect(user.attachments[0].typeBadge == "TXT")
        #expect(user.attachments[1].contentType == "image/png")
        #expect(user.attachments.allSatisfy { $0.isServerFile })
        let assistant = try #require(chat.tree.activePath.last)
        #expect(assistant.attachments.isEmpty)
        #expect(assistant.content.contains("Poseidonia"))
    }

    @Test func inlineImagesAndOtherReferenceTypes() {
        let image: JSONValue = .object(["type": .string("image"), "url": .string("data:image/png;base64,AAAA")])
        let collection: JSONValue = .object(["type": .string("collection"), "id": .string("kb")])
        #expect(MessageWire.attachment(from: image, index: 2)?.url == "data:image/png;base64,AAAA")
        #expect(MessageWire.attachment(from: image, index: 2)?.isServerFile == false)
        #expect(MessageWire.attachment(from: collection, index: 0) == nil)
    }

    @Test func socketBodyCarriesFilesAndOnlyDocumentsForRetrieval() throws {
        var request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi", userMessageID: "u", assistantMessageID: "a")
        let doc = FileReference(id: "d1", name: "a.pdf", contentType: "application/pdf", size: 10)
        let photo = FileReference(id: "i1", name: "p.jpg", contentType: "image/jpeg", size: 5)
        let earlier = FileReference(id: "d0", name: "old.txt", contentType: "text/plain", size: 1)
        request.files = [doc, photo]
        request.contextFiles = [earlier, doc]
        request.params = ["reasoning_effort": .string("high")]
        let body = try WireCoding.decoder.decode(JSONValue.self, from: CompletionSession.socketBody(request, sessionID: "sid"))
        let messageFiles = body[path: "user_message.files"]?.arrayValue ?? []
        #expect(messageFiles.compactMap { $0[path: "id"]?.stringValue } == ["d1", "i1"])
        #expect(messageFiles.first?[path: "type"]?.stringValue == "file")
        #expect(messageFiles.first?[path: "url"]?.stringValue == "d1")
        #expect(messageFiles.last?[path: "content_type"]?.stringValue == "image/jpeg")
        #expect((body[path: "files"]?.arrayValue ?? []).compactMap { $0[path: "id"]?.stringValue } == ["d0", "d1"])
        #expect(body[path: "params.reasoning_effort"]?.stringValue == "high")
    }

    @Test func socketBodyWithoutAttachmentsHasNoTopLevelFiles() throws {
        let request = CompletionRequest(chatID: nil, modelID: "m", prompt: "hi")
        let body = try WireCoding.decoder.decode(JSONValue.self, from: CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(body[path: "files"] == nil)
        #expect(body[path: "user_message.files"]?.arrayValue?.isEmpty == true)
    }
}

@Suite("Models, config and settings for the composer (MODEL-01..04)")
struct ComposerEndpointTests {
    @Test func modelControlsKeepTheAdminsOrder() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/models", fixture: "synthetic/models.model-controls.json")
        let models = try await client(transport).send(.models)
        let reasoner = try #require(models.first)
        #expect(reasoner.controls.map(\.id) == ["thinking", "effort", "verbosity"])
        let effort = try #require(reasoner.controls.first { $0.id == "effort" })
        #expect(effort.options.map(\.label) == ["Low", "Medium", "High", "Max"])
        #expect(effort.defaultOptionID == "low")
        #expect(effort.description == "How long the model reasons")
        #expect(reasoner.controls[2].display == .slider)
        #expect(reasoner.controls[2].options.map(\.id) == ["terse", "normal", "chatty"])
        #expect(reasoner.isOpenAICompatible)
        #expect(models[1].controls.isEmpty)
        #expect(!models[1].isOpenAICompatible)
    }

    @Test func recordedModelsHaveNoControls() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/models", fixture: "models.json")
        let models = try await client(transport).send(.models)
        #expect(models.count == 5)
        #expect(models.allSatisfy { $0.controls.isEmpty && $0.isOpenAICompatible })
    }

    @Test func keyOrderScannerHandlesEscapesAndNesting() throws {
        let json = #"{"b": {"x\"y": 1, "a": [1, {"q": true}], "z": null}, "a": "s,}"}"#
        let order = try #require(JSONKeyOrder(Data(json.utf8)))
        #expect(order.keys(at: []) == ["b", "a"])
        #expect(order.keys(at: ["b"]) == ["x\"y", "a", "z"])
        #expect(order.keys(at: ["b", "a", 1]) == ["q"])
        #expect(order.keys(at: ["missing"]).isEmpty)
        #expect(JSONKeyOrder(Data("{".utf8)) == nil)
    }

    @Test func configFileLimitsAndPinnedModels() throws {
        let recorded = try WireCoding.decoder.decode(ServerConfig.self, from: Fixture.data("config.json"))
        #expect(recorded.fileLimits == FileLimits())
        #expect(recorded.defaultPinnedModelIDs.isEmpty)
        let configured = try WireCoding.decoder.decode(ServerConfig.self, from: Fixture.data("synthetic/config.file-limits.json"))
        #expect(configured.fileLimits == FileLimits(maxSizeMB: 10, maxCount: 3, imageMaxWidth: 1024, imageMaxHeight: nil))
        #expect(configured.defaultModelIDs == ["a", "b"])
        #expect(configured.defaultPinnedModelIDs == ["b", "c"])
    }

    @Test func bannersDecode() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/configs/banners", fixture: "synthetic/banners.json")
        let banners = try await client(transport).send(.banners)
        #expect(banners.map(\.kind) == [.warning, .info])
        #expect(banners[1].isDismissible == false)
        try transport.stub("GET", "api/v1/configs/banners", fixture: "banners.json")
        #expect(try await client(transport).send(.banners).isEmpty)
    }

    @Test func userSettingsExposeNicknameModelsAndPins() throws {
        let settings = UserSettings(raw: [
            "ui": .object(["models": .array([.string("claude-sonnet-5-5")]), "pinnedModels": .array([.string("a"), .string("")])]),
            "theseus": .object([
                "profile": .object(["nickname": .string("  Lex ")]),
                "models": .object(["defaultModelID": .string("claude-haiku-5-5")]),
            ]),
        ])
        #expect(settings.nickname == "Lex")
        #expect(settings.webClientDefaultModelIDs == ["claude-sonnet-5-5"])
        #expect(settings.pinnedModelIDs == ["a"])
        #expect(settings.modelPreferences.defaultModelID == "claude-haiku-5-5")
        #expect(!settings.hasCapabilityDefaults)
        let empty = try WireCoding.decoder.decode(UserSettings.self, from: Fixture.data("user-settings.json"))
        #expect(empty.nickname == nil)
        #expect(empty.modelPreferences == ModelPreferences())
        #expect(empty.pinnedModelIDs.isEmpty)
    }

    @Test func modelControlsNeedBothPermissions() throws {
        let features = ServerFeatures(raw: [:])
        func user(_ chat: [String: Bool]) throws -> SessionUser {
            let permissions = JSONValue.object(["chat": .object(chat.mapValues(JSONValue.bool))])
            let json = JSONValue.object(["id": .string("u"), "email": .string("e"), "name": .string("n"), "role": .string("user"), "permissions": permissions])
            return try WireCoding.decoder.decode(SessionUser.self, from: WireCoding.encoder.encode(json))
        }
        let paramsOnly = Capabilities.resolve(features: features, user: try user(["params": true]), model: nil)
        #expect(paramsOnly.contains(.modelParams))
        #expect(!paramsOnly.contains(.modelControls))
        let both = Capabilities.resolve(features: features, user: try user(["params": true, "controls": true]), model: nil)
        #expect(both.contains(.modelControls))
        let neither = Capabilities.resolve(features: features, user: try user([:]), model: nil)
        #expect(!neither.contains(.modelParams))
    }
}
