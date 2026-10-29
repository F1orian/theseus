@testable import ComposerFeature
import Fixtures
import Foundation
import OpenWebUIKit
import Testing

/// Per-Chat Skills (#140) list the Account's own Skills and the shared ones (#187).
@MainActor
@Suite("Composer skills")
struct ComposerSkillTests {
    private func services(_ transport: StubTransport, role: String) throws -> ComposerServices {
        let user = #"{"id":"00000000-0000-4000-8000-000000000001","name":"Test User","email":"user@example.com","role":"\#(role)"}"#
        transport.stub("GET", "api/v1/auths/", body: Data(user.utf8))
        try transport.stub("GET", "api/v1/skills/", fixture: "synthetic/skills.mixed.json")
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
        return ComposerServices(client: client, models: [], defaultModelIDs: []) { _ in Capabilities(enabled: []) }
    }

    @Test func yoursComeFirstThenShared() async throws {
        let services = try services(StubTransport(), role: "user")
        await services.refresh()
        // tone-check is off, so Chats don't offer it.
        #expect(services.yourSkills.map(\.id) == ["meeting-notes"])
        #expect(services.sharedSkills.map(\.id) == ["brand-voice", "drafts", "legal-review", "pair-review"])
    }

    @Test func adminsDontGetOthersPrivateSkills() async throws {
        let services = try services(StubTransport(), role: "admin")
        await services.refresh()
        #expect(services.skills.map(\.id) == ["brand-voice", "legal-review", "meeting-notes", "pair-review"])
        #expect(!services.skills.contains { $0.id == "drafts" })
    }

    @Test func pickedSharedSkillsGoOutWithTheMessage() async throws {
        let services = try services(StubTransport(), role: "user")
        await services.refresh()
        let composer = ComposerModel(services: services)
        composer.setSkill("brand-voice", selected: true)
        composer.setSkill("meeting-notes", selected: true)
        #expect(composer.selectedSkills.map(\.id) == ["brand-voice", "meeting-notes"])
    }

    @Test func withoutTheAccountEverySkillIsShared() async throws {
        let transport = StubTransport()
        try transport.stub("GET", "api/v1/skills/", fixture: "skills.json")
        let client = OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticToken())
        let services = ComposerServices(client: client, models: [], defaultModelIDs: []) { _ in Capabilities(enabled: []) }
        await services.refresh()
        #expect(services.skills.count == 12, "the recorded Skills still list when /auths/ fails")
        #expect(services.yourSkills.isEmpty)
    }
}
