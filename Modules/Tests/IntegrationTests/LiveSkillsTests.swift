import Auth
import Foundation
import OpenWebUIKit
import Testing

/// #187 against the test Server, with writes (the owner allowed them for #186/#187 on
/// 2026-10-25): every Skill made here is named `[theseus-test] …` and deleted again, and the
/// Skill list ends as it started. The Account is an admin, so the permission gates don't apply;
/// sharing goes to everyone and straight back to private.
@Suite(
    "Live Skills (opt-in: THESEUS_INTEGRATION=1 + .env; writes [theseus-test] Skills and deletes them)",
    .enabled(if: LiveServer.isConfigured, "Set THESEUS_INTEGRATION=1 and fill in .env to run"),
    .serialized
)
@MainActor
struct LiveSkillsTests {
    @Test func aSkillsLifeOnTheServer() async throws {
        let settings = try #require(LiveServer.settings)
        let transport = URLSessionTransport()
        let server = ServerProfile(url: settings.url, name: "Live")
        guard case .signedIn(let signedIn) = try await PasswordSignIn(server: server, transport: transport)
            .signIn(email: settings.email, password: settings.password)
        else {
            Issue.record("sign-in failed")
            return
        }
        let authenticator = SessionAuthenticator(token: signedIn.token) { throw OpenWebUIError.unauthorized(detail: nil) }
        let client = OpenWebUIClient(server: settings.url, transport: transport, authorizer: authenticator)

        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let skillID = "theseus-test-skill-187-\(suffix)"
        let importID = "theseus-test-import-187-\(suffix)"
        let before = Set(try await client.send(.skills).map(\.id))

        do {
            try await lifecycle(client: client, skillID: skillID, importID: importID, suffix: suffix)
        } catch {
            Issue.record("lifecycle failed: \(error)")
        }

        // Cleanup, even after a failure.
        _ = try? await client.send(.deleteSkill(id: skillID))
        _ = try? await client.send(.deleteSkill(id: importID))
        let after = Set(try await client.send(.skills).map(\.id))
        #expect(after == before, "every [theseus-test] Skill is gone again")
        _ = try? await client.send(.signOut)
    }

    private func lifecycle(client: OpenWebUIClient, skillID: String, importID: String, suffix: String) async throws {
        // Create (private).
        let draft = SkillDraft(
            id: skillID,
            name: "[theseus-test] Skill 187 \(suffix)",
            description: "Created by LiveSkillsTests; deleted at the end.",
            content: "# Test\n\nReply with the word test."
        )
        let created = try await client.send(.createSkill(draft))
        #expect(created.id == skillID)
        #expect(created.accessGrants.isEmpty && created.sharing == .onlyOwner)
        #expect(created.isActive)

        // Detail and update (grants stay).
        var detail = try await client.send(.skill(id: skillID))
        #expect(detail.content == draft.content)
        #expect(detail.skill.writeAccess == true)
        var edit = draft
        edit.content = "# Test\n\nReply with the word tested."
        edit.accessGrants = nil
        let updated = try await client.send(.updateSkill(id: skillID, edit))
        #expect(updated.accessGrants.isEmpty)
        detail = try await client.send(.skill(id: skillID))
        #expect(detail.content == edit.content)

        // Toggle off and on.
        #expect(try await client.send(.toggleSkill(id: skillID)).isActive == false)
        #expect(try await client.send(.toggleSkill(id: skillID)).isActive == true)

        // Share with everyone, then back to private.
        let shared = try await client.send(.updateSkillAccess(id: skillID, grants: SkillSharing.everyone.grants()))
        #expect(shared.sharing == .everyone)
        let listed = try await client.send(.skills).first { $0.id == skillID }
        #expect(listed?.sharing == .everyone)
        #expect(listed?.owner != nil, "the list joins the owner in")
        let unshared = try await client.send(.updateSkillAccess(id: skillID, grants: []))
        #expect(unshared.sharing == .onlyOwner)

        // Import a SKILL.md: preview, then create under a [theseus-test] id and name.
        let markdown = "---\nname: theseus-test-import\ndescription: Imported by LiveSkillsTests.\n---\n\n# Import\n\nSay hi.\n"
        let file = SkillImportFile(filename: "SKILL.md", contentType: "text/markdown", data: Data(markdown.utf8))
        let preview = try await client.send(.previewSkillImport([file]))
        #expect(preview.count == 1)
        #expect(preview.first?.description == "Imported by LiveSkillsTests.")
        let decision = SkillImportDecision(action: .create, id: importID, name: "[theseus-test] Import 187 \(suffix)")
        let results = try await client.send(.importSkills([file], decisions: [decision]))
        #expect(results.map(\.status) == [.saved])
        #expect(results.first?.id == importID)
        let imported = try await client.send(.skill(id: importID))
        #expect(imported.content == markdown)
        #expect(imported.skill.accessGrants.isEmpty, "imports are private")

        // Delete both.
        #expect(try await client.send(.deleteSkill(id: importID)))
        #expect(try await client.send(.deleteSkill(id: skillID)))

        // Read-only: the users' default permissions (admin GET).
        let defaults = try await client.send(.skillUserDefaults)
        #expect(defaults.usersCanCreate == false, "workspace.skills is off for users on the test Server")
    }
}
