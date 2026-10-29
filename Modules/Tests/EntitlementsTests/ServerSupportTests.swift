import Entitlements
import Testing

/// ADR 0173 (addendum): the paywall promises only what the active Account's Server offers, and
/// qualifies what isn't known yet.
@Suite("What the Server offers")
struct ServerSupportTests {
    @Test func unknownShowsEverythingWithTheQualifier() {
        let support = ServerSupport.unknown
        #expect(support.checklist() == ProFeature.checklist)
        #expect(support.detail(for: .sandbox).contains("when your Server supports it"))
        #expect(support.detail(for: .sandbox).contains("Free includes 5 runs a day."))
        #expect(support.detail(for: .skills).contains("when your Server supports them"))
        #expect(support.detail(for: .connectors).contains("when your Server supports them"))
        #expect(support.detail(for: .connectors) == ProFeature.connectors.detail)
        // Features that don't depend on the Server never carry it.
        #expect(!support.detail(for: .voiceMode).contains("Server supports"))
        #expect(support.detail(for: .sandbox) == ProFeature.sandbox.detail)
        #expect(support.detail(for: .skills) == ProFeature.skills.detail)
    }

    @Test func aServerWithoutCodeExecutionLeavesItOut() {
        let support = ServerSupport(codeExecution: .none, skills: true, connectors: true)
        #expect(support.checklist() == [.skills, .connectors, .voiceMode, .accounts, .platform, .appIcons])
        #expect(support.offers(.sandbox) == false)
        #expect(!support.mentionsCodeExecutionRuns)
    }

    @Test func aServerWithoutSkillsLeavesThemOut() {
        let support = ServerSupport(codeExecution: .none, skills: false, connectors: true)
        #expect(support.checklist() == [.connectors, .voiceMode, .accounts, .platform, .appIcons])
    }

    @Test func connectorsFollowTheServerToo() {
        let none = ServerSupport(codeExecution: .sandbox, skills: true, connectors: false)
        #expect(!none.checklist().contains(.connectors))
        let some = ServerSupport(codeExecution: .sandbox, skills: true, connectors: true)
        #expect(some.detail(for: .connectors) == "Turn on tools and MCP servers in any chat. The ones a model comes with stay free.")
        #expect(ServerSupport(codeExecution: .sandbox, skills: true).checklist().contains(.connectors), "unknown shows, qualified")
    }

    @Test func aSandboxPromisesFilesAndAnInterpreterOnlyCode() {
        let sandbox = ServerSupport(codeExecution: .sandbox, skills: true, connectors: true)
        #expect(sandbox.checklist() == ProFeature.checklist)
        #expect(sandbox.detail(for: .sandbox) == "Run code and create files as often as you like. Free includes 5 runs a day.")
        #expect(sandbox.detail(for: .skills) == "Use your Server's Skills, like deep research and documents.")
        let interpreter = ServerSupport(codeExecution: .interpreter, skills: nil)
        #expect(interpreter.detail(for: .sandbox) == "Run code as often as you like. Free includes 5 runs a day.")
        #expect(interpreter.mentionsCodeExecutionRuns)
    }

    @Test func theGatesFeatureStillLeads() {
        // A contextual paywall keeps its feature first, even if the Server's offer is stale.
        let support = ServerSupport(codeExecution: .none, skills: false, connectors: false)
        #expect(support.checklist(leading: .sandbox).first == .sandbox)
        #expect(support.checklist(leading: .skills) == [.skills, .voiceMode, .accounts, .platform, .appIcons])
        #expect(support.checklist(leading: .connectors).first == .connectors)
        #expect(ServerSupport.unknown.checklist(leading: .voiceMode).first == .voiceMode)
    }

    @Test func theUpgradeCardNamesWhatTheServerOffers() {
        #expect(ServerSupport(codeExecution: .sandbox, skills: true).upgradeSummary
            == "Unlimited code execution, Skills, Voice mode and more.")
        #expect(ServerSupport(codeExecution: .none, skills: true).upgradeSummary
            == "Skills, Voice mode, widgets and more.")
        #expect(ServerSupport(codeExecution: .none, skills: false).upgradeSummary
            == "Voice mode, widgets, more Accounts and more.")
        #expect(ServerSupport.unknown.upgradeSummary
            == "Voice mode, widgets and more, plus unlimited code execution and Skills when your Server supports them.")
        #expect(ServerSupport(codeExecution: .interpreter, skills: nil).upgradeSummary
            == "Unlimited code execution, Voice mode and more, plus Skills when your Server supports them.")
    }
}
