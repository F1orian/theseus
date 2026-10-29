import ChatDomain
import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Readable step titles for Skills and sub-agents (#140), from the recorded `skills` scenario.
@Suite("Skill and sub-agent steps")
struct SkillStepTests {
    @Test func skillAndSubAgentStepsReadNaturally() async throws {
        let fixture = StreamFixture("skills")
        let ids = try fixture.ids()
        let chat = try await storedChat(fixture)
        let titles = ids.allTurns.flatMap { turn -> [String] in
            guard let message = chat.tree[turn.assistant] else { return [] }
            return message.response.parts.flatMap { part -> [String] in
                if case .tools(_, let tools) = part { return tools.map(\.title) }
                return []
            }
        }
        #expect(titles == ["Read the xlsx skill", "Sub-agent: What is 6 times 7? Answer with the number only."])

        let running = ToolActivity(id: "1", name: "view_skill", arguments: #"{"id":"deep-research"}"#, isRunning: true)
        #expect(running.title == "Reading the deep-research skill")
    }

    @Test func aPickedSkillReachesTheServer() async throws {
        // The third turn was sent with skill_ids: ["discernment-nudge"]; the server took it.
        let fixture = StreamFixture("skills")
        let ids = try fixture.ids()
        let chat = try await storedChat(fixture)
        let third = try #require(chat.tree[ids.allTurns[2].assistant])
        #expect(third.response.phase == .completed)
        #expect(!third.response.text.isEmpty)
    }
}
