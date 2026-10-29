import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

/// Skills (#187): personal and shared Skills, their request bodies, sharing grants, imports and
/// the permission gates. Recorded fixtures are GET-only (`skills.json`, `skills.list-page.json`,
/// `skill.detail.json`, `users.permissions.json`, `groups.json`); every write is checked against
/// hand-written `synthetic/skill.*` shapes from `B/routers/skills.py` and `B/models/skills.py`.
@Suite("Skill endpoints")
struct SkillEndpointTests {
    private let me = "00000000-0000-4000-8000-000000000001"

    private func request<R>(_ endpoint: Endpoint<R>) -> URLRequest {
        endpoint.urlRequest(server: Fixture.serverURL, token: "jwt")
    }

    private func json(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    }

    // MARK: Reading

    @Test func recordedListCarriesOwnersAndGrants() throws {
        let skills = try Endpoint.skills.decode(Fixture.data("skills.json"))
        #expect(skills.count == 12)
        let first = try #require(skills.first)
        #expect(first.id == "deep-research")
        #expect(first.userID == me)
        #expect(first.owner == SkillOwner(id: me, name: "Test User", email: "user@example.com"))
        #expect(first.accessGrants.isEmpty)
        #expect(first.sharing == .onlyOwner)
        #expect(first.versionID != nil)
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_792_768_702))
        #expect(skills.allSatisfy { SkillScope($0, userID: me, isAdmin: true) == .yours })
    }

    @Test func recordedPageHasWriteAccess() throws {
        #expect(request(.skillList()).url?.absoluteString == "https://owui.example.com/api/v1/skills/list")
        let created = request(.skillList(view: .created, query: "pdf", page: 2))
        #expect(created.url?.absoluteString == "https://owui.example.com/api/v1/skills/list?view_option=created&query=pdf&page=2")
        let page = try Endpoint.skillList().decode(Fixture.data("skills.list-page.json"))
        #expect(page.total == 12)
        #expect(page.items.allSatisfy { $0.writeAccess == true })
    }

    @Test func recordedDetailHasTheInstructions() throws {
        #expect(request(.skill(id: "xlsx")).url?.path() == "/api/v1/skills/id/xlsx")
        let detail = try Endpoint.skill(id: "xlsx").decode(Fixture.data("skill.detail.json"))
        #expect(detail.skill.id == "xlsx")
        #expect(detail.skill.writeAccess == true)
        #expect(detail.content.hasPrefix("---\nname: xlsx\n"))
        #expect(SkillMarkdown.frontMatter(detail.content) == ["name": "xlsx", "description": "What the xlsx skill does."])
    }

    @Test func oldShapesStillDecode() throws {
        // The stream fixture predates owners and grants.
        let skills = try Endpoint.skills.decode(Fixture.data("stream/skills.list.json"))
        #expect(!skills.isEmpty)
        #expect(skills.allSatisfy { $0.userID == nil && $0.accessGrants.isEmpty && $0.owner == nil })
    }

    @Test func scopesSplitYoursSharedAndOthersPrivate() throws {
        let skills = try Endpoint.skills.decode(Fixture.data("synthetic/skills.mixed.json"))
        let asAdmin = skills.map { SkillScope($0, userID: me, isAdmin: true) }
        #expect(asAdmin == [.yours, .yours, .shared, .shared, .othersPrivate, .shared])
        let asUser = skills.map { SkillScope($0, userID: me, isAdmin: false) }
        #expect(asUser == [.yours, .yours, .shared, .shared, .shared, .shared])
        #expect(skills.map(\.sharing) == [.onlyOwner, .everyone, .everyone, .groups(["group-legal"]), .onlyOwner, .people])
        #expect(skills[1].isActive == false)
    }

    @Test func groupsDecode() throws {
        #expect(request(.sharingGroups).url?.path() == "/api/v1/groups/")
        #expect(try Endpoint.sharingGroups.decode(Fixture.data("groups.json")).isEmpty, "the test Server has no groups")
        let groups = try Endpoint.sharingGroups.decode(Fixture.data("synthetic/groups.json"))
        #expect(groups.map(\.name) == ["Legal", "Design"])
    }

    // MARK: Writing

    @Test func createSendsTheSkillForm() throws {
        let draft = SkillDraft(name: "Meeting notes", description: "Turns notes into minutes.", content: "# Minutes\n\nSummarise.")
        #expect(draft.id == "meeting-notes")
        let create = request(.createSkill(draft))
        #expect(create.httpMethod == "POST")
        #expect(create.url?.path() == "/api/v1/skills/create")
        #expect(create.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try json(create) == .object([
            "id": .string("meeting-notes"),
            "name": .string("Meeting notes"),
            "description": .string("Turns notes into minutes."),
            "content": .string("# Minutes\n\nSummarise."),
            "is_active": .bool(true),
            "access_grants": .array([]),
        ]))
        let created = try Endpoint.createSkill(draft).decode(Fixture.data("synthetic/skill.create.json"))
        #expect(created.id == "meeting-notes" && created.userID == me && created.owner == nil)
    }

    @Test func aSharedSkillIsCreatedWithItsGrants() throws {
        let draft = SkillDraft(name: "Brand voice", content: "Write like us.", accessGrants: SkillSharing.everyone.grants())
        #expect(try json(request(.createSkill(draft)))[path: "access_grants"] == .array([.object([
            "principal_type": .string("user"), "principal_id": .string("*"), "permission": .string("read"),
        ])]))
    }

    @Test func updateKeepsGrantsUnlessGiven() throws {
        var draft = SkillDraft(id: "ignored", name: "Meeting notes", content: "New", isActive: false)
        draft.accessGrants = nil
        let update = request(.updateSkill(id: "meeting-notes", draft))
        #expect(update.httpMethod == "POST")
        #expect(update.url?.path() == "/api/v1/skills/id/meeting-notes/update")
        let body = try json(update)
        #expect(body[path: "id"] == .string("meeting-notes"), "the path's id wins")
        #expect(body[path: "access_grants"] == nil, "omitted, so the server keeps the grants (exclude_unset)")
        #expect(body[path: "is_active"] == .bool(false))
        #expect(body[path: "content"] == .string("New"))
    }

    @Test func toggleAndDelete() throws {
        let toggle = request(.toggleSkill(id: "meeting-notes"))
        #expect(toggle.httpMethod == "POST" && toggle.httpBody == nil)
        #expect(toggle.url?.path() == "/api/v1/skills/id/meeting-notes/toggle")
        #expect(try Endpoint.toggleSkill(id: "x").decode(Fixture.data("synthetic/skill.toggle.json")).isActive == false)

        let delete = request(.deleteSkill(id: "meeting-notes"))
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path() == "/api/v1/skills/id/meeting-notes/delete")
        #expect(try Endpoint.deleteSkill(id: "x").decode(Fixture.data("synthetic/skill.delete.json")))
    }

    @Test func accessUpdateReplacesTheGrants() throws {
        let everyone = request(.updateSkillAccess(id: "meeting-notes", grants: SkillSharing.everyone.grants()))
        #expect(everyone.url?.path() == "/api/v1/skills/id/meeting-notes/access/update")
        #expect(try json(everyone) == .object(["access_grants": .array([.object([
            "principal_type": .string("user"), "principal_id": .string("*"), "permission": .string("read"),
        ])])]))
        let none = request(.updateSkillAccess(id: "meeting-notes", grants: SkillSharing.onlyOwner.grants()))
        #expect(try json(none) == .object(["access_grants": .array([])]))
        let updated = try Endpoint.updateSkillAccess(id: "x", grants: []).decode(Fixture.data("synthetic/skill.access-update.json"))
        #expect(updated.sharing == .everyone)
    }

    @Test func sharingKeepsPeopleAndGroupWrites() {
        let existing: [SkillAccessGrant] = [
            SkillAccessGrant(principalType: "user", principalID: "u2", permission: "write"),
            .group("legal"), .group("legal", permission: "write"), .group("design"), .everyone,
        ]
        #expect(SkillSharing(grants: existing) == .everyone)
        #expect(SkillSharing.groups(["legal"]).grants(keeping: existing) == [
            SkillAccessGrant(principalType: "user", principalID: "u2", permission: "write"),
            .group("legal"), .group("legal", permission: "write"),
        ])
        #expect(SkillSharing.everyone.grants(keeping: existing) == [
            SkillAccessGrant(principalType: "user", principalID: "u2", permission: "write"), .everyone,
        ])
        #expect(SkillSharing.onlyOwner.grants(keeping: existing).isEmpty)
        #expect(SkillSharing(grants: [.group("a"), .group("a", permission: "write")]) == .groups(["a"]))
    }

    @Test func slugsMatchTheServersCharset() {
        #expect(SkillDraft.slug(for: "Meeting notes") == "meeting-notes")
        #expect(SkillDraft.slug(for: "  Résumé / CV  ") == "resume-cv")
        #expect(SkillDraft.slug(for: "snake_case OK") == "snake_case-ok")
        #expect(SkillDraft.slug(for: "🙂") == "skill")
    }

    // MARK: Import

    @Test func loadFromURLIsAdminOnlyAndReturnsPackages() throws {
        let url = try #require(URL(string: "https://github.com/acme/skills/tree/main/pdf-tools"))
        let load = request(.loadSkills(fromURL: url))
        #expect(load.httpMethod == "POST")
        #expect(load.url?.path() == "/api/v1/skills/load/url")
        #expect(try json(load) == .object(["url": .string("https://github.com/acme/skills/tree/main/pdf-tools")]))
        let packages = try Endpoint.loadSkills(fromURL: url).decode(Fixture.data("synthetic/skill.load-url.json"))
        #expect(packages.map(\.id) == ["pdf-tools"])
        #expect(packages.first?.description == "Fill and split PDF files.")

        // The packages go back to the import routes as one skills.json, unchanged.
        let file = SkillImportFile.packages(packages)
        #expect(file.filename == "skills.json" && file.contentType == "application/json")
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: file.data)
        #expect(roundTrip == .array(packages.map(\.raw)))
    }

    @Test func previewUploadsFilesAsMultipart() throws {
        let file = SkillImportFile(filename: "pdf\"tools.skill", contentType: "application/zip", data: Data("PK\u{3}\u{4}".utf8))
        let preview = request(.previewSkillImport([file]))
        #expect(preview.url?.path() == "/api/v1/skills/import/preview")
        let contentType = try #require(preview.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=theseus-"))
        let body = String(decoding: try #require(preview.httpBody), as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"files\"; filename=\"pdftools.skill\"\r\n"))
        #expect(body.contains("Content-Type: application/zip\r\n\r\nPK"))
        #expect(!body.contains("name=\"decisions\""))

        let items = try Endpoint.previewSkillImport([]).decode(Fixture.data("synthetic/skill.import-preview.json"))
        #expect(items.map(\.id) == ["pdf-tools", "meeting-notes"])
        #expect(items[0].fileCount == 2 && !items[0].isTaken)
        #expect(items[0].defaultDecision == SkillImportDecision(action: .create, id: "pdf-tools", name: "pdf-tools"))
        #expect(items[1].description == nil)
        #expect(items[1].isTaken && items[1].canReplace)
        #expect(items[1].defaultDecision == SkillImportDecision(action: .copy, id: "meeting-notes-copy", name: "Meeting notes (copy)"))
        #expect(SkillImportDecision.replace(items[1]).expectedVersionID == "meeting-notes-v1")
    }

    @Test func importSendsOneDecisionPerSkill() throws {
        let file = SkillImportFile(filename: "SKILL.md", contentType: "text/markdown", data: Data("# Hi".utf8))
        let decisions = [
            SkillImportDecision(action: .create, id: "pdf-tools", name: "pdf-tools"),
            SkillImportDecision(action: .replace, id: "meeting-notes", name: "Meeting notes", expectedVersionID: "v1"),
        ]
        let send = request(.importSkills([file], decisions: decisions))
        #expect(send.url?.path() == "/api/v1/skills/import")
        let body = String(decoding: try #require(send.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"files\"; filename=\"SKILL.md\""))
        let decisionsPart = try #require(body.components(separatedBy: "name=\"decisions\"\r\n\r\n").last?.components(separatedBy: "\r\n").first)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(decisionsPart.utf8)) == .array([
            .object(["action": .string("create"), "id": .string("pdf-tools"), "name": .string("pdf-tools")]),
            .object(["action": .string("replace"), "id": .string("meeting-notes"), "name": .string("Meeting notes"), "expected_version_id": .string("v1")]),
        ]))

        let results = try Endpoint.importSkills([], decisions: []).decode(Fixture.data("synthetic/skill.import.json"))
        #expect(results.map(\.status) == [.saved, .error, .error, .skipped])
        #expect(results[1].error == "A skill with this name already exists")
        #expect(results[2].error == "version_conflict")
    }

    // MARK: Permissions

    @Test func recordedDefaultsAllowNothing() throws {
        // The test Server's defaults (GET /api/v1/users/permissions): workspace.skills is off.
        let raw = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("users.permissions.json"))
        let user = SessionUser(id: "u", name: "U", email: "u@example.com", role: .user, permissions: UserPermissions(raw: raw))
        let permissions = SkillPermissions(user: user)
        #expect(!permissions.canCreate && !permissions.canImportFiles && !permissions.canLoadFromURLOnServer)
        #expect(!permissions.canShareWithEveryone)
        #expect(permissions.canShareWithGroups, "access_grants.allow_groups is on by default")

        let admin = SkillPermissions(user: SessionUser(id: "a", name: "A", email: "a@example.com", role: .admin, permissions: UserPermissions(raw: raw)))
        #expect(admin.canCreate && admin.canImportFiles && admin.canLoadFromURLOnServer && admin.canShareWithEveryone)
    }

    @Test func createOrImportPermissionUnlocksCreating() {
        func permissions(_ workspace: [String: JSONValue]) -> SkillPermissions {
            SkillPermissions(user: SessionUser(id: "u", name: "U", email: "u@example.com", role: .user,
                                               permissions: UserPermissions(raw: .object(["workspace": .object(workspace)]))))
        }
        let creator = permissions(["skills": .bool(true)])
        #expect(creator.canCreate && !creator.canImportFiles)
        let importer = permissions(["skills_import": .bool(true)])
        #expect(importer.canCreate && importer.canImportFiles, "the create route also accepts skills_import")
        #expect(SkillPermissions.none.canCreate == false)
    }

    @Test func editingNeedsOwnershipOrWriteAccess() throws {
        let skills = try Endpoint.skills.decode(Fixture.data("synthetic/skills.mixed.json"))
        let user = SkillPermissions(user: SessionUser(id: me, name: "U", email: "u@example.com", role: .user))
        #expect(skills.map { user.canEdit($0, userID: me) } == [true, true, false, false, false, true])
    }

    @Test func frontMatterReadsFlatKeys() {
        let content = "---\nname: \"pdf-tools\"\ndescription: Fill PDFs: fast.\nmetadata:\n  version: 2\n---\n# Body"
        #expect(SkillMarkdown.frontMatter(content) == ["name": "pdf-tools", "description": "Fill PDFs: fast."])
        #expect(SkillMarkdown.frontMatter("# No header").isEmpty)
        #expect(SkillMarkdown.frontMatter("---\nname: open").isEmpty, "an unclosed block isn't front matter")
        #expect(SkillMarkdown.displayName("pdf-tools") == "Pdf tools")
        #expect(SkillMarkdown.displayName("PDF Tools") == "PDF Tools")
    }
}
