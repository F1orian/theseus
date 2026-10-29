import Fixtures
import Foundation
import OpenWebUIKit
@testable import SettingsFeature
import Synchronization
import Testing

/// A fake user-settings endpoint that stores what was written, like the server's top-level merge.
final class UserSettingsServer: Sendable {
    let stored: Mutex<[String: JSONValue]>

    init(_ initial: [String: JSONValue] = ["ui": .object(["memory": .bool(true)])]) {
        stored = Mutex(initial)
    }

    func install(on transport: StubTransport, failWrites: Bool = false) {
        transport.stub("GET", "api/v1/users/user/settings") { [self] _ in
            (200, (try? JSONEncoder().encode(JSONValue.object(stored.withLock { $0 }))) ?? Data())
        }
        transport.stub("POST", "api/v1/users/user/settings/update") { [self] request in
            guard !failWrites else { return (500, Data(#"{"detail":"Server error"}"#.utf8)) }
            let patch = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))?.objectValue ?? [:]
            let merged = stored.withLock { state in
                state.merge(patch) { _, new in new }
                return state
            }
            return (200, (try? JSONEncoder().encode(JSONValue.object(merged))) ?? Data())
        }
    }

    var capabilities: JSONValue? {
        stored.withLock { $0["theseus"]?[path: "capabilities"] }
    }
}

@MainActor
@Suite("Capabilities page (SET-05)")
struct CapabilitiesSettingsTests {
    let transport = StubTransport()

    func makeModel(_ enabled: Capabilities) -> CapabilitiesSettingsModel {
        CapabilitiesSettingsModel(client: makeClient(transport), capabilities: enabled)
    }

    @Test func onlyRowsTheServerAndPermissionsAllowAreShown() {
        let model = makeModel(capabilities(.webSearch, .codeInterpreter))
        #expect(model.rows == [.artifacts, .codeInterpreter, .webSearch])
        #expect(!model.showsMemory)

        let everything = makeModel(capabilities(.webSearch, .codeInterpreter, .imageGeneration, .memory))
        #expect(everything.rows == [.artifacts, .codeInterpreter, .webSearch, .imageGeneration])
        #expect(everything.showsMemory)
    }

    @Test func theSandboxReplacesTheCodeInterpreterRowAndStartsOn() async throws {
        // ADR 0120: one code execution row, backed by the sandbox when the Server has one.
        let model = makeModel(capabilities(.webSearch, .codeInterpreter, .sandbox))
        #expect(model.rows == [.artifacts, .sandbox, .webSearch])
        let server = UserSettingsServer(
            ["theseus": .object(["capabilities": .object(["webSearch": .bool(true), "codeInterpreter": .bool(false)])])]
        )
        server.install(on: transport)
        await model.load()
        #expect(model.isOn(.sandbox), "older saved defaults don't turn the sandbox off")
        await model.set(.sandbox, on: false)
        #expect(server.capabilities?[path: "sandbox"] == .bool(false))
        #expect(server.capabilities?[path: "webSearch"] == .bool(true))
    }

    @Test func defaultsComeFromTheUserSettings() async throws {
        let server = UserSettingsServer(["theseus": .object(["capabilities": .object(["webSearch": .bool(true)])])])
        server.install(on: transport)
        let model = makeModel(capabilities(.webSearch))
        await model.load()
        #expect(model.isOn(.webSearch))
        #expect(model.isOn(.artifacts))
        #expect(!model.isOn(.codeInterpreter))
    }

    @Test func accountsWithoutSettingsGetTheDefaults() async throws {
        try transport.stub("GET", "api/v1/users/user/settings", fixture: "user-settings.json")
        let model = makeModel(capabilities(.webSearch))
        await model.load()
        #expect(model.defaults == CapabilityDefaults())
        #expect(model.errorMessage == nil)
    }

    @Test func switchingWritesTheTheseusNamespaceAndKeepsOtherSettings() async throws {
        let server = UserSettingsServer()
        server.install(on: transport)
        let model = makeModel(capabilities(.webSearch, .codeInterpreter))
        await model.load()

        await model.set(.webSearch, on: true)
        await model.set(.codeInterpreter, on: true)

        #expect(model.isOn(.webSearch) && model.isOn(.codeInterpreter))
        #expect(server.capabilities?[path: "webSearch"] == .bool(true))
        #expect(server.capabilities?[path: "codeInterpreter"] == .bool(true), "the second write saw the first")
        #expect(server.stored.withLock { $0["ui"] } == .object(["memory": .bool(true)]), "web client settings untouched")
    }

    @Test func aFailedWriteRevertsTheSwitch() async throws {
        let server = UserSettingsServer()
        server.install(on: transport, failWrites: true)
        let model = makeModel(capabilities(.webSearch))
        await model.load()

        await model.set(.webSearch, on: true)

        #expect(!model.isOn(.webSearch))
        #expect(model.errorMessage != nil)
    }
}
