import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import SwiftUI
import Testing

@MainActor
@Suite("Server administration (#186)")
struct ServerAdministrationTests {
    let transport = StubTransport()

    private func makeModel() -> SettingsModel {
        SettingsModel(
            account: testAccount,
            client: makeClient(transport),
            preferences: AccountPreferencesStore(accountID: testAccount.id, defaults: makeDefaults()),
            capabilities: Capabilities(enabled: []),
            actions: ActionLog().actions
        )
    }

    private func stubSession(role: String) throws {
        try transport.stub("GET", "api/config", fixture: "config.json")
        var user = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("auths.json")).objectValue ?? [:]
        user["role"] = .string(role)
        transport.stub("GET", "api/v1/auths/", body: try JSONEncoder().encode(JSONValue.object(user)))
    }

    @Test func onlyAdminsSeeServerAdministration() async throws {
        try stubSession(role: "user")
        let model = makeModel()
        #expect(!model.showsAdministration, "Hidden until the role is known")
        await model.load()
        #expect(!model.showsAdministration)

        try stubSession(role: "admin")
        await model.load()
        #expect(model.showsAdministration)
        #expect(model.serverHost == "owui.example.com")
    }

    @Test func featureAreasContributeRowsInOrder() {
        var extensions = SettingsExtensions()
        extensions.registerAdministration(SettingsAdministrationRow(
            id: "skills", title: "Skills", systemImage: "book.closed", order: SettingsAdministrationRow.Order.skills
        ) { Text("Skills") })
        extensions.registerAdministration(SettingsAdministrationRow(
            id: "connectors", title: "Connectors", systemImage: "square.grid.2x2", order: SettingsAdministrationRow.Order.connectors
        ) { Text("Connectors") })
        // Registering an id again replaces its row.
        extensions.registerAdministration(SettingsAdministrationRow(
            id: "skills", title: "Shared skills", systemImage: "book.closed", order: SettingsAdministrationRow.Order.skills
        ) { Text("Skills") })

        #expect(extensions.administrationRows.map(\.id) == ["connectors", "skills"])
        #expect(extensions.administrationRows.last?.title == "Shared skills")
        #expect(extensions.administrationDestination(for: "connectors") != nil)
        #expect(extensions.administrationDestination(for: "missing") == nil)
    }
}

@MainActor
@Suite("User permissions (#186)")
struct UserPermissionsTests {
    let transport = StubTransport()

    @Test func showsTheCurrentDefaults() async throws {
        try transport.stub("GET", "api/v1/users/default/permissions", fixture: "users.default-permissions.json")
        let model = UserPermissionsModel(client: makeClient(transport), host: "owui.example.com")
        await model.load()
        #expect(model.state == .loaded)
        // Recorded from the test Server (0.12.3): both off by default.
        #expect(!model.isOn(.personalConnectors))
        #expect(!model.isOn(.createSkills))
    }

    @Test func asksBeforeSavingAndWritesOnlyTheChangedKey() async throws {
        try transport.stub("GET", "api/v1/users/default/permissions", fixture: "users.default-permissions.json")
        transport.stub("POST", "api/v1/users/default/permissions") { request in
            (200, request.httpBody ?? Data())
        }
        let model = UserPermissionsModel(client: makeClient(transport), host: "owui.example.com")
        await model.load()

        model.request(.personalConnectors, on: true)
        #expect(model.pending?.newValue == true)
        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" }, "Nothing is written before confirming")

        await model.confirm()
        #expect(model.isOn(.personalConnectors))
        // Re-read right before writing, then one POST.
        let methods = transport.requests.map { $0.httpMethod ?? "" }
        #expect(methods == ["GET", "GET", "POST"])
        let sent = try JSONDecoder().decode(JSONValue.self, from: transport.requests.last?.httpBody ?? Data())
        let original = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("users.default-permissions.json"))
        var expected = DefaultUserPermissions(raw: original)
        expected.set(DefaultUserPermissions.personalConnectors, to: true)
        #expect(sent == expected.raw, "Every other key goes back as it was read")
    }

    @Test func cancellingWritesNothing() async throws {
        try transport.stub("GET", "api/v1/users/default/permissions", fixture: "users.default-permissions.json")
        let model = UserPermissionsModel(client: makeClient(transport), host: "owui.example.com")
        await model.load()
        model.request(.createSkills, on: true)
        model.cancel()
        #expect(model.pending == nil)
        #expect(!model.isOn(.createSkills))
        #expect(transport.requests.count == 1)
    }

    @Test func aFailedSaveReportsAndReloads() async throws {
        try transport.stub("GET", "api/v1/users/default/permissions", fixture: "users.default-permissions.json")
        transport.stub("POST", "api/v1/users/default/permissions", status: 403, body: Data(#"{"detail":"Not authorized"}"#.utf8))
        let model = UserPermissionsModel(client: makeClient(transport), host: "owui.example.com")
        await model.load()
        model.request(.personalConnectors, on: true)
        await model.confirm()
        #expect(model.notice != nil)
        #expect(!model.isOn(.personalConnectors))
    }
}
