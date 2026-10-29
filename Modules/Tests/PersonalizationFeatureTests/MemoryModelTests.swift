import Fixtures
import Foundation
import OpenWebUIKit
@testable import PersonalizationFeature
import Testing

@MainActor
@Suite("Memory settings (PERS-03) and Memory summary (PERS-04)")
struct MemoryModelTests {
    let transport = StubTransport()
    let server = PersonalizationServer()

    init() {
        server.install(on: transport)
    }

    func makeSettings(_ enabled: Capabilities = capabilities(.memory)) -> MemorySettingsModel {
        MemorySettingsModel(client: makeClient(transport), capabilities: enabled)
    }

    // MARK: Settings (PERS-03)

    @Test func theSwitchReflectsTheSharedMemoryKey() async {
        let model = makeSettings()
        #expect(model.isAvailable)
        await model.load()
        #expect(model.isOn)

        let off = PersonalizationServer(settings: ["ui": .object(["memory": .bool(false)])])
        let offTransport = StubTransport()
        off.install(on: offTransport)
        let offModel = MemorySettingsModel(client: makeClient(offTransport), capabilities: capabilities(.memory))
        await offModel.load()
        #expect(!offModel.isOn)
    }

    @Test func memoryIsOnUntilTheUserTurnsItOff() async {
        let fresh = PersonalizationServer(settings: [:])
        let freshTransport = StubTransport()
        fresh.install(on: freshTransport)
        let model = MemorySettingsModel(client: makeClient(freshTransport), capabilities: capabilities(.memory))
        await model.load()
        #expect(model.isOn)
    }

    @Test func withoutTheCapabilityNothingShows() {
        #expect(!makeSettings(capabilities()).isAvailable)
    }

    @Test func turningMemoryOffPatchesOnlyThatKey() async {
        let model = makeSettings()
        await model.load()
        await model.setOn(false)
        #expect(!model.isOn)
        #expect(server.settings["ui"]?[path: "memory"] == .bool(false))
        #expect(server.settings["ui"]?[path: "system"] == .string("Be brief."))
    }

    @Test func aFailedSwitchRevertsWithAnError() async {
        server.fail("api/v1/users/user/settings/update")
        let model = makeSettings()
        await model.load()
        await model.setOn(false)
        #expect(model.isOn)
        #expect(model.errorMessage != nil)
    }

    @Test func theRowShowsWhenMemoryWasLastUpdated() async {
        server.addMemory("Likes tea", at: 1_000)
        server.addMemory("Lives in Hamburg", at: 5_000)
        let model = makeSettings()
        await model.load()
        #expect(model.summary.lastUpdated == Date(timeIntervalSince1970: 5_000))
        let now = Date(timeIntervalSince1970: 5_000 + 12 * 3_600)
        #expect(model.summary.updatedText(relativeTo: now)?.hasPrefix("Updated ") == true)

        let empty = MemorySummaryModel(client: makeClient(StubTransport()))
        #expect(empty.updatedText(relativeTo: now) == nil)
    }

    // MARK: Summary (PERS-04)

    @Test func entriesAreGroupedIntoSections() {
        let date = Date(timeIntervalSince1970: 0)
        let entries = [
            MemoryEntry(id: "1", content: "Is a teacher", path: "work", kind: .user, createdAt: date, updatedAt: date),
            MemoryEntry(id: "2", content: "Vegetarian", path: nil, kind: .user, createdAt: date, updatedAt: date),
            MemoryEntry(id: "3", content: "Uses SwiftUI", path: "work/side_projects", kind: .context, createdAt: date, updatedAt: date),
            MemoryEntry(id: "4", content: "Asked about tides", path: nil, kind: .context, createdAt: date, updatedAt: date),
            MemoryEntry(id: "5", content: "Teaches maths", path: "Work/", kind: .user, createdAt: date.addingTimeInterval(1), updatedAt: date),
        ]
        let sections = MemorySection.group(entries)
        #expect(sections.map(\.title) == ["About you", "Work", "Work › Side projects", "Other context"])
        #expect(sections[1].entries.map(\.id) == ["1", "5"], "paths group case-insensitively, oldest first")
        #expect(sections.last?.entries.map(\.id) == ["4"])
    }

    @Test func addEditAndDeleteKeepTheListInStep() async throws {
        let model = MemorySummaryModel(client: makeClient(transport))
        await model.load()
        #expect(model.entries.isEmpty)
        #expect(model.isLoaded)

        await model.add(content: "  Prefers metric units ", path: " preferences/units ")
        let added = try #require(model.entries.first)
        #expect(added.content == "Prefers metric units")
        #expect(added.path == "preferences/units")
        #expect(added.kind == .user)

        await model.update(added, content: "Prefers metric units and 24-hour time", path: "")
        #expect(model.entries.first?.content == "Prefers metric units and 24-hour time")
        #expect(model.entries.first?.path == nil, "clearing the topic removes the path")
        #expect(server.memoryContents == ["Prefers metric units and 24-hour time"])

        await model.delete(added)
        #expect(model.entries.isEmpty)
        #expect(server.memoryContents.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func emptyContentIsNotSaved() async {
        let model = MemorySummaryModel(client: makeClient(transport))
        await model.load()
        await model.add(content: "   ", path: nil)
        #expect(model.entries.isEmpty)
        #expect(transport.requests.allSatisfy { $0.httpMethod != "POST" })
    }

    @Test func forgetAllEmptiesMemory() async {
        server.addMemory("Likes tea")
        server.addMemory("Lives in Hamburg", path: "home")
        let model = MemorySummaryModel(client: makeClient(transport))
        await model.load()
        #expect(model.entries.count == 2)
        await model.forgetAll()
        #expect(model.entries.isEmpty)
        #expect(server.memoryContents.isEmpty)
        #expect(!model.isEditing, "editing ends once there is nothing left")
    }

    @Test func aFailedDeleteKeepsTheEntry() async {
        server.addMemory("Likes tea")
        let model = MemorySummaryModel(client: makeClient(transport))
        await model.load()
        server.fail("api/v1/memories/m1")
        await model.delete(model.entries[0])
        #expect(model.entries.count == 1)
        #expect(model.errorMessage != nil)
    }
}
