import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Open Terminal (#132, ADR 0120): terminals, the `sandbox` Capability, `terminal_id` on requests,
/// the terminal acks and the sandbox proxy endpoints.
@Suite("Sandbox (Open Terminal)")
struct SandboxEndpointTests {
    let features: ServerFeatures
    let admin: SessionUser
    let model: Model
    let sandbox = StreamFixture("sandbox")

    init() throws {
        features = try Endpoint.config.decode(Fixture.data("config.json")).features
        admin = try Endpoint.sessionUser.decode(Fixture.data("auths.json"))
        model = try #require(try Endpoint.models.decode(Fixture.data("models.json")).first)
    }

    private func json(_ data: Data?) throws -> JSONValue {
        try WireCoding.decoder.decode(JSONValue.self, from: try #require(data))
    }

    // MARK: Discovery

    @Test func modelsNameTheirDefaultTerminal() {
        // The recorded models carry the Server's default terminal (scrubbed to "sandbox").
        #expect(model.terminalID == "sandbox")
        #expect(model.capabilities.supports("terminal"))
    }

    @Test func terminalsDecodeWithoutTheirKeys() throws {
        let terminals = try Endpoint.terminals.decode(sandbox.data("terminals.json"))
        #expect(terminals == [TerminalServer(id: "demo-sandbox", name: "Demo sandbox", uploadMode: .default)])
        let filesystem = try Endpoint.terminals.decode(Data(#"[{"id":"t","name":"","config":{"chat_uploads":"filesystem"}}]"#.utf8))
        #expect(filesystem.first?.name == "t")
        #expect(filesystem.first?.uploadMode == .filesystem)
    }

    // MARK: Capability

    @Test func theSandboxNeedsTheModelsTerminalAmongTheAccountsTerminals() {
        let terminals = [TerminalServer(id: "sandbox", name: "Sandbox")]
        #expect(Capabilities.resolve(features: features, user: admin, model: model, terminals: terminals).contains(.sandbox))
        // Not loaded, none listed, or a terminal the Account can't use: no sandbox.
        #expect(!Capabilities.resolve(features: features, user: admin, model: model).contains(.sandbox))
        #expect(!Capabilities.resolve(features: features, user: admin, model: model, terminals: []).contains(.sandbox))
        let other = [TerminalServer(id: "elsewhere", name: "Elsewhere")]
        #expect(!Capabilities.resolve(features: features, user: admin, model: model, terminals: other).contains(.sandbox))
        // Settings (no model): any terminal will do.
        #expect(Capabilities.resolve(features: features, user: admin, model: nil, terminals: other).contains(.sandbox))
    }

    @Test func theSandboxFollowsTheServerFlagAndTheModelCapability() throws {
        let terminals = [TerminalServer(id: "sandbox", name: "Sandbox")]
        var raw = features.raw
        raw["enable_tool_servers"] = .bool(false)
        #expect(!Capabilities.resolve(features: ServerFeatures(raw: raw), user: admin, model: model, terminals: terminals).contains(.sandbox))

        let noTerminal = try #require(try Endpoint.models.decode(Data(#"""
        {"data":[{"id":"m","name":"M","info":{"meta":{"terminalId":"sandbox","capabilities":{"terminal":false}}}}]}
        """#.utf8)).first)
        #expect(!Capabilities.resolve(features: features, user: admin, model: noTerminal, terminals: terminals).contains(.sandbox))
    }

    // MARK: Requests

    @Test func theTerminalGoesOutOnSocketAndSSEBodies() throws {
        var request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi", parentMessageID: "a0")
        request.terminalID = "demo-sandbox"
        request.skillIDs = ["xlsx", "pdf"]
        let socket = try json(CompletionSession.socketBody(request, sessionID: "sid"))
        #expect(socket[path: "terminal_id"]?.stringValue == "demo-sandbox")
        #expect(socket[path: "skill_ids"] == .array(["xlsx", "pdf"]))
        let sse = try json(CompletionSession.sseBody(request))
        #expect(sse[path: "terminal_id"]?.stringValue == "demo-sandbox")
        #expect(sse[path: "skill_ids"] == .array(["xlsx", "pdf"]))
    }

    @Test func withoutASandboxNoTerminalIsSent() throws {
        let request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi")
        #expect(try json(CompletionSession.socketBody(request, sessionID: "sid"))[path: "terminal_id"] == nil)
        #expect(try json(CompletionSession.sseBody(request))[path: "terminal_id"] == nil)
        #expect(try json(CompletionSession.socketBody(request, sessionID: "sid"))[path: "skill_ids"] == nil)
    }

    @Test func followUpsAreRequestedOnlyWhenAskedAndNeverForIncognitoChats() throws {
        var request = CompletionRequest(chatID: "c1", modelID: "m", prompt: "hi")
        #expect(try json(CompletionSession.socketBody(request, sessionID: "s"))[path: "background_tasks.follow_up_generation"] == .bool(false))
        request.generatesFollowUps = true
        #expect(try json(CompletionSession.socketBody(request, sessionID: "s"))[path: "background_tasks.follow_up_generation"] == .bool(true))
        request.isIncognito = true
        #expect(try json(CompletionSession.socketBody(request, sessionID: "s"))[path: "background_tasks.follow_up_generation"] == .bool(false))
    }

    // MARK: Acks

    @Test func recordedTerminalStateCallsAreAnsweredNotConnected() throws {
        let calls = try sandbox.envelopes().filter { $0.envelope[path: "data.type"]?.stringValue == "request:terminal:state" }
        #expect(calls.count == 2)
        for (envelope, ackID) in calls {
            let ack = try #require(ackID)
            #expect(ChatEventDecoder.decode(envelope, ackID: ack).map(\.kind) == [.unsupportedCall(type: "request:terminal:state", ackID: ack)])
        }
        #expect(CompletionSession.refusal(for: "request:terminal:state") == .object(["connected": .bool(false)]))
        #expect(CompletionSession.refusal(for: "request:terminal")[path: "error"]?.stringValue != nil)
    }

    @Test func theSessionAcksTerminalStateRightAway() async throws {
        let ids = try sandbox.ids()
        let replay = try SocketReplay(scenario: "sandbox")
        let transport = StubTransport()
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            let body = #"{"status":true,"chat_id":"\#(ids.chatID ?? "")"}"#
            return (200, Data(body.utf8))
        }
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
        let socket = SocketIOClient(server: Fixture.serverURL, connector: replay, backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20))) { "jwt" }
        let session = CompletionSession(client: client, socket: socket, joinTimeout: .milliseconds(500))
        await session.start()
        var request = CompletionRequest(chatID: nil, modelID: "claude-haiku-5-5", prompt: "hi", userMessageID: ids.userMessageID, assistantMessageID: ids.assistantMessageID)
        request.terminalID = ids.terminalID
        _ = try await session.send(request)

        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, !replay.sentFrames.joined().contains(where: { $0.hasPrefix("431") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let acks = replay.sentFrames.joined().filter { $0.hasPrefix("431") }
        #expect(acks.first == #"431[{"connected":false}]"#)
        await session.shutdown()
    }

    // MARK: Generated files

    @Test func filesEventsAttachToTheResponse() {
        let envelope: JSONValue = .object([
            "chat_id": "c", "message_id": "m",
            "data": .object(["type": "files", "data": .object(["files": .array([
                .object(["type": "image", "url": "/api/v1/files/f1/content"]),
            ])])]),
        ])
        let decoded = ChatEventDecoder.decode(envelope)
        guard case .response(.files(let files, let replace))? = decoded.first?.kind else {
            Issue.record("no files event: \(decoded)")
            return
        }
        #expect(!replace)
        #expect(files.first?.kind == .image)
        #expect(files.first?.url == "/api/v1/files/f1/content")

        var state = ResponseState()
        state.apply(.files(files, replace: false))
        state.apply(.files(files, replace: false))
        #expect(state.files.count == 1)
        let replaced = ChatEventDecoder.decode(.object([
            "chat_id": "c", "message_id": "m",
            "data": .object(["type": "chat:message:files", "data": .object(["files": .array([
                .object(["type": "file", "id": "f2", "name": "report.pdf", "content_type": "application/pdf"]),
            ])])]),
        ]))
        guard case .response(let event)? = replaced.first?.kind else { return }
        state.apply(event)
        #expect(state.files.map(\.id) == ["f2"])
    }

    // MARK: Proxy

    @Test func browsingGoesThroughTheChatsSessionOnTheProxy() throws {
        let server = Fixture.serverURL
        let list = Endpoint.sandboxDirectory(terminalID: "demo-sandbox", chatID: "c1", path: "/home/user/theseus-test").urlRequest(server: server, token: "jwt")
        #expect(list.url?.path() == "/api/v1/terminals/demo-sandbox/chats/c1/files/list")
        #expect(list.url?.query()?.contains("directory=/home/user/theseus-test") == true)
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")

        let view = Endpoint.sandboxFile(terminalID: "demo-sandbox", chatID: "c1", path: "/home/user/a b.docx", preview: true).urlRequest(server: server, token: "jwt")
        #expect(view.url?.path() == "/api/v1/terminals/demo-sandbox/chats/c1/files/view")
        #expect(view.url?.query()?.contains("preview=true") == true)

        let archive = Endpoint.sandboxArchive(terminalID: "t", chatID: "c1", paths: ["/a", "/b"]).urlRequest(server: server, token: "jwt")
        #expect(archive.httpMethod == "POST")
        #expect(try json(archive.httpBody) == .object(["paths": .array(["/a", "/b"])]))
    }

    @Test func recordedBrowsingResponsesDecode() throws {
        let location = try Endpoint.sandboxLocation(terminalID: "t", chatID: "c").decode(sandbox.data("files.cwd.json"))
        #expect(location == SandboxLocation(cwd: "/home/user", home: "/home/user", rootPath: "/home/user", rootLabel: "Home"))
        let directory = try Endpoint.sandboxDirectory(terminalID: "t", chatID: "c", path: "/").decode(sandbox.data("files.list.json"))
        #expect(directory.path == "/home/user/theseus-test")
        #expect(directory.entries.map(\.name) == ["hello.txt", "planets.csv"])
        #expect(directory.entries.first?.size == 2)
        #expect(directory.entries.first?.isDirectory == false)
        let matches = try Endpoint.sandboxSearch(terminalID: "t", chatID: "c", query: "planets", path: "/").decode(sandbox.data("files.matches.json"))
        #expect(matches.map(\.name) == ["planets.csv"])
    }

    @Test func uploadsAreMultipartIntoTheChatsSession() throws {
        let request = Endpoint.sandboxUpload(terminalID: "t", chatID: "c1", directory: "/home/user/uploads", filename: "data.csv", contentType: "text/csv", data: Data("a,b\n".utf8))
            .urlRequest(server: Fixture.serverURL, token: "jwt")
        #expect(request.url?.path() == "/api/v1/terminals/t/chats/c1/files/upload")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains(#"filename="data.csv""#))
        #expect(body.contains("a,b"))
        let decoded = try Endpoint.sandboxUpload(terminalID: "t", chatID: "c", directory: "/", filename: "x", contentType: "text/plain", data: Data())
            .decode(Data(#"{"path":"/home/user/uploads/data.csv","size":4}"#.utf8))
        #expect(decoded == SandboxUpload(path: "/home/user/uploads/data.csv", size: 4))
    }

    // MARK: Skills (#140)

    @Test func skillsDecode() throws {
        let skills = try Endpoint.skills.decode(StreamFixture("skills").data("list.json"))
        #expect(skills.count == 12)
        #expect(skills.contains { $0.id == "deep-research" && $0.isActive })
    }
}
