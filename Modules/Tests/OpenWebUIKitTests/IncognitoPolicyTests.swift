import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// INCOG-02: whether the Account may use Incognito chats (`chat.temporary`) and whether the Server
/// enforces them (`chat.temporary_enforced`).
@Suite("Incognito policy (INCOG-02)")
struct IncognitoPolicyTests {
    func user(_ role: UserRole = .user, chat: [String: Bool]) -> SessionUser {
        SessionUser(
            id: "u", name: "U", email: "u@example.com", role: role,
            permissions: UserPermissions(raw: .object(["chat": .object(chat.mapValues(JSONValue.bool))]))
        )
    }

    @Test func theRecordedAdminMayChooseIncognito() throws {
        let admin = try Endpoint.sessionUser.decode(Fixture.data("auths.json"))
        #expect(IncognitoPolicy(user: admin) == .available)
    }

    @Test func usersNeedTheTemporaryPermission() {
        #expect(IncognitoPolicy(user: user(chat: ["temporary": true])) == .available)
        #expect(IncognitoPolicy(user: user(chat: ["temporary": false])) == .unavailable)
        #expect(IncognitoPolicy(user: user(chat: [:])) == .unavailable)
    }

    @Test func enforcementOnlyCountsWhenIncognitoIsAllowed() {
        #expect(IncognitoPolicy(user: user(chat: ["temporary": true, "temporary_enforced": true])) == .enforced)
        // The Server only enforces when both are set (B/models/chats.py).
        #expect(IncognitoPolicy(user: user(chat: ["temporary": false, "temporary_enforced": true])) == .unavailable)
    }

    @Test func adminsAreNeverForced() {
        let admin = user(.admin, chat: ["temporary": true, "temporary_enforced": true])
        #expect(IncognitoPolicy(user: admin) == .available)
    }

    @Test func pendingAccountsGetNothing() {
        #expect(IncognitoPolicy(user: user(.pending, chat: ["temporary": true])) == .unavailable)
    }

    @Test func enforcedIncognitoLeavesNoProjects() throws {
        let features = try Endpoint.config.decode(Fixture.data("config.json")).features
        let enforced = user(chat: ["temporary": true, "temporary_enforced": true])
        let free = user(chat: ["temporary": true])
        func withFolders(_ user: SessionUser) -> SessionUser {
            var raw = user.permissions.raw
            raw = .object((raw.objectValue ?? [:]).merging(["features": .object(["folders": .bool(true)])]) { $1 })
            return SessionUser(id: user.id, name: user.name, email: user.email, role: user.role, permissions: UserPermissions(raw: raw))
        }
        #expect(Capabilities.resolve(features: features, user: withFolders(free), model: nil).contains(.projects))
        // Every new Chat is Incognito (never saved), so there's nothing to file in a Project.
        #expect(!Capabilities.resolve(features: features, user: withFolders(enforced), model: nil).contains(.projects))
        #expect(Capabilities.resolve(features: features, user: withFolders(enforced), model: nil).contains(.incognitoChat))
    }
}
