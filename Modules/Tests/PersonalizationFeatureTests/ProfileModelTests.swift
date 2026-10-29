import Fixtures
import Foundation
import OpenWebUIKit
@testable import PersonalizationFeature
import Testing

@MainActor
@Suite("Profile (PERS-01) and Instructions (PERS-02)")
struct ProfileModelTests {
    let transport = StubTransport()
    let server = PersonalizationServer(settings: [
        "ui": .object(["system": .string("Be brief."), "memory": .bool(true), "hapticFeedback": .bool(false)]),
        "theseus": .object(["profile": .object(["nickname": .string("Ada")]), "capabilities": .object(["webSearch": .bool(true)])]),
    ])

    init() {
        server.install(on: transport)
    }

    func makeModel(_ enabled: Capabilities = capabilities(.instructions)) -> ProfileModel {
        ProfileModel(client: makeClient(transport), capabilities: enabled)
    }

    @Test func loadsNameNicknameAndInstructions() async {
        let model = makeModel()
        await model.load()
        #expect(model.fullName == "Ada Lovelace")
        #expect(model.nickname == "Ada")
        #expect(model.instructions == "Be brief.")
        #expect(model.showsInstructions)
        #expect(!model.hasChanges, "the save button stays unfilled until something changes")
    }

    @Test func instructionsAreHiddenWithoutTheirCapability() async {
        let model = makeModel(capabilities())
        await model.load()
        #expect(!model.showsInstructions)
        model.instructions = "Changed"
        #expect(!model.hasChanges, "hidden Instructions never count as a change")
    }

    @Test func savingWritesOnlyWhatChanged() async throws {
        let model = makeModel()
        await model.load()
        model.nickname = "  Lovelace "
        #expect(model.hasChanges)
        await model.save()

        #expect(model.errorMessage == nil)
        #expect(!model.hasChanges)
        #expect(model.nickname == "Lovelace")
        let paths = transport.requests.filter { $0.httpMethod == "POST" }.compactMap { $0.url?.path() }
        #expect(paths == ["/api/v1/users/user/settings/update"], "name and Instructions didn't change")
        let settings = UserSettings(raw: server.settings)
        #expect(settings.profilePreferences.nickname == "Lovelace")
        #expect(settings.capabilityDefaults.webSearch, "other theseus keys survive")
        #expect(settings.raw["ui"]?[path: "hapticFeedback"] == .bool(false), "the web client's keys survive")
    }

    @Test func savingTheNameKeepsTheRestOfTheProfile() async {
        let model = makeModel()
        var reported: String?
        model.onNameChange = { reported = $0 }
        await model.load()
        model.fullName = "Augusta Ada King"
        await model.save()
        #expect(server.profileName == "Augusta Ada King")
        #expect(server.state.withLock { $0.profile["bio"] } == .string("Mathematician"))
        #expect(reported == "Augusta Ada King")
        #expect(!model.hasChanges)
    }

    @Test func anEmptyNicknameIsRemoved() async {
        let model = makeModel()
        await model.load()
        model.nickname = "   "
        await model.save()
        #expect(UserSettings(raw: server.settings).profilePreferences.nickname == nil)
    }

    @Test func aBlankFullNameCannotBeSaved() async {
        let model = makeModel()
        await model.load()
        model.fullName = "  "
        #expect(model.hasChanges)
        #expect(!model.canSave)
    }

    @Test func instructionsArePatchedIntoTheWebClientKey() async {
        let model = makeModel()
        await model.load()
        model.instructions = "Answer in German."
        await model.save()
        #expect(server.settings["ui"]?[path: "system"] == .string("Answer in German."))
        #expect(server.settings["ui"]?[path: "memory"] == .bool(true))
    }

    @Test func aFailedSaveKeepsTheEditsAndReportsIt() async {
        server.fail("api/v1/auths/update/profile")
        let model = makeModel()
        await model.load()
        model.fullName = "New Name"
        model.nickname = "Nick"
        await model.save()
        #expect(model.errorMessage != nil)
        #expect(model.hasChanges, "the unsaved name is still pending")
        #expect(model.fullName == "New Name")
        #expect(UserSettings(raw: server.settings).profilePreferences.nickname == "Nick", "the parts that worked are kept")
    }

    @Test func aFailedLoadShowsAnError() async {
        server.fail("api/v1/auths/")
        let model = makeModel()
        await model.load()
        #expect(model.errorMessage != nil)
        #expect(!model.isLoaded)
    }

    // MARK: Instructions page

    @Test func theInstructionsPageEditsOnlyInstructions() async {
        let model = InstructionsModel(client: makeClient(transport))
        await model.load()
        #expect(model.text == "Be brief.")
        #expect(!model.hasChanges)
        model.text = ""
        #expect(model.hasChanges)
        await model.save()
        #expect(model.errorMessage == nil)
        #expect(server.settings["ui"]?[path: "system"] == .string(""), "an empty string clears the Instructions")
        #expect(!model.hasChanges)
    }

    @Test func instructionsTheServerDroppedAreReported() async {
        // Without chat.controls + chat.system_prompt the server silently drops `ui.system`.
        transport.stub("POST", "api/v1/users/user/settings/update") { _ in
            (200, Data(#"{"ui":{"system":"Be brief."}}"#.utf8))
        }
        let model = InstructionsModel(client: makeClient(transport))
        await model.load()
        model.text = "Something else"
        await model.save()
        #expect(model.errorMessage != nil)
        #expect(model.hasChanges)
    }
}
