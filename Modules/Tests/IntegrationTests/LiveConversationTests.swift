import Auth
import ChatDomain
import ChatFeature
import Foundation
import OpenWebUIKit
import Testing

/// Drives a real Conversation (send, stop, follow-up) against the test Server, then deletes it.
@Suite(
    "Live conversation (opt-in: THESEUS_INTEGRATION=1 + .env)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
@MainActor
struct LiveConversationTests {
    func until(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func sendStopAndFollowUp() async throws {
        let settings = try #require(LiveServer.settings)
        let transport = URLSessionTransport()
        let server = ServerProfile(url: settings.url, name: "Live")
        guard case .signedIn(let signedIn) = try await PasswordSignIn(server: server, transport: transport)
            .signIn(email: settings.email, password: settings.password)
        else {
            Issue.record("sign-in failed")
            return
        }
        let authenticator = SessionAuthenticator(token: signedIn.token) { throw OpenWebUIError.unauthorized(detail: nil) }
        let client = OpenWebUIClient(server: settings.url, transport: transport, authorizer: authenticator)
        let models = try await client.send(.models)
        let haiku = try #require(models.first { $0.id.contains(ProcessInfo.processInfo.environment["THESEUS_LIVE_MODEL"] ?? "haiku") })
        let services = ChatServices(
            client: client,
            session: .live(client: client, credential: .sessionToken, serverSupportsWebSocket: true),
            models: [haiku],
            defaultModelID: haiku.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        services.start()
        let conversation = services.newConversation()

        conversation.draft = "[theseus-test] Write a 500-word story about a mouse in a maze."
        await conversation.send()
        #expect(await until(.seconds(30)) {
            conversation.thread.last.map { !conversation.response(for: $0).text.isEmpty } ?? false
        })
        await conversation.stop()
        #expect(await until(.seconds(30)) { !conversation.isStreaming })
        let stopped = try #require(conversation.thread.last)
        #expect(conversation.response(for: stopped).phase == .stopped)

        conversation.draft = "[theseus-test] Now reply with exactly: follow-up works."
        await conversation.send()
        #expect(await until(.seconds(60)) { !conversation.isStreaming })
        let followUp = try #require(conversation.thread.last)
        let state = conversation.response(for: followUp)
        #expect(state.phase == .completed, "phase \(state.phase), error \(state.error ?? "-"), output \(state.output)")
        #expect(state.text.lowercased().contains("follow-up works"))
        #expect(conversation.thread.count == 4)

        if let chatID = conversation.chatID {
            try? await Task.sleep(for: .seconds(2))
            let stored = try await client.send(.chat(id: chatID)).chat.tree[followUp.id]
            #expect(stored?.response.text == state.text)
            _ = try await client.send(.deleteChat(id: chatID))
        }
        await services.stop()
        _ = try await client.send(.signOut)
    }
}
