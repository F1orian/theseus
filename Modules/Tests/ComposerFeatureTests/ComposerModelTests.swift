@testable import ComposerFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization
import Testing
import UniformTypeIdentifiers

final class StaticToken: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

/// The recorded document upload's id.
func uploadedDocument() throws -> (id: String, name: String) {
    let json = try JSONDecoder().decode(JSONValue.self, from: StreamFixture("attachments").data("upload.document.json"))
    return (json[path: "id"]?.stringValue ?? "", json[path: "meta.name"]?.stringValue ?? "")
}

@MainActor
func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

let vision = model("sonnet", capabilities: ["vision": true, "file_upload": true, "web_search": true])
let blind = model("blind", capabilities: ["vision": false, "file_upload": false])

@MainActor
func makeServices(
    _ transport: StubTransport,
    models: [Model] = [vision, blind],
    capabilities: Set<Capability> = Set(Capability.allCases).subtracting([.modelControls]),
    defaults: [String] = []
) -> ComposerServices {
    let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
    let services = ComposerServices(client: client, models: models, defaultModelIDs: defaults) { model in
        guard let admin = SessionUserFixture.admin else { return Capabilities(enabled: []) }
        return Capabilities.resolve(
            features: ServerFeatures(raw: ["enable_web_search": .bool(true)]),
            user: admin,
            model: model
        ).intersection(capabilities)
    }
    services.processingPollInterval = .milliseconds(10)
    return services
}

enum SessionUserFixture {
    static let admin: SessionUser? = {
        let json = #"{"id":"u","email":"e@example.com","name":"Alexandra Stone","role":"admin","permissions":{}}"#
        return try? JSONDecoder().decode(SessionUser.self, from: Data(json.utf8))
    }()
}

extension Capabilities {
    func intersection(_ allowed: Set<Capability>) -> Capabilities {
        Capabilities(enabled: enabled.intersection(allowed))
    }
}

@Suite("Composer (HOME-02, ATT-01..04)", .serialized)
@MainActor
struct ComposerModelTests {
    @Test func sendStateFollowsContentAndUploads() async throws {
        let transport = StubTransport()
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: vision.id)
        #expect(!composer.hasContent)
        #expect(!composer.isReady)
        #expect(composer.placeholder(isNewChat: true) == "Chat with Sonnet")
        #expect(composer.placeholder(isNewChat: false) == "Reply to Sonnet")
        composer.text = "  \n "
        #expect(!composer.hasContent)
        composer.text = "Hello"
        #expect(composer.isReady)
        let submission = try #require(composer.submission())
        #expect(submission.text == "Hello")
        #expect(submission.modelID == vision.id)
        #expect(submission.files.isEmpty)
        // The model starts with web search off (no defaults); image generation isn't enabled on the Server.
        #expect(submission.features == ["web_search": false])
        composer.reset()
        #expect(composer.text.isEmpty)
    }

    @Test func documentsUploadProcessAndBecomeReady() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.document.json")
        let uploaded = try uploadedDocument()
        let polls = Mutex(0)
        transport.stub("GET", "api/v1/files/\(uploaded.id)/process/status") { _ in
            let count = polls.withLock { $0 += 1; return $0 }
            return (200, Data(#"{"status":"\#(count < 3 ? "pending" : "completed")"}"#.utf8))
        }
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: vision.id)
        composer.attach([PendingAttachment(data: Data("Poseidonia".utf8), filename: "atlas.txt", source: .files)])
        #expect(composer.attachments.count == 1)
        #expect(composer.attachments[0].kind == .document)
        #expect(composer.attachments[0].badge == "TXT")
        #expect(composer.hasContent)
        #expect(!composer.isReady)
        #expect(await until { composer.attachments.first?.phase == .processing })
        #expect(await until { composer.attachments.first?.phase == .ready })
        #expect(polls.withLock { $0 } == 3)
        #expect(composer.isReady)
        let submission = try #require(composer.submission())
        #expect(submission.text.isEmpty)
        #expect(submission.files.map(\.id) == [uploaded.id])
        #expect(submission.attachments.first?.kind == .document)
        let request = try #require(transport.requests.first { $0.httpMethod == "POST" })
        #expect(request.url?.query()?.contains("process=true") == true)
    }

    @Test func failedProcessingBlocksSending() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.document.json")
        let uploaded = try uploadedDocument()
        transport.stub("GET", "api/v1/files/\(uploaded.id)/process/status", body: Data(#"{"status":"failed","error":"Empty document"}"#.utf8))
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: vision.id)
        composer.text = "Read this"
        composer.attach([PendingAttachment(data: Data("x".utf8), filename: "a.txt", source: .files)])
        #expect(await until { composer.attachments.first?.phase == .failed("Empty document") })
        #expect(composer.blockingIssue != nil)
        #expect(composer.submission() == nil)
        composer.remove(try #require(composer.attachments.first?.id))
        #expect(composer.isReady)
        // The upload on the Server is cleaned up.
        #expect(await until { transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path().hasSuffix(uploaded.id) == true } })
    }

    @Test func photosUploadUnprocessedWithAThumbnail() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.image.json")
        let services = makeServices(transport)
        let composer = ComposerModel(services: services, selectedModelID: vision.id)
        let heic = ImageProcessingTests.image(width: 64, height: 48, type: .heic)
        try #require(!heic.isEmpty)
        composer.attach([PendingAttachment(data: heic, filename: "IMG_1.HEIC", contentType: "image/heic", source: .photos)])
        #expect(await until { composer.attachments.first?.phase == .ready })
        let attachment = try #require(composer.attachments.first)
        #expect(attachment.kind == .image)
        #expect(attachment.thumbnail != nil)
        #expect(attachment.name == "IMG_1.jpg")
        let fileID = try #require(attachment.file?.id)
        #expect(services.images.cached(fileID) != nil)
        let request = try #require(transport.requests.first)
        #expect(request.url?.query() == "process=false")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("filename=\"IMG_1.jpg\""))
        #expect(body.contains("Content-Type: image/jpeg"))
    }

    @Test func attachmentsAreGatedByTheModelsCapabilities() {
        let transport = StubTransport()
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: blind.id)
        #expect(!composer.canAttachPhotos)
        #expect(!composer.canAttachFiles)
        composer.attach([PendingAttachment(data: Data([1]), filename: "p.jpg", source: .camera)])
        #expect(composer.attachments.isEmpty)
        #expect(composer.notice == "Blind can't see images.")
        composer.attach([PendingAttachment(data: Data([1]), filename: "a.pdf", source: .files)])
        #expect(composer.notice == "Blind can't read files.")
        #expect(transport.requests.isEmpty)
    }

    @Test func switchingToABlindModelBlocksQueuedImages() async throws {
        let transport = StubTransport()
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.image.json")
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: vision.id)
        composer.attach([PendingAttachment(data: ImageProcessingTests.image(width: 8, height: 8, type: .png), filename: "a.png", source: .photos)])
        #expect(await until { composer.attachments.first?.phase == .ready })
        composer.select(blind.id)
        #expect(composer.blockingIssue?.contains("can't see images") == true)
        #expect(!composer.isReady)
    }

    @Test func limitsFromTheServerApply() throws {
        let transport = StubTransport()
        let services = makeServices(transport)
        let config = try JSONDecoder().decode(ServerConfig.self, from: Fixture.data("synthetic/config.file-limits.json"))
        services.configure(config: config, accountName: "Alexandra Stone")
        let composer = ComposerModel(services: services, selectedModelID: vision.id)
        composer.attach([PendingAttachment(data: Data(count: 11_000_000), filename: "huge.pdf", source: .files)])
        #expect(composer.attachments.isEmpty)
        #expect(composer.notice == "huge.pdf is larger than 10 MB, the limit on this Server.")
        let small = (0..<4).map { PendingAttachment(data: Data([UInt8($0)]), filename: "f\($0).txt", source: .files) }
        composer.attach(small)
        #expect(composer.attachments.count == 3)
        #expect(composer.remainingSlots == 0)
        #expect(composer.notice == "You can attach up to 3 files to a message.")
    }

    @Test func featureTogglesStartFromTheModelAndCanBeFlipped() {
        let searching = Model(id: "s", name: "S", ownedBy: "openai", defaultFeatureIDs: ["web_search"])
        let composer = ComposerModel(services: makeServices(StubTransport(), models: [searching]), selectedModelID: "s")
        #expect(composer.availableToggles == [.webSearch])
        #expect(composer.isOn(.webSearch))
        composer.set(.webSearch, on: false)
        #expect(!composer.isOn(.webSearch))
        composer.text = "hi"
        #expect(composer.submission()?.features == ["web_search": false])
    }

    @Test func effortPicksPersistPerModelAndBecomeParams() throws {
        let services = makeServices(StubTransport())
        let composer = ComposerModel(services: services, selectedModelID: vision.id)
        let effort = try #require(composer.effort)
        #expect(effort.source == .reasoningEffort)
        #expect(composer.chipDetail == nil)
        composer.setEffort("high", for: EffortConfiguration.reasoningEffortKey)
        #expect(composer.chipDetail == "High")
        composer.text = "think"
        #expect(composer.submission()?.params == ["reasoning_effort": .string("high")])
        // A new composer for the same model starts with the same Effort.
        #expect(ComposerModel(services: services, selectedModelID: vision.id).chipDetail == "High")
        #expect(ComposerModel(services: services, selectedModelID: blind.id).chipDetail == nil)
    }

    @Test func newChatsFollowThePreferredModelUntilTheUserPicks() async {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/users/user/settings", body: Data(#"{"ui":{"models":["blind"]}}"#.utf8))
        let services = makeServices(transport)
        let composer = ComposerModel(services: services, followsPreferredModel: true)
        #expect(composer.selectedModelID == vision.id)
        await services.refresh()
        #expect(composer.selectedModelID == blind.id)
        composer.select(vision.id)
        services.recordUse(of: blind.id)
        #expect(composer.selectedModelID == vision.id)
    }

    @Test func unavailableChatModelsFallBackAndAreRemembered() {
        let composer = ComposerModel(services: makeServices(StubTransport()))
        composer.adoptChatModel(["retired-model"])
        #expect(composer.unavailableModelID == "retired-model")
        #expect(composer.selectedModelID == vision.id)
        composer.select(blind.id)
        #expect(composer.unavailableModelID == nil)
        composer.adoptChatModel(["gone", blind.id])
        #expect(composer.selectedModelID == blind.id)
        #expect(composer.unavailableModelID == nil)
    }
}

@Suite("Composer services (MODEL-04, HOME-01, HOME-04)", .serialized)
@MainActor
struct ComposerServicesTests {
    @Test func newChatsStartWithTheSettingThenLastUsedThenWebClientThenAdmin() async throws {
        let a = model("a"), b = model("b"), c = model("c"), d = model("d")
        let transport = StubTransport()
        let settings = Mutex(#"{"ui":{"models":["c"]},"theseus":{}}"#)
        transport.stub("GET", "api/v1/users/user/settings") { _ in (200, Data(settings.withLock { $0 }.utf8)) }
        try transport.stub("GET", "api/v1/configs/banners", fixture: "banners.json")
        let services = makeServices(transport, models: [a, b, c, d], defaults: ["d"])
        #expect(services.preferredModelID == "d")
        await services.refresh()
        #expect(services.preferredModelID == "c")
        services.recordUse(of: "b")
        #expect(services.preferredModelID == "b")
        settings.withLock { $0 = #"{"ui":{"models":["c"]},"theseus":{"models":{"defaultModelID":"a"}}}"# }
        await services.refresh()
        #expect(services.defaultModelSetting == "a")
        #expect(services.preferredModelID == "a")
        // A default that disappeared from the Server is skipped.
        services.update(models: [b, c, d], defaultModelIDs: ["d"]) { _ in Capabilities(enabled: []) }
        #expect(services.preferredModelID == "b")
    }

    @Test func settingTheDefaultWritesOnlyTheTheseusNamespace() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/users/user/settings", body: Data(#"{"ui":{"models":["c"]},"theseus":{"profile":{"nickname":"Lex"}}}"#.utf8))
        let written = Mutex<Data?>(nil)
        transport.stub("POST", "api/v1/users/user/settings/update") { request in
            written.withLock { $0 = request.httpBody }
            return (200, Data(#"{"ui":{"models":["c"]},"theseus":{"profile":{"nickname":"Lex"},"models":{"defaultModelID":"sonnet"}}}"#.utf8))
        }
        let services = makeServices(transport)
        try await services.setDefaultModel("sonnet")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(written.withLock { $0 }))
        #expect(body[path: "ui"] == nil)
        #expect(body[path: "theseus.models.defaultModelID"]?.stringValue == "sonnet")
        #expect(body[path: "theseus.profile.nickname"]?.stringValue == "Lex")
        #expect(services.defaultModelSetting == "sonnet")
        #expect(services.greetingName == "Lex")
    }

    @Test func greetingNameFallsBackToTheAccountsFirstName() throws {
        let services = makeServices(StubTransport())
        let config = try JSONDecoder().decode(ServerConfig.self, from: Fixture.data("config.json"))
        services.configure(config: config, accountName: "Alexandra Stone")
        #expect(services.greetingName == "Alexandra")
        #expect(services.recordVisit(at: Date(timeIntervalSince1970: 10)) == nil)
        #expect(services.recordVisit(at: Date(timeIntervalSince1970: 20)) == Date(timeIntervalSince1970: 10))
    }

    @Test func dismissedBannersStayHidden() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/configs/banners", fixture: "synthetic/banners.json")
        transport.stub("GET", "api/v1/users/user/settings", body: Data("null".utf8))
        let store = ComposerLocalStore(accountKey: "a")
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
        let services = ComposerServices(client: client, models: [vision], defaultModelIDs: [], store: store) { _ in Capabilities(enabled: []) }
        await services.refresh()
        #expect(services.visibleBanners.map(\.id) == ["maintenance", "policy"])
        for banner in services.visibleBanners { services.dismiss(banner) }
        // Non-dismissible banners stay.
        #expect(services.visibleBanners.map(\.id) == ["policy"])
        #expect(store.dismissedBannerIDs.contains("maintenance"))
    }

    @Test func catalogUsesTheUsersPinsElseTheAdmins() async throws {
        let models = ["a", "b", "c", "d", "e"].map { model($0) }
        let transport = StubTransport()
        transport.stub("GET", "api/v1/users/user/settings", body: Data(#"{"ui":{"pinnedModels":["e"]}}"#.utf8))
        let services = makeServices(transport, models: models)
        let config = try JSONDecoder().decode(ServerConfig.self, from: Fixture.data("synthetic/config.file-limits.json"))
        services.configure(config: config, accountName: nil)
        #expect(services.catalog.primary.map(\.id) == ["b", "c"])
        await services.refresh()
        #expect(services.catalog.primary.map(\.id) == ["e"])
        #expect(services.catalog.more.map(\.id) == ["a", "b", "c", "d"])
    }
}
