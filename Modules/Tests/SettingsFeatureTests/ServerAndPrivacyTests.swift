import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import Testing

@MainActor
@Suite("Server & usage (SET-09)")
struct ServerUsageTests {
    let transport = StubTransport()

    init() throws {
        try transport.stub("GET", "api/version", fixture: "version.json")
        try transport.stub("GET", "api/v1/auths/", fixture: "auths.json")
        try transport.stub("GET", "api/v1/users/usage", fixture: "users.usage.json")
    }

    @Test func showsTheServerTheRoleAndPersonalUsage() async throws {
        let model = ServerUsageModel(account: testAccount, client: makeClient(transport), user: nil)
        await model.load()
        #expect(model.serverHost == "owui.example.com")
        #expect(model.serverVersion == "0.12.3")
        #expect(model.role == "Admin")
        let usage = try #require(model.usage)
        #expect(usage.totals.chats == 42)
        #expect(model.usageError == nil)
    }

    @Test func serverDetailsStayWhenUsageIsUnavailable() async throws {
        transport.stub("GET", "api/v1/users/usage", status: 404, body: Data(#"{"detail":"Not Found"}"#.utf8))
        let model = ServerUsageModel(account: testAccount, client: makeClient(transport), user: nil)
        await model.load()
        #expect(model.serverVersion == "0.12.3")
        #expect(model.usage == nil)
        #expect(model.usageError != nil)
    }

    @Test func tokenCountsAreCompact() {
        #expect(ServerUsageModel.compact(12_645_250, locale: Locale(identifier: "en_US")) == "12.6M")
        #expect(ServerUsageModel.compact(950, locale: Locale(identifier: "en_US")) == "950")
    }
}

@MainActor
@Suite("Data & privacy and delete account (SET-07, SET-10)")
struct DataPrivacyTests {
    let transport = StubTransport()
    let log = ActionLog()

    func makeModel() -> DataPrivacyModel {
        DataPrivacyModel(account: testAccount, client: makeClient(transport), actions: log.actions)
    }

    @Test func showsWhereDataLivesAndTheAdminContact() async throws {
        try transport.stub("GET", "api/v1/auths/admin/details", fixture: "admin-details.json")
        let model = makeModel()
        await model.load()
        #expect(model.serverHost == "owui.example.com")
        #expect(model.adminContact == AdminContact(name: "Server Admin", email: "admin@example.com"))
        #expect(model.adminEmailURL?.absoluteString == "mailto:admin@example.com")
        #expect(model.cacheSize == 2_048)
    }

    @Test func serversThatHideTheAdminShowNoContact() async throws {
        transport.stub("GET", "api/v1/auths/admin/details", status: 400, body: Data(#"{"detail":"Action prohibited"}"#.utf8))
        let model = makeModel()
        await model.load()
        #expect(model.adminContact == nil)
        #expect(model.adminEmailURL == nil)
        #expect(model.errorMessage == nil, "a hidden admin isn't an error")
    }

    @Test func clearingTheCacheAsksTheAppAndRemeasures() async {
        let model = makeModel()
        await model.clearCache()
        #expect(log.events == ["clearCache"])
        #expect(model.didClearCache)
    }

    @Test func removingTheAccountAsksTheApp() async {
        let model = makeModel()
        await model.removeAccountFromDevice()
        #expect(log.events == ["remove"])
    }
}
