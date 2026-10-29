import Auth
import Fixtures
import Foundation
@testable import OnboardingFeature
import OpenWebUIKit
import Testing

@MainActor
@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    let transport = StubTransport()

    @Test func startsAtServerEntryWithTheAddressPrefilled() throws {
        let flow = OnboardingFlow(start: .serverEntry(address: "chat.example.com"), transport: transport) { _ in }
        guard case .serverEntry(let entry) = flow.step else {
            Issue.record("Expected Server entry, got \(flow.step)")
            return
        }
        #expect(entry.address == "chat.example.com")
    }
}
