#if canImport(AppKit)
import AppKit
@testable import ChatFeature
import Fixtures
import Foundation
import OpenWebUIKit
import SwiftUI
import Testing

/// Hosts the real conversation screen and streams a recorded Response through it, to catch
/// layout feedback loops and main-thread stalls (each update must lay out quickly).
@Suite("Conversation screen hosting", .serialized)
@MainActor
struct ConversationViewSmokeTests {
    @Test func streamingThroughTheScreenStaysResponsive() async throws {
        let fixture = StreamFixture("plain")
        let ids = try fixture.ids()
        let transport = StubTransport()
        let replay = try SocketReplay(scenario: "plain")
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, (try? fixture.data("completion.new.json")) ?? Data())
        }
        let services = makeServices(transport: transport, replay: replay)
        services.start()
        let model = services.newConversation()
        model.idGenerator = IDSequence([ids.userMessageID, ids.assistantMessageID]).next

        let host = NSHostingView(rootView: NavigationStack { ConversationView(model: model) }.environment(services))
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host

        func pump(_ duration: Duration) async -> Duration {
            let clock = ContinuousClock()
            var worst = Duration.zero
            let deadline = clock.now + duration
            while clock.now < deadline {
                let elapsed = clock.measure {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                worst = max(worst, elapsed)
                try? await Task.sleep(for: .milliseconds(16))
            }
            return worst
        }

        _ = await pump(.milliseconds(200))
        model.draft = "[theseus-test] In two short sentences, what is a maze?"
        await model.send()
        let worst = await pump(.seconds(1))
        #expect(await until { !model.isStreaming })
        let settled = await pump(.milliseconds(500))
        #expect(model.response(for: model.thread[1]).phase == .completed)
        #expect(worst < .milliseconds(250), "a layout pass took \(worst)")
        #expect(settled < .milliseconds(250), "a layout pass took \(settled)")
        await services.stop()
    }
    /// Typing in a long Chat re-rendered every Message on each keystroke: the screen read the
    /// draft (through `canSend`) for its composer. Only the composer may depend on it.
    @Test func typingDoesNotRebuildTheTranscript() async throws {
        let fixture = StreamFixture("plain")
        let chatID = try #require(try fixture.ids().chatID)
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(chatID)", body: try fixture.data("chat.final.json"))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        #expect(model.thread.contains { $0.role == .assistant })

        // `row(_:)` asks this hook for every Response each time the transcript is built.
        var rowsBuilt = 0
        let extensions = TranscriptExtensions(responseContent: { _, _ in
            rowsBuilt += 1
            return AnyView(EmptyView())
        })
        let host = NSHostingView(rootView: NavigationStack { ConversationView(model: model) }
            .environment(services)
            .environment(\.transcriptExtensions, extensions))
        host.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rowsBuilt > 0)

        let built = rowsBuilt
        for character in "And Lemuria?" {
            model.draft += String(character)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        #expect(model.canSend)
        #expect(rowsBuilt == built, "typing rebuilt the transcript \(rowsBuilt - built) times")
        // Tear the screen down, so it doesn't keep running beside the next tests.
        window.contentView = nil
        await services.stop()
    }
}
#endif
