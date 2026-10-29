import Auth
import ChatDomain
import Foundation
import OpenWebUIKit
import Testing

/// Streams one real Response over the hand-rolled Socket.IO client, then deletes the Chat.
/// Only own-data endpoints are used; the Chat is prefixed `[theseus-test]`.
@Suite(
    "Live streaming (opt-in: THESEUS_INTEGRATION=1 + .env)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
struct LiveStreamingTests {
    @Test func streamsAResponseOverTheSocketAndGetsATitle() async throws {
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
        let session = CompletionSession.live(client: client, credential: .sessionToken, serverSupportsWebSocket: true)
        let events = await session.events()
        await session.start()

        let models = try await client.send(.models)
        let model = models.first { $0.id.contains("haiku") } ?? models.first
        let request = CompletionRequest(
            chatID: nil,
            modelID: try #require(model).id,
            prompt: "[theseus-test] Reply with exactly: Hello from Theseus."
        )
        let receipt = try await session.send(request)
        #expect(receipt.transport == .socket)
        let chatID = try #require(receipt.chatID)

        var state = ResponseState()
        var title: String?
        let deadline = ContinuousClock.now + .seconds(90)
        for await event in events where event.chatID == chatID || event.messageID == request.assistantMessageID {
            if case .title(let value) = event.kind { title = value }
            if event.messageID == request.assistantMessageID, case .response(let response) = event.kind {
                state.apply(response)
            }
            if (state.isFinished && title != nil) || ContinuousClock.now > deadline { break }
        }
        #expect(state.phase == .completed)
        #expect(state.text.contains("Hello from Theseus"))
        #expect(title?.isEmpty == false)

        let stored = try await client.send(.chat(id: chatID)).chat
        #expect(stored.tree[request.assistantMessageID]?.response.text == state.text)

        _ = try await client.send(.deleteChat(id: chatID))
        await session.shutdown()
        _ = try await client.send(.signOut)
    }
}
