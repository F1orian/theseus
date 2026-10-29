import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import Testing

/// Settings › Skills and Server administration › Skills (#187) against stubbed routes.
@MainActor
@Suite("Skills settings")
struct SkillsModelTests {
    private static let me = "00000000-0000-4000-8000-000000000001"

    private func sessionUser(role: String = "user", workspace: [String: Bool] = [:], sharing: [String: Bool] = [:]) -> Data {
        let user: [String: Any] = [
            "id": Self.me, "name": "Test User", "email": "user@example.com", "role": role,
            "permissions": ["workspace": workspace, "sharing": sharing, "access_grants": ["allow_groups": true]],
        ]
        return (try? JSONSerialization.data(withJSONObject: user)) ?? Data()
    }

    private func body(_ request: URLRequest?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request?.httpBody))
    }

    private func makeModel(
        _ transport: StubTransport,
        mode: SkillsModel.Mode = .personal,
        role: String = "user",
        workspace: [String: Bool] = [:],
        download: (@Sendable (URL) async throws -> (Data, String?))? = nil
    ) throws -> SkillsModel {
        transport.stub("GET", "api/v1/auths/", body: sessionUser(role: role, workspace: workspace))
        try transport.stub("GET", "api/v1/skills/", fixture: "synthetic/skills.mixed.json")
        try transport.stub("GET", "api/v1/groups/", fixture: "synthetic/groups.json")
        try transport.stub("GET", "api/v1/users/default/permissions", fixture: "users.default-permissions.json")
        return SkillsModel(mode: mode, client: makeClient(transport), host: "chat.example.com", download: download)
    }

    private func requests(_ transport: StubTransport, _ method: String, _ path: String) -> [URLRequest] {
        transport.requests.filter { $0.httpMethod == method && $0.url?.path() == path }
    }

    // MARK: Yours and shared

    @Test func withoutPermissionYouSeeSharedSkillsAndAnExplanation() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport)
        await model.load()
        #expect(model.yours.map(\.id) == ["meeting-notes", "tone-check"])
        #expect(model.shared.map(\.id) == ["brand-voice", "drafts", "legal-review", "pair-review"])
        #expect(model.showsNoPermission)
        #expect(!model.showsUserPermissionsHint, "only admins get the hint")
        #expect(model.sharingText(model.yours[0]) == "Only you")
        #expect(model.sharingText(model.yours[1]) == "Everyone on chat.example.com")
        #expect(model.sharingText(model.shared[2]) == "Legal", "group names come from GET /groups/")
        #expect(model.ownerName(model.shared[0]) == "Ada Admin")
        model.startCreating()
        #expect(model.editor == nil, "no editor without permission")
        #expect(requests(transport, "GET", "/api/v1/users/default/permissions").isEmpty)
    }

    @Test func creatingAPrivateSkill() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills": true])
        try transport.stub("POST", "api/v1/skills/create", fixture: "synthetic/skill.create.json")
        await model.load()
        #expect(!model.showsNoPermission)
        model.startCreating()
        #expect(model.editor?.sharing == .onlyOwner)
        model.editor?.name = "  Meeting notes "
        #expect(model.editor?.canSave == false, "needs instructions")
        model.editor?.content = "Summarise the meeting."
        #expect(await model.saveEditor())
        #expect(model.editor == nil)
        let sent = try body(requests(transport, "POST", "/api/v1/skills/create").first)
        #expect(sent[path: "name"] == .string("Meeting notes"))
        #expect(sent[path: "id"] == .string("meeting-notes-2"), "meeting-notes is taken")
        #expect(sent[path: "access_grants"] == .array([]), "personal Skills are private")
    }

    @Test func editingKeepsTheGrants() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills": true])
        transport.stub("GET", "api/v1/skills/id/tone-check", body: Data(#"""
            {"id":"tone-check","user_id":"00000000-0000-4000-8000-000000000001","name":"Tone check","description":"","meta":{},
             "is_active":false,"access_grants":[{"principal_type":"user","principal_id":"*","permission":"read"}],
             "updated_at":1,"created_at":1,"write_access":true,"content":"Check the tone."}
            """#.utf8))
        try transport.stub("POST", "api/v1/skills/id/tone-check/update", fixture: "synthetic/skill.toggle.json")
        await model.load()
        await model.open(try #require(model.yours.last))
        let editor = try #require(model.editor)
        #expect(editor.existingID == "tone-check" && editor.content == "Check the tone." && !editor.isActive)
        model.editor?.content = "Check the tone. Be kind."
        #expect(await model.saveEditor())
        let sent = try body(requests(transport, "POST", "/api/v1/skills/id/tone-check/update").first)
        #expect(sent[path: "access_grants"] == nil)
        #expect(sent[path: "content"] == .string("Check the tone. Be kind."))
        #expect(sent[path: "is_active"] == .bool(false))
    }

    @Test func aSharedSkillOpensReadOnly() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport)
        transport.stub("GET", "api/v1/skills/id/brand-voice", body: Data(#"""
            {"id":"brand-voice","user_id":"00000000-0000-4000-8000-000000000002","name":"Brand voice","meta":{},
             "access_grants":[],"updated_at":1,"created_at":1,"write_access":false,"content":"Write like us."}
            """#.utf8))
        await model.load()
        await model.open(try #require(model.shared.first))
        #expect(model.editor == nil)
        #expect(model.viewing?.content == "Write like us.")
    }

    @Test func togglingAndDeleting() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills": true])
        try transport.stub("POST", "api/v1/skills/id/meeting-notes/toggle", fixture: "synthetic/skill.toggle.json")
        try transport.stub("DELETE", "api/v1/skills/id/meeting-notes/delete", fixture: "synthetic/skill.delete.json")
        await model.load()
        let notes = try #require(model.yours.first)
        await model.setEnabled(notes, true)
        #expect(requests(transport, "POST", "/api/v1/skills/id/meeting-notes/toggle").isEmpty, "already on")
        await model.setEnabled(notes, false)
        #expect(model.yours.first?.isActive == false)
        #expect(model.yours.first?.owner?.name == "Test User", "the owner survives the write response")
        // Shared Skills can't be toggled by a user.
        await model.setEnabled(try #require(model.shared.first), false)
        #expect(requests(transport, "POST", "/api/v1/skills/id/brand-voice/toggle").isEmpty)
        await model.delete(notes)
        #expect(!model.yours.contains { $0.id == "meeting-notes" })
    }

    @Test func permissionErrorsReadPlainly() {
        #expect(SkillsModel.message(for: .unauthorized(detail: "401 Unauthorized")) == "Your Server admin hasn't allowed this.")
        #expect(SkillsModel.message(for: .server(status: 409, detail: "A skill with this name already exists")) == "A skill with this name already exists")
    }

    // MARK: Administration

    @Test func adminsSeeEverySkillAndChangeSharing() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, mode: .administration, role: "admin")
        try transport.stub("POST", "api/v1/skills/id/drafts/access/update", fixture: "synthetic/skill.access-update.json")
        await model.load()
        #expect(model.all.count == 6)
        #expect(model.shared.map(\.id) == ["brand-voice", "legal-review", "pair-review"], "others' private ones aren't 'shared'")
        #expect(model.groups.map(\.name) == ["Legal", "Design"])
        #expect(model.showsUserPermissionsHint, "users can't create Skills on the recorded Server")
        let drafts = try #require(model.all.first { $0.id == "drafts" })
        #expect(model.sharingText(drafts) == "Only Ada Admin")
        await model.setSharing(drafts, .everyone)
        let sent = try body(requests(transport, "POST", "/api/v1/skills/id/drafts/access/update").first)
        #expect(sent == .object(["access_grants": .array([.object([
            "principal_type": .string("user"), "principal_id": .string("*"), "permission": .string("read"),
        ])])]))
    }

    @Test func adminsCreateSharedSkills() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, mode: .administration, role: "admin")
        try transport.stub("POST", "api/v1/skills/create", fixture: "synthetic/skill.access-update.json")
        await model.load()
        model.startCreating()
        #expect(model.editor?.sharing == .everyone)
        model.editor?.name = "House style"
        model.editor?.content = "Use sentence case."
        model.editor?.sharing = .groups(["group-legal"])
        #expect(await model.saveEditor())
        let sent = try body(requests(transport, "POST", "/api/v1/skills/create").first)
        #expect(sent[path: "access_grants"] == .array([.object([
            "principal_type": .string("group"), "principal_id": .string("group-legal"), "permission": .string("read"),
        ])]))
    }

    // MARK: Import

    @Test func adminsLoadLinksOnTheServerThenReview() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, role: "admin")
        try transport.stub("POST", "api/v1/skills/load/url", fixture: "synthetic/skill.load-url.json")
        try transport.stub("POST", "api/v1/skills/import/preview", fixture: "synthetic/skill.import-preview.json")
        try transport.stub("POST", "api/v1/skills/import", fixture: "synthetic/skill.import.json")
        await model.load()
        #expect(await model.addFromURL("github.com/acme/skills/tree/main/pdf-tools"))
        let load = try body(requests(transport, "POST", "/api/v1/skills/load/url").first)
        #expect(load == .object(["url": .string("https://github.com/acme/skills/tree/main/pdf-tools")]))
        let preview = try #require(requests(transport, "POST", "/api/v1/skills/import/preview").first)
        #expect(String(decoding: preview.httpBody ?? Data(), as: UTF8.self).contains("filename=\"skills.json\""))

        var session = try #require(model.importSession)
        #expect(session.source == "github.com")
        #expect(session.decisions.map(\.action) == [.create, .copy])
        #expect(session.actions(for: 1) == [.copy, .replace, .skip])
        session.choose(.skip, for: 1)
        model.importSession = session
        #expect(session.selectedCount == 1)
        _ = await model.confirmImport()
        let sent = String(decoding: try #require(requests(transport, "POST", "/api/v1/skills/import").first?.httpBody), as: UTF8.self)
        #expect(sent.contains(#"[{"action":"create","id":"pdf-tools","name":"pdf-tools"},{"action":"skip","id":"meeting-notes","name":"Meeting notes"}]"#))
        // The fixture reports one error, so the sheet stays with the results.
        #expect(model.importSession?.results?.count == 4)
        #expect(model.errorMessage == "A skill with this name already exists")
    }

    @Test func usersDownloadOnTheDevice() async throws {
        let transport = StubTransport()
        let fetched = URLBox()
        let model = try makeModel(transport, workspace: ["skills": true]) { url in
            await fetched.set(url)
            return (Data("---\nname: pdf-tools\ndescription: Fill PDFs.\n---\n\n# PDF tools".utf8), "text/plain")
        }
        await model.load()
        #expect(await model.addFromURL("https://github.com/acme/skills/blob/main/pdf-tools/SKILL.md"))
        #expect(await fetched.url?.absoluteString == "https://raw.githubusercontent.com/acme/skills/main/pdf-tools/SKILL.md")
        #expect(requests(transport, "POST", "/api/v1/skills/load/url").isEmpty, "load/url is admin-only")
        // Without import permission the SKILL.md opens in the editor to review.
        let editor = try #require(model.editor)
        #expect(editor.isNew && editor.name == "Pdf tools" && editor.description == "Fill PDFs.")
        #expect(editor.content.hasSuffix("# PDF tools"))

        #expect(await model.addFromURL("https://github.com/acme/skills/tree/main/pdf-tools") == false)
        #expect(model.errorMessage?.contains("Only Server admins") == true)
    }

    @Test func importersSendDownloadsThroughThePreview() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills_import": true]) { _ in
            (Data("PK\u{3}\u{4}zip".utf8), "application/octet-stream")
        }
        try transport.stub("POST", "api/v1/skills/import/preview", fixture: "synthetic/skill.import-preview.json")
        await model.load()
        #expect(await model.addFromURL("https://example.com/downloads/pdf-tools.skill"))
        let preview = String(decoding: try #require(requests(transport, "POST", "/api/v1/skills/import/preview").first?.httpBody), as: UTF8.self)
        #expect(preview.contains("filename=\"pdf-tools.skill\"\r\nContent-Type: application/zip"))
        #expect(model.importSession?.items.count == 2)
    }

    @Test func webPagesAreRefused() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills_import": true]) { _ in (Data("<html>".utf8), "text/html") }
        await model.load()
        #expect(await model.addFromURL("https://example.com/skill") == false)
        #expect(model.errorMessage?.contains("web page") == true)
        #expect(await model.addFromURL("not a link") == false)
    }

    @Test func filesNeedImportPermissionUnlessMarkdown() async throws {
        let transport = StubTransport()
        let model = try makeModel(transport, workspace: ["skills": true])
        await model.load()
        let archive = SkillImportFile(filename: "pdf.skill", contentType: "application/zip", data: Data("PK".utf8))
        #expect(await model.addFromFile(archive) == false)
        #expect(model.errorMessage?.contains("importing skill files") == true)
        let markdown = SkillImportFile(filename: "Tone.md", contentType: "text/markdown", data: Data("Be kind.".utf8))
        #expect(await model.addFromFile(markdown))
        #expect(model.editor?.name == "Tone" && model.editor?.content == "Be kind.")
    }

    @Test func linksAreNormalised() throws {
        #expect(SkillLink.url(from: " example.com/SKILL.md ")?.absoluteString == "https://example.com/SKILL.md")
        #expect(SkillLink.url(from: "ftp://example.com/a") == nil)
        #expect(SkillLink.url(from: "https://user:pw@example.com/a") == nil)
        let raw = try #require(URL(string: "https://github.com/acme/skills/raw/main/SKILL.md"))
        #expect(SkillLink.downloadURL(for: raw) == raw)
        let repo = try #require(URL(string: "https://github.com/acme/skills"))
        #expect(SkillLink.downloadURL(for: repo) == nil)
        let other = try #require(URL(string: "https://example.com/x.zip"))
        #expect(SkillLink.downloadURL(for: other) == other)
        #expect(SkillLink.importFile(data: Data("{}".utf8), mimeType: "application/json", url: other).filename == "skills.json")
        #expect(SkillLink.importFile(data: Data("# Hi".utf8), mimeType: "text/markdown", url: other).filename == "SKILL.md")
    }
}

/// Collects the URL a download closure was called with.
private actor URLBox {
    var url: URL?
    func set(_ url: URL) { self.url = url }
}
