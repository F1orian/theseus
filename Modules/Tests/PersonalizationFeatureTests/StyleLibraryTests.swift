import Fixtures
import Foundation
import OpenWebUIKit
@testable import PersonalizationFeature
import Testing

@MainActor
@Suite("Styles (PERS-05)")
struct StyleLibraryTests {
    let transport = StubTransport()
    let server = PersonalizationServer(settings: [
        "ui": .object(["system": .string("Be brief.")]),
        "theseus": .object(["profile": .object(["nickname": .string("Ada")])]),
    ])

    init() {
        server.install(on: transport)
    }

    func makeLibrary() -> StyleLibrary {
        StyleLibrary(client: makeClient(transport), makeID: { "style-1" })
    }

    private var stored: StylePreferences {
        UserSettings(raw: server.settings).stylePreferences
    }

    @Test func startsOnNormalWithThePresets() async {
        let library = makeLibrary()
        await library.load()
        #expect(library.selected == .normal)
        #expect(library.selectedInstructions == nil)
        #expect(library.styles.map(\.name) == ["Normal", "Concise", "Explanatory", "Formal"])
        #expect(library.styles.dropFirst().allSatisfy { !$0.instructions.isEmpty })
    }

    @Test func choosingAPresetRoamsInTheTheseusNamespace() async {
        let library = makeLibrary()
        await library.load()
        let concise = try? #require(library.styles.first { $0.id == "concise" })
        await library.select(concise ?? .normal)
        #expect(library.selected.id == "concise")
        #expect(library.selectedInstructions?.contains("brief") == true)
        #expect(stored.selected == "concise")
        #expect(UserSettings(raw: server.settings).nickname == "Ada", "other theseus keys survive")
        #expect(UserSettings(raw: server.settings).instructions == "Be brief.", "Instructions are untouched")

        await library.select(.normal)
        #expect(stored.selected == nil)
        #expect(library.selectedInstructions == nil)
    }

    @Test func aCustomStyleIsSavedChosenAndDeleted() async {
        let library = makeLibrary()
        await library.load()
        let id = await library.save(id: nil, name: "  Pirate ", instructions: "Talk like a pirate.\nSay Arr.")
        #expect(stored.custom == [CustomStyle(id: "style-1", name: "Pirate", instructions: "Talk like a pirate.\nSay Arr.")])
        let pirate = library.styles.last
        #expect(pirate?.isCustom == true)
        #expect(pirate?.summary == "Talk like a pirate.")

        await library.select(pirate ?? .normal)
        #expect(library.selectedInstructions == "Talk like a pirate.\nSay Arr.")

        await library.save(id: id, name: "Pirate", instructions: "Talk like a pirate.")
        #expect(stored.custom.count == 1, "editing updates in place")
        #expect(library.selectedInstructions == "Talk like a pirate.")

        await library.delete(id)
        #expect(stored.custom.isEmpty)
        #expect(stored.selected == nil, "deleting the chosen Style goes back to Normal")
        #expect(library.selected == .normal)
    }

    @Test func aFailedWriteRestoresTheChoice() async {
        let library = makeLibrary()
        await library.load()
        server.fail("api/v1/users/user/settings/update")
        await library.select(Style.presets[1])
        #expect(library.selected == .normal)
        #expect(library.errorMessage != nil)
    }

    @Test func aChosenStyleDeletedElsewhereFallsBackToNormal() {
        let library = makeLibrary()
        library.apply(UserSettings(raw: ["theseus": .object(["styles": .object(["selected": .string("gone")])])]))
        #expect(library.selected == .normal)
        #expect(library.selectedInstructions == nil)
    }

    @Test func aStyleNeedsANameAndInstructions() {
        #expect(StyleLibrary.canSave(name: "Haiku", instructions: "Answer in haiku."))
        #expect(!StyleLibrary.canSave(name: "  ", instructions: "Answer in haiku."))
        #expect(!StyleLibrary.canSave(name: "Haiku", instructions: "\n"))
    }
}
