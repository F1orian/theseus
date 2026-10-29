@testable import ComposerFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// INCOG-01: an Incognito chat's composer uploads nothing. Photos stay on the device as `data:`
/// URLs (sent inline); files can't be attached.
@Suite("Composer in an Incognito chat", .serialized)
@MainActor
struct IncognitoComposerTests {
    @Test func photosStayInlineAndNothingUploads() async throws {
        let transport = StubTransport()
        let services = makeServices(transport)
        let composer = ComposerModel(services: services, selectedModelID: vision.id)
        composer.isIncognito = true
        #expect(composer.canAttachPhotos)
        #expect(!composer.canAttachFiles)

        composer.attach([PendingAttachment(data: ImageProcessingTests.image(width: 8, height: 8, type: .png), filename: "a.png", source: .photos)])
        #expect(await until { composer.attachments.first?.phase == .ready })
        let attachment = try #require(composer.attachments.first)
        #expect(attachment.file == nil)
        #expect(attachment.inlineURL?.hasPrefix("data:image/png;base64,") == true)

        composer.text = "What's this?"
        let submission = try #require(composer.submission())
        #expect(submission.files.isEmpty)
        #expect(submission.attachments.first?.url == attachment.inlineURL)
        #expect(submission.attachments.first?.isServerFile == false)
        composer.remove(attachment.id)
        #expect(transport.requests.isEmpty, "no upload, and no delete either")
    }

    @Test func filesAreRefused() {
        let transport = StubTransport()
        let composer = ComposerModel(services: makeServices(transport), selectedModelID: vision.id)
        composer.isIncognito = true
        composer.attach([PendingAttachment(data: Data("x".utf8), filename: "a.txt", source: .files)])
        #expect(composer.attachments.isEmpty)
        #expect(composer.notice?.hasPrefix("Incognito chats can't take files") == true)
        #expect(transport.requests.isEmpty)
    }
}
