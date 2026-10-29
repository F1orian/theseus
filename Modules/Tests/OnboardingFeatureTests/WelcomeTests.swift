@testable import OnboardingFeature
import OpenWebUIKit
import Testing

@Suite("Welcome (AUTH-08)")
struct WelcomeTests {
    private func summary(
        _ enabled: Set<Capability>, savesChats: Bool = true, speechOnDevice: Bool = true, connectors: [String] = []
    ) -> WelcomeSummary {
        WelcomeSummary(
            host: "chat.example.com", capabilities: Capabilities(enabled: enabled),
            savesChats: savesChats, speechOnDevice: speechOnDevice, connectorNames: connectors
        )
    }

    @Test func listsWhatTheServerOffers() {
        let welcome = summary([.voiceMode, .dictation, .projects, .webSearch, .connectors, .memory], connectors: ["Weather", "GitHub"])
        #expect(welcome.items.map(\.id) == ["chats", "voice", "projects", "webSearch", "connectors", "memory"])
        #expect(welcome.items.first { $0.id == "voice" }?.text.contains("on this device") == true)
        #expect(welcome.items.first { $0.id == "connectors" }?.text.contains("Weather and GitHub") == true)
        #expect(welcome.items.first { $0.id == "chats" }?.text.contains("chat.example.com") == true)
    }

    @Test func hidesWhatItDoesntAndExplainsProjects() {
        let welcome = summary([])
        #expect(welcome.items.map(\.id) == ["chats", "projects"])
        #expect(welcome.items.first { $0.id == "projects" }?.text.contains("need folders") == true)
    }

    @Test func serverSpeechAndEnforcedIncognito() {
        let welcome = summary([.voiceMode], savesChats: false, speechOnDevice: false)
        #expect(welcome.items.first { $0.id == "voice" }?.text.contains("speech engines") == true)
        #expect(welcome.items.first { $0.id == "chats" }?.symbol == "theatermasks")
    }

    @Test func connectorsNeedTheCapabilityAndAName() {
        #expect(!summary([.connectors]).items.contains { $0.id == "connectors" })
        #expect(!summary([], connectors: ["Weather"]).items.contains { $0.id == "connectors" })
    }

    @Test func longConnectorListsAreShortened() {
        #expect(WelcomeSummary.list(["A"]) == "A")
        #expect(WelcomeSummary.list(["A", "B", "C"]) == "A, B and C")
        #expect(WelcomeSummary.list(["A", "B", "C", "D", "E"]) == "A, B and 3 more")
    }
}
