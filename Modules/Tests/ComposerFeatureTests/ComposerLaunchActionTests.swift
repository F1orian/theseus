@testable import ComposerFeature
import Fixtures
import OpenWebUIKit
import Testing

/// Widget buttons and Shortcuts open the composer with an action (PLAT-01, PLAT-03), gated by
/// the model's and Server's Capabilities (ADR 0006).
@Suite("Composer launch actions (PLAT-01, PLAT-03)")
@MainActor
struct ComposerLaunchActionTests {
    @Test func cameraAndPhotosNeedAModelThatSees() {
        let seeing = ComposerModel(services: makeServices(StubTransport()), selectedModelID: vision.id)
        #expect(seeing.launchOutcome(.camera, cameraAvailable: true) == .camera)
        #expect(seeing.launchOutcome(.photos, cameraAvailable: false) == .photos)
        #expect(seeing.launchOutcome(.camera, cameraAvailable: false) == .notice("There's no camera on this device."))

        let blindComposer = ComposerModel(services: makeServices(StubTransport()), selectedModelID: blind.id)
        #expect(blindComposer.launchOutcome(.camera, cameraAvailable: true) == .notice("Blind can't see images."))
    }

    @Test func voiceNeedsTheServerToAllowIt() {
        let allowed = ComposerModel(services: makeServices(StubTransport()), selectedModelID: vision.id)
        #expect(allowed.launchOutcome(.dictation, cameraAvailable: true) == .dictation)
        #expect(allowed.launchOutcome(.voiceMode, cameraAvailable: true) == .voiceMode)

        let services = makeServices(StubTransport(), capabilities: [.imageInput])
        let denied = ComposerModel(services: services, selectedModelID: vision.id)
        #expect(denied.launchOutcome(.dictation, cameraAvailable: true) == .notice("Dictation isn't available on this Server."))
        #expect(denied.launchOutcome(.voiceMode, cameraAvailable: true) == .notice("Voice mode isn't available on this Server."))
    }
}
