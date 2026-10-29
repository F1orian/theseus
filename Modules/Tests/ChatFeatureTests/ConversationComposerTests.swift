@testable import ChatFeature
import ChatDomain
import ComposerFeature
import CoreGraphics
import Fixtures
import Foundation
import ImageIO
import OpenWebUIKit
import Synchronization
import Testing
import UniformTypeIdentifiers

/// A tiny PNG for attachment tests.
func pngData() -> Data {
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    context?.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let output = NSMutableData()
    guard let image = context?.makeImage(),
          let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

@Suite("Conversation × composer (HOME-02, MODEL-02, ATT-04)", .serialized)
@MainActor
struct ConversationComposerTests {
    @Test func sendCarriesAttachmentsEffortAndToggles() async throws {
        let fixture = StreamFixture("error")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "error")
        let bodies = Mutex<[Data]>([])
        transport.stub("POST", "api/chat/completions") { request in
            bodies.withLock { $0.append(request.httpBody ?? Data()) }
            replay.open(.completion)
            return (200, (try? fixture.data("completion.json")) ?? Data())
        }
        try transport.stub("POST", "api/v1/files/", fixture: "stream/attachments.upload.image.json")
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID, "retry-assistant"]).next
        model.composer.attach([PendingAttachment(data: pngData(), filename: "swatch.png", source: .photos)])
        #expect(!model.canSend)
        #expect(await until { model.composer.attachments.first?.phase == .ready })
        model.composer.set(.webSearch, on: false)
        model.composer.setEffort("high", for: EffortConfiguration.reasoningEffortKey)
        await send(model, "What colour is this?")
        #expect(model.composer.attachments.isEmpty)
        #expect(model.draft.isEmpty)

        // The optimistic user Message shows the photo right away (ATT-04).
        let user = try #require(model.thread.first)
        #expect(user.attachments.map(\.kind) == [.image])
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.withLock { $0.first }))
        let files = body[path: "user_message.files"]?.arrayValue ?? []
        #expect(files.count == 1)
        #expect(files.first?[path: "content_type"]?.stringValue == "image/png")
        #expect(body[path: "files"] == nil, "images stay on the Message")
        #expect(body[path: "params.reasoning_effort"]?.stringValue == "high")
        #expect(body[path: "features.web_search"]?.boolValue == false)
        #expect(services.composer.store.lastUsedModelID == haiku.id)

        // A retry resends the same files.
        #expect(await until { !model.isStreaming })
        await model.retry(ids.assistantMessageID)
        let retried = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.withLock { $0.last }))
        #expect(retried[path: "user_message.files"]?.arrayValue?.count == 1)
        await services.stop()
    }

    @Test func storedChatsShowAttachmentsAndKeepDocumentsInContext() async throws {
        let fixture = StreamFixture("attachments")
        let ids = try fixture.ids()
        let chatID = try #require(ids.chatID)
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(chatID)", body: try fixture.data("chat.final.json"))
        let bodies = Mutex<[Data]>([])
        transport.stub("POST", "api/chat/completions") { request in
            bodies.withLock { $0.append(request.httpBody ?? Data()) }
            return (200, (try? StreamFixture("sse").data("plain.txt")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        let user = try #require(model.thread.first)
        #expect(user.attachments.map(\.kind) == [.document, .image])
        #expect(model.selectedModelID == haiku.id)
        #expect(model.composer.unavailableModelID == nil)

        await send(model, "And the capital of Lemuria?")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(bodies.withLock { $0.first }))
        let context = (body[path: "files"]?.arrayValue ?? []).compactMap { $0[path: "id"]?.stringValue }
        #expect(context == [user.attachments[0].id])
        #expect(await until { !model.isStreaming })
    }

    @Test func aChatWhoseModelIsGoneFallsBackWithANotice() async throws {
        let fixture = StreamFixture("plain")
        let chatID = try #require(try fixture.ids().chatID)
        let transport = StubTransport()
        let stored = try fixture.data("chat.final.json")
        let renamed = String(decoding: stored, as: UTF8.self).replacingOccurrences(of: "claude-haiku-5-5", with: "retired-model")
        transport.stub("GET", "api/v1/chats/\(chatID)", body: Data(renamed.utf8))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        #expect(model.composer.unavailableModelID == "retired-model")
        #expect(model.selectedModelID == haiku.id)
    }
}
