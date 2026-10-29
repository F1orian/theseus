import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Synchronization
import Testing

private func notesDocument() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Fixture.data("synthetic/openapi.notes.json"))
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("OpenAPI tools (#186)")
struct OpenAPIToolSpecTests {
    @Test func everyOperationWithAnIDIsATool() throws {
        let tools = OpenAPIToolSpec.tools(from: try notesDocument())
        #expect(tools.map(\.name).sorted() == ["add_note", "get_note", "list_notes", "update_note"])
    }

    @Test func queryParametersCarryTheirTypeAndOptions() throws {
        let list = try #require(OpenAPIToolSpec.tools(from: try notesDocument()).first { $0.name == "list_notes" })
        #expect(list.description == "List notes")
        #expect(list.parameters == (try json("""
        {"type":"object","required":[],"properties":{
          "tag":{"type":"string","description":". Possible values: work, home"},
          "limit":{"type":"integer","description":"How many notes"}}}
        """)))
    }

    @Test func bodiesResolveReferences() throws {
        let add = try #require(OpenAPIToolSpec.tools(from: try notesDocument()).first { $0.name == "add_note" })
        #expect(add.description == "Add a note")
        #expect(add.parameters == (try json("""
        {"type":"object","required":["text"],"properties":{
          "text":{"type":"string","description":"The note"},
          "tags":{"type":"array","items":{"type":"string","enum":["work","home"]}}}}
        """)))
    }

    @Test func operationParametersOverridePathParameters() throws {
        let tools = OpenAPIToolSpec.tools(from: try notesDocument())
        let get = try #require(tools.first { $0.name == "get_note" })
        #expect(get.parameters[path: "required"] == .array([.string("note_id")]))
        let update = try #require(tools.first { $0.name == "update_note" })
        #expect(update.parameters[path: "properties.note_id.description"] == .string("The note to change"))
        #expect(update.parameters[path: "required"] == .array([.string("note_id"), .string("text")]))
        #expect(update.description == "No description available.")
    }
}

@Suite("Calling a personal connector from the device (#186)")
struct OpenAPIToolInvocationTests {
    let invocation: OpenAPIToolInvocation

    init() throws {
        invocation = OpenAPIToolInvocation(baseURL: "http://localhost:8766/", document: try notesDocument())
    }

    @Test func getWithQueryAndBearer() throws {
        let request = try invocation.request(
            operation: "list_notes", params: ["tag": .string("work"), "limit": .number(5)],
            bearerToken: "sk-1", sessionID: "chat-1"
        )
        #expect(request.httpMethod == "GET")
        let url = try #require(request.url)
        #expect(url.path() == "/notes")
        #expect(Set(url.query()?.split(separator: "&").map(String.init) ?? []) == ["tag=work", "limit=5"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        #expect(request.value(forHTTPHeaderField: "X-Session-Id") == "chat-1")
        #expect(request.httpBody == nil)
    }

    @Test func pathParametersAreEncodedAndKeptOutOfTheBody() throws {
        let request = try invocation.request(
            operation: "update_note", params: ["note_id": .string("a b/c"), "text": .string("hi")],
            bearerToken: nil, sessionID: nil
        )
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "http://localhost:8766/notes/a%20b%2Fc")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body == .object(["text": .string("hi")]))
    }

    @Test func postSendsTheBody() throws {
        let request = try invocation.request(
            operation: "add_note", params: ["text": .string("milk"), "tags": .array([.string("home")])],
            bearerToken: nil, sessionID: nil
        )
        #expect(request.httpMethod == "POST")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
        #expect(body == (try json(#"{"text":"milk","tags":["home"]}"#)))
    }

    @Test func unknownOperationsFail() {
        #expect(throws: OpenAPIToolInvocation.Failure.unknownOperation("nope")) {
            try invocation.request(operation: "nope", params: [:], bearerToken: nil, sessionID: nil)
        }
    }

    @Test func resultsTakeTheShapeTheServerExpects() throws {
        let url = try #require(URL(string: "http://localhost:8766/notes"))
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        let result = OpenAPIToolInvocation.result(data: Data(#"[{"id":"1"}]"#.utf8), response: ok)
        #expect(result.arrayValue?.first == (try json(#"[{"id":"1"}]"#)))
        #expect(result.arrayValue?.last?[path: "content-type"] == .string("application/json"))

        let text = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"]))
        #expect(OpenAPIToolInvocation.result(data: Data("hello".utf8), response: text).arrayValue?.first == .string("hello"))

        let image = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]))
        #expect(OpenAPIToolInvocation.result(data: Data([0x89, 0x50]), response: image).arrayValue?.first == .string("data:image/png;base64,iVA="))

        let failed = try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        let error = OpenAPIToolInvocation.result(data: Data("boom".utf8), response: failed)
        #expect(error == .array([.object(["error": .string("HTTP error! Status: 500. Message: boom")]), .null]))
    }
}

/// A personal-connector stand-in that records calls.
final class RecordingDirectTools: DirectToolServers {
    let payload: [JSONValue]
    let delay: Duration
    private let calls = Mutex<[DirectToolCall]>([])

    init(payload: [JSONValue], delay: Duration = .zero) {
        self.payload = payload
        self.delay = delay
    }

    var received: [DirectToolCall] { calls.withLock { $0 } }

    func toolServersPayload() async -> [JSONValue] { payload }

    func execute(_ call: DirectToolCall) async -> JSONValue {
        calls.withLock { $0.append(call) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return .array([.object(["notes": .array([.string("milk")])]), .object(["content-type": .string("application/json")])])
    }
}

@Suite("execute:tool over the socket (#186)")
struct ExecuteToolSocketTests {
    let transport = StubTransport()

    /// A handshake, a completion, then the Server asking this session to run `list_notes`
    /// (ack id 7) and finishing once it has the answer.
    static let log = #"""
    {"dir":"note","note":"socket: open wss://owui.example.com/ws/socket.io/?EIO=4&transport=websocket"}
    {"dir":"in","frame":"0{\"sid\":\"eio\",\"upgrades\":[],\"pingTimeout\":20000,\"pingInterval\":25000,\"maxPayload\":1000000}"}
    {"dir":"out","frame":"40"}
    {"dir":"in","frame":"40{\"sid\":\"S1\"}"}
    {"dir":"out","frame":"420"}
    {"dir":"in","frame":"430[{\"id\":\"u\",\"name\":\"Test\"}]"}
    {"dir":"note","note":"POST /api/chat/completions"}
    {"dir":"in","frame":"427[\"events\",{\"chat_id\":\"c1\",\"message_id\":\"m1\",\"data\":{\"type\":\"execute:tool\",\"data\":{\"id\":\"call-1\",\"name\":\"list_notes\",\"params\":{\"tag\":\"work\"},\"server\":{\"url\":\"http://localhost:8766\",\"info\":{\"title\":\"Notes\"}},\"session_id\":\"S1\"}}}]"}
    {"dir":"out","frame":"437[...]"}
    {"dir":"in","frame":"42[\"events\",{\"chat_id\":\"c1\",\"message_id\":\"m1\",\"data\":{\"type\":\"chat:completion\",\"data\":{\"done\":true,\"content\":\"You have one note: milk.\"}}}]"}
    """#

    private func makeSession(_ replay: SocketReplay, timeout: Duration = .seconds(5)) -> CompletionSession {
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: CountingAuthorizer(token: "jwt"))
        let socket = SocketIOClient(server: Fixture.serverURL, connector: replay, backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20))) { "jwt" }
        return CompletionSession(client: client, socket: socket, joinTimeout: .seconds(2), directToolTimeout: timeout)
    }

    private func stubCompletion(_ replay: SocketReplay) {
        transport.stub("POST", "api/chat/completions") { _ in
            replay.open(.completion)
            return (200, Data(#"{"status":true,"task_ids":["t"],"chat_id":"c1"}"#.utf8))
        }
    }

    private func ack(in replay: SocketReplay) -> JSONValue? {
        guard let frame = replay.sentFrames.joined().first(where: { $0.hasPrefix("437") }) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(frame.dropFirst(3).utf8))
    }

    @Test func sendsSpecsAndRunsTheCallOnTheDevice() async throws {
        let replay = try SocketReplay(log: Self.log)
        stubCompletion(replay)
        let session = makeSession(replay)
        let server: JSONValue = try json(#"{"url":"http://localhost:8766","openapi":{"paths":{}},"info":{"title":"Notes"},"specs":[{"name":"list_notes"}]}"#)
        let tools = RecordingDirectTools(payload: [server])
        session.useDirectToolServers(tools)
        let events = await session.events()
        await session.start()
        _ = try await session.send(CompletionRequest(chatID: "c1", modelID: "m", prompt: "notes?", userMessageID: "u1", assistantMessageID: "m1"))

        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.last?.httpBody))
        #expect(sent[path: "tool_servers"] == .array([server]))

        let (state, _) = await collect(events, messageID: "m1")
        #expect(state.phase == .completed)
        #expect(tools.received == [DirectToolCall(id: "call-1", name: "list_notes", params: ["tag": .string("work")], serverURL: "http://localhost:8766", chatID: "c1")])
        let answer = try #require(ack(in: replay))
        #expect(answer == .array([.array([.object(["notes": .array([.string("milk")])]), .object(["content-type": .string("application/json")])])]))
        await session.shutdown()
    }

    @Test func aSlowConnectorAnswersWithAToolErrorInsteadOfHanging() async throws {
        let replay = try SocketReplay(log: Self.log)
        stubCompletion(replay)
        let session = makeSession(replay, timeout: .milliseconds(100))
        session.useDirectToolServers(RecordingDirectTools(payload: [], delay: .seconds(30)))
        let events = await session.events()
        await session.start()
        _ = try await session.send(CompletionRequest(chatID: "c1", modelID: "m", prompt: "notes?", userMessageID: "u1", assistantMessageID: "m1"))
        let (state, _) = await collect(events, messageID: "m1")
        #expect(state.phase == .completed)
        let answer = try #require(ack(in: replay))
        let error = answer.arrayValue?.first?.arrayValue?.first?[path: "error"]?.stringValue
        #expect(error?.contains("didn't answer") == true)
        await session.shutdown()
    }

    @Test func withoutPersonalConnectorsTheCallIsRefusedAndNoServersAreSent() async throws {
        let replay = try SocketReplay(log: Self.log)
        stubCompletion(replay)
        let session = makeSession(replay)
        let events = await session.events()
        await session.start()
        _ = try await session.send(CompletionRequest(chatID: "c1", modelID: "m", prompt: "notes?", userMessageID: "u1", assistantMessageID: "m1"))
        let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.last?.httpBody))
        #expect(sent[path: "tool_servers"] == .array([]))
        _ = await collect(events, messageID: "m1")
        let answer = try #require(ack(in: replay))
        #expect(answer.arrayValue?.first?[path: "error"]?.stringValue?.contains("Personal connectors") == true)
        await session.shutdown()
    }
}
