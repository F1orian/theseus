import Auth
import Entitlements
import Fixtures
import Foundation
@testable import OnboardingFeature
import Testing

/// AUTH-07: the Account switcher's rows.
@MainActor
@Suite("Account switcher")
struct AccountSwitcherTests {
    let home = ServerProfile(url: Fixture.serverURL, name: "Home")
    let work = ServerProfile(url: URL(string: "https://work.example.com") ?? Fixture.serverURL, name: "Work")

    @Test func groupsAccountsByServerAndMarksTheActiveAndSignedOutOnes() throws {
        let registry = AccountRegistry(fileURL: nil)
        let credentials = InMemoryCredentialStore()
        let zoe = Account(server: home, userID: "1", name: "Zoe", email: "zoe@home")
        let adam = Account(server: home, userID: "2", name: "Adam", email: "adam@home")
        let me = Account(server: work, userID: "3", name: "Me", email: "me@work")
        try credentials.save(Credential(sessionToken: "t"), for: zoe.id)
        try credentials.save(Credential(sessionToken: "t"), for: me.id)
        // A token past its exp counts as signed out.
        try credentials.save(Credential(sessionToken: "e30.eyJleHAiOjEwMDB9.c2ln"), for: adam.id)
        for account in [zoe, me, adam] { try registry.activate(account) }
        try registry.activate(me)

        let model = AccountSwitcherModel(registry: registry, credentials: credentials, actions: .init(
            switchTo: { _ in }, addAccount: {}, remove: { _ in }
        ))

        #expect(model.groups.map(\.server.name) == ["Home", "Work"])
        let homeRows = try #require(model.groups.first?.rows)
        #expect(homeRows.map(\.account.name) == ["Adam", "Zoe"])
        #expect(homeRows.map(\.isSignedIn) == [false, true])
        #expect(model.groups.last?.rows.first?.isActive == true)
    }

    @Test func selectingTheActiveAccountDoesNothing() async throws {
        let registry = AccountRegistry(fileURL: nil)
        let me = Account(server: work, userID: "3", name: "Me", email: "me@work")
        try registry.activate(me)
        var switched: [Account] = []
        let model = AccountSwitcherModel(registry: registry, credentials: InMemoryCredentialStore(), actions: .init(
            switchTo: { switched.append($0) }, addAccount: {}, remove: { _ in }
        ))
        let row = try #require(model.groups.first?.rows.first)
        await model.select(row)
        #expect(switched.isEmpty)
    }

    // MARK: Theseus Pro (ADR 0173)

    @Test func theFreeTierAsksForProBeforeAddingOrSwitching() async throws {
        let registry = AccountRegistry(fileURL: nil)
        let zoe = Account(server: home, userID: "1", name: "Zoe", email: "zoe@home")
        let me = Account(server: work, userID: "3", name: "Me", email: "me@work")
        for account in [zoe, me] { try registry.activate(account) }
        var switched: [Account] = []
        var added = 0
        let model = AccountSwitcherModel(registry: registry, credentials: InMemoryCredentialStore(), actions: .init(
            switchTo: { switched.append($0) }, addAccount: { added += 1 }, remove: { _ in }
        ))
        model.pro = .free()
        #expect(model.addingNeedsPro)
        #expect(!model.addAccount())
        #expect(model.paywallRequest == PaywallRequest(.accounts))
        model.paywallRequest = nil
        let other = try #require(model.groups.flatMap(\.rows).first { !$0.isActive })
        #expect(await model.select(other) == false)
        #expect(model.paywallRequest == PaywallRequest(.accounts))
        #expect(switched.isEmpty && added == 0)

        model.pro = .unlocked()
        #expect(!model.addingNeedsPro)
        #expect(model.addAccount())
        #expect(await model.select(other))
        #expect(switched == [zoe] && added == 1)
    }
}
