@testable import ChatFeature
import ChatDomain
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Tool approval prompts (OT-06): a Response paused on a sandbox run waits for Allow or Deny,
/// which resolve the call on the Server. Built from the recorded sandbox run, paused the way the
/// server stores it in `tool_approval_mode: "ask"` (`status: "pending"`, `done: false`).
@Suite("Tool approvals", .serialized)
@MainActor
struct ToolApprovalTests {
    private let chatID = "00000000-0000-4000-8000-0000000c0001"
    private let assistantID = "a1"

    private var pausedChat: Data {
        Data(#"""
        {"id":"\#(chatID)","title":"[theseus-test] approval","updated_at":1792829701,"created_at":1792829700,
         "chat":{"title":"[theseus-test] approval","models":["\#(haiku.id)"],"history":{"currentId":"\#(assistantID)","messages":{
          "u1":{"id":"u1","parentId":null,"childrenIds":["\#(assistantID)"],"role":"user","content":"[theseus-test] list the folder","timestamp":1792829700},
          "\#(assistantID)":{"id":"\#(assistantID)","parentId":"u1","childrenIds":[],"role":"assistant","content":"","model":"\#(haiku.id)","done":false,"timestamp":1792829701,
           "output":[
            {"type":"function_call","id":"call_1","call_id":"call_1","name":"run_command","arguments":"{\"command\":\"ls -la theseus-test\"}","status":"pending"},
            {"type":"function_call","id":"call_2","call_id":"call_2","name":"write_file","arguments":"{\"path\":\"theseus-test/a.txt\",\"content\":\"a\"}","status":"requires_approval"}]}}}}}
        """#.utf8)
    }

    private func loaded() async throws -> (ConversationModel, StubTransport, ChatServices) {
        let transport = StubTransport()
        transport.stub("GET", "api/v1/chats/\(chatID)", body: pausedChat)
        transport.stub("GET", "api/tasks/chat/\(chatID)", body: Data(#"{"task_ids":[]}"#.utf8))
        transport.stub("POST", "api/v1/chats/\(chatID)/messages/\(assistantID)/resolve", body: Data(#"{"status":true}"#.utf8))
        let services = makeServices(transport: transport, replay: nil)
        let model = services.conversation(chatID: chatID)
        await model.load()
        return (model, transport, services)
    }

    private func resolveBody(_ transport: StubTransport) async throws -> JSONValue {
        #expect(await until { transport.requests.contains { $0.url?.path().hasSuffix("/resolve") == true } })
        let request = try #require(transport.requests.first { $0.url?.path().hasSuffix("/resolve") == true })
        return try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    }

    @Test func aPausedRunAsksAndAllowResolvesIt() async throws {
        let (model, transport, services) = try await loaded()
        #expect(await until { !model.isStreaming })
        let pending = try #require(model.pendingApproval)
        #expect(pending.call.name == "run_command", "the call the server marked pending comes first")
        #expect(model.response(for: model.thread[1]).phase == .awaitingAnswer)
        #expect(!model.canSend)

        model.resolveApproval(allow: true)
        #expect(model.isStreaming)
        let body = try await resolveBody(transport)
        #expect(body == .object(["call_id": .string("call_1"), "action": .string("approve")]))
        // The next paused call waits its turn.
        #expect(model.pendingApproval?.call.name == "write_file")
        await services.stop()
    }

    @Test func denyRejectsTheCall() async throws {
        let (model, transport, services) = try await loaded()
        #expect(await until { model.pendingApproval != nil })
        model.resolveApproval(allow: false)
        let body = try await resolveBody(transport)
        #expect(body == .object(["call_id": .string("call_1"), "action": .string("reject")]))
        await services.stop()
    }

    @Test func askModeGoesOutOnlyWhenTheServerAllowsIt() throws {
        // Capability gating (ADR 0006): without `enable_tool_permissions` there's no switch and
        // requests keep the server's default ("full").
        let off = Capabilities.resolve(features: ServerFeatures(raw: [:]), user: SessionUser(id: "u", name: "U", email: "u@example.com", role: .admin, permissions: UserPermissions(raw: .object([:]))), model: nil)
        #expect(!off.contains(.toolApprovals))
        let on = Capabilities.resolve(features: ServerFeatures(raw: ["enable_tool_permissions": .bool(true)]), user: SessionUser(id: "u", name: "U", email: "u@example.com", role: .admin, permissions: UserPermissions(raw: .object([:]))), model: nil)
        #expect(on.contains(.toolApprovals))
    }
}
