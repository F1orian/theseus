#if canImport(AppKit)
import AppKit
@testable import ArtifactsFeature
import ChatDomain
import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import SwiftUI
import Testing

/// Hosts the real conversation screen with the Artifacts hooks over the recorded `artifacts`
/// Chat: the cards and the pill must be wired in and layout must stay quick.
@Suite("Artifacts in the transcript", .serialized)
@MainActor
struct TranscriptHostingTests {
    @Test func recordedChatRendersCardsAndThePill() async throws {
        let ids = try ArtifactIDs.load()
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ids.chatID)", body: try StreamFixture("artifacts").data("chat.final.json"))
        let model = Model(id: "claude-haiku-5-5", name: "Claude Haiku")
        let client = makeClient(transport)
        let services = ChatServices(
            client: client,
            session: CompletionSession(client: client, socket: nil),
            models: [model],
            defaultModelID: model.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        let conversation = services.conversation(chatID: ids.chatID)
        await conversation.load()
        #expect(conversation.thread.count == 8)

        var asked: [String?] = []
        var extensions = Artifacts.transcriptExtensions
        let hook = extensions.codeBlock
        extensions.codeBlock = { model, message, language, code in
            asked.append(language)
            return hook?(model, message, language, code)
        }
        let root = NavigationStack { ConversationView(model: conversation) }
            .environment(services)
            .environment(\.transcriptExtensions, extensions)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host

        let clock = ContinuousClock()
        var worst = Duration.zero
        for _ in 0..<10 {
            worst = max(worst, clock.measure {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
            try await Task.sleep(for: .milliseconds(16))
        }
        // Every fence went through the hook: two HTML pages, the SVG and the Mermaid diagram.
        #expect(Set(asked) == ["html", "svg", "mermaid"])
        #expect(ArtifactsCache.shared.catalog(for: conversation).count == 4)
        #expect(worst < .milliseconds(500), "a layout pass took \(worst)")
    }

    /// #180: an imported Claude Chat showed its `<details>` markup as text and no Artifact cards.
    @Test func importedChatRendersArtifactStepsAsCards() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ImportedChat.id)", body: try ImportedChat.data())
        let model = Model(id: "claude-sonnet-5-5", name: "Claude Sonnet")
        let client = makeClient(transport)
        let services = ChatServices(
            client: client,
            session: CompletionSession(client: client, socket: nil),
            models: [model],
            defaultModelID: model.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        let conversation = services.conversation(chatID: ImportedChat.id)
        await conversation.load()
        #expect(conversation.thread.count == 10)
        // No raw markup reaches the text parts.
        for message in conversation.thread where message.role == .assistant {
            for part in conversation.response(for: message).parts {
                if case .text(_, let markdown, _) = part { #expect(!markdown.contains("<details")) }
            }
        }

        var claimed: [[String]] = []
        var extensions = Artifacts.transcriptExtensions
        let hook = extensions.toolSteps
        extensions.toolSteps = { model, message, steps in
            let view = hook?(model, message, steps)
            if view != nil { claimed.append(steps.map(\.name)) }
            return view
        }
        let root = NavigationStack { ConversationView(model: conversation) }
            .environment(services)
            .environment(\.transcriptExtensions, extensions)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        // Every run with an `artifacts` call became cards; the web search keeps its status line.
        #expect(claimed.contains(["artifacts"]))
        #expect(claimed.contains(["artifacts", "artifacts"]))
        #expect(!claimed.contains(["web_search"]))
        #expect(ArtifactsCache.shared.catalog(for: conversation).count == 6)
    }
    /// Every Response's tool-embed cards and the header pill read the catalog, which spans the
    /// whole path: built per reader, opening a long Chat took seconds. One state, one build.
    @Test func oneTranscriptStateBuildsTheCatalogOnce() async throws {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(ImportedChat.id)", body: try ImportedChat.data())
        let model = Model(id: "claude-sonnet-5-5", name: "Claude Sonnet")
        let client = makeClient(transport)
        let services = ChatServices(
            client: client,
            session: CompletionSession(client: client, socket: nil),
            models: [model],
            defaultModelID: model.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        let conversation = services.conversation(chatID: ImportedChat.id)
        await conversation.load()

        let before = ArtifactsCache.shared.catalogBuilds
        let root = NavigationStack { ConversationView(model: conversation) }
            .environment(services)
            .environment(\.transcriptExtensions, Artifacts.transcriptExtensions)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        // At most one: the shared cache may already hold this state from another test.
        let builds = ArtifactsCache.shared.catalogBuilds - before
        #expect(builds <= 1)
        #expect(ArtifactsCache.shared.catalog(for: conversation).count == 6)
        #expect(ArtifactsCache.shared.catalogBuilds - before == builds)
        window.contentView = nil
    }
}
#endif
