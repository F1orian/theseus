import Fixtures
import OpenWebUIKit
@testable import PersonalizationFeature
import SettingsFeature
import Testing

@MainActor
@Suite("Settings registration")
struct RegistrationTests {
    @Test func profileInstructionsAndMemoryArePluggedIn() {
        var extensions = SettingsExtensions()
        PersonalizationSettings.register(in: &extensions, client: makeClient(StubTransport()), capabilities: { capabilities(.memory) })
        #expect(extensions.isRegistered(.profile))
        #expect(extensions.isRegistered(.instructions))
        #expect(extensions.isRegistered(.memory))
        #expect(extensions.content(for: .capabilitiesMemory) != nil)
        #expect(!extensions.isRegistered(.styles), "Styles (PERS-05) is not registered yet")
    }
}
