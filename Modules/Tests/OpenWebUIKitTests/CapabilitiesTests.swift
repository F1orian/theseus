import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

@Suite("Capabilities (ADR 0006)")
struct CapabilitiesTests {
    let features: ServerFeatures
    let admin: SessionUser
    let model: Model

    init() throws {
        features = try Endpoint.config.decode(Fixture.data("config.json")).features
        admin = try Endpoint.sessionUser.decode(Fixture.data("auths.json"))
        model = try #require(try Endpoint.models.decode(Fixture.data("models.json")).first)
    }

    /// A regular user with the given dotted permissions granted.
    func user(granting permissions: [String]) -> SessionUser {
        var tree: [String: [String: JSONValue]] = [:]
        for permission in permissions {
            let parts = permission.split(separator: ".").map(String.init)
            tree[parts[0], default: [:]][parts[1]] = .bool(true)
        }
        return SessionUser(
            id: "u", name: "U", email: "u@example.com", role: .user,
            permissions: UserPermissions(raw: .object(tree.mapValues { .object($0) }))
        )
    }

    @Test func recordedAdminOnRecordedServer() {
        let capabilities = Capabilities.resolve(features: features, user: admin, model: model)
        #expect(capabilities.contains(.webSearch))
        // The test Server's code interpreter is Pyodide, which needs a browser (CONN-08).
        #expect(!capabilities.contains(.codeInterpreter))
        #expect(capabilities.contains(.connectors))
        #expect(capabilities.contains(.projects))
        #expect(capabilities.contains(.memory))
        #expect(capabilities.contains(.rateResponse))
        #expect(capabilities.contains(.imageInput))
        #expect(capabilities.contains(.sources))
        // Disabled server-wide on the test Server.
        #expect(!capabilities.contains(.imageGeneration))
        #expect(!capabilities.contains(.apiKeys))
    }

    @Test func codeInterpreterNeedsAServerSideEngine() {
        var jupyter = features
        jupyter.codeInterpreterEngine = "jupyter"
        #expect(Capabilities.resolve(features: jupyter, user: admin, model: model).contains(.codeInterpreter))
        var pyodide = features
        pyodide.codeInterpreterEngine = "pyodide"
        #expect(!Capabilities.resolve(features: pyodide, user: admin, model: model).contains(.codeInterpreter))
        // Unknown engine (no `code` in the config): the flags decide.
        var unknown = features
        unknown.codeInterpreterEngine = nil
        #expect(Capabilities.resolve(features: unknown, user: admin, model: model).contains(.codeInterpreter))
    }

    @Test func connectorsNeedToolsOrToolServers() {
        let user = user(granting: [])
        let none = ServerFeatures(raw: ["enable_tools": .bool(false), "enable_tool_servers": .bool(false)])
        #expect(!Capabilities.resolve(features: none, user: user, model: nil).contains(.connectors))
        let serversOnly = ServerFeatures(raw: ["enable_tool_servers": .bool(true)])
        #expect(Capabilities.resolve(features: serversOnly, user: user, model: nil).contains(.connectors))
        let toolsOnly = ServerFeatures(raw: ["enable_tools": .bool(true)])
        #expect(Capabilities.resolve(features: toolsOnly, user: user, model: nil).contains(.connectors))
    }

    @Test func webSearchConfirmationTextOnlyWhenRequired() {
        #expect(features.webSearchConfirmation == nil, "off on the test Server")
        let required = ServerFeatures(raw: [
            "enable_web_search_confirmation": .bool(true),
            "web_search_confirmation_content": .string("Queries go to Brave."),
        ])
        #expect(required.webSearchConfirmation == "Queries go to Brave.")
        let blank = ServerFeatures(raw: ["enable_web_search_confirmation": .bool(true)])
        #expect(blank.webSearchConfirmation?.isEmpty == false)
    }

    @Test func adminsBypassPermissionsButNotServerFlags() {
        let lockedDown = SessionUser(id: "a", name: "A", email: "a@example.com", role: .admin)
        let capabilities = Capabilities.resolve(features: features, user: lockedDown, model: nil)
        #expect(capabilities.contains(.webSearch))
        #expect(capabilities.contains(.deleteChat))
        #expect(!capabilities.contains(.imageGeneration), "server flag off")
    }

    @Test func userNeedsServerFlagAndPermission() {
        let withoutPermission = Capabilities.resolve(features: features, user: user(granting: []), model: model)
        #expect(!withoutPermission.contains(.webSearch))
        #expect(!withoutPermission.contains(.fileUpload))
        #expect(withoutPermission.contains(.sources), "model-only capability")

        let granted = Capabilities.resolve(
            features: features,
            user: user(granting: ["features.web_search", "chat.file_upload", "features.image_generation"]),
            model: model
        )
        #expect(granted.contains(.webSearch))
        #expect(granted.contains(.fileUpload))
        #expect(!granted.contains(.imageGeneration), "server flag off")
    }

    @Test func publicChatLinksNeedShareAndPublicSharing() {
        let shareOnly = Capabilities.resolve(features: features, user: user(granting: ["chat.share"]), model: nil)
        #expect(shareOnly.contains(.shareChat))
        #expect(!shareOnly.contains(.publicChatLink))
        let both = Capabilities.resolve(features: features, user: user(granting: ["chat.share", "sharing.public_chats"]), model: nil)
        #expect(both.contains(.publicChatLink))
        #expect(Capabilities.resolve(features: features, user: admin, model: nil).contains(.publicChatLink))
    }

    @Test func modelCapabilitiesGateAndMissingKeysCountAsSupported() {
        let blind = Model(id: "m", name: "M", capabilities: ModelCapabilities(raw: ["vision": false, "web_search": false]))
        let capabilities = Capabilities.resolve(features: features, user: admin, model: blind)
        #expect(!capabilities.contains(.imageInput))
        #expect(!capabilities.contains(.webSearch))
        #expect(capabilities.contains(.fileUpload), "file_upload key missing → supported")
        #expect(capabilities.contains(.memory), "memory key missing → supported")
    }

    @Test func noModelIgnoresModelRequirements() {
        let blind = Model(id: "m", name: "M", capabilities: ModelCapabilities(raw: ["web_search": false]))
        #expect(!Capabilities.resolve(features: features, user: admin, model: blind).contains(.webSearch))
        #expect(Capabilities.resolve(features: features, user: admin, model: nil).contains(.webSearch))
    }

    @Test func publicConfigEnablesNoServerGatedFeatures() throws {
        let publicFeatures = try Endpoint.config.decode(Fixture.data("config.public.json")).features
        let capabilities = Capabilities.resolve(features: publicFeatures, user: admin, model: model)
        #expect(!capabilities.contains(.webSearch))
        #expect(!capabilities.contains(.projects))
        #expect(capabilities.contains(.editMessage), "permission-only capabilities don't need server flags")
    }

    @Test func pendingUsersGetNothing() {
        let pending = SessionUser(id: "p", name: "P", email: "p@example.com", role: .pending)
        #expect(Capabilities.resolve(features: features, user: pending, model: model).enabled.isEmpty)
    }
}

@Suite("CompletionSession transport selection")
struct CompletionTransportTests {
    @Test(arguments: [
        (CredentialKind.sessionToken, true, CompletionTransport.socket),
        (.sessionToken, false, .serverSentEvents),
        (.apiKey, true, .serverSentEvents),
        (.apiKey, false, .serverSentEvents),
    ])
    func transportSelection(credential: CredentialKind, webSocket: Bool, expected: CompletionTransport) {
        #expect(CompletionSession.selectTransport(credential: credential, serverSupportsWebSocket: webSocket) == expected)
    }
}
