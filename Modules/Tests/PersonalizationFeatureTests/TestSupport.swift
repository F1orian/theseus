import Fixtures
import Foundation
import OpenWebUIKit
import Synchronization

/// Static token so `.required` endpoints are sent.
struct StaticAuthorizer: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { throw OpenWebUIError.unauthorized(detail: nil) }
}

func makeClient(_ transport: StubTransport) -> OpenWebUIClient {
    OpenWebUIClient(server: Fixture.serverURL, transport: transport, authorizer: StaticAuthorizer())
}

func capabilities(_ enabled: Capability...) -> Capabilities {
    Capabilities(enabled: Set(enabled))
}

private func json(_ value: JSONValue) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data()
}

@Sendable private func body(_ request: URLRequest) -> [String: JSONValue] {
    (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))?.objectValue ?? [:]
}

private let serverError = Data(#"{"detail":"Server error"}"#.utf8)

/// A fake Open WebUI for the personalization endpoints. It stores what was written with the
/// server's semantics: top-level settings keys merge, `ui` is patched field by field, the profile
/// form overwrites every field, and Memory entries get ids and timestamps.
final class PersonalizationServer: Sendable {
    struct State {
        var settings: [String: JSONValue]
        var profile: [String: JSONValue]
        var memories: [[String: JSONValue]] = []
        var nextID = 1
        var now: Double = 1_792_789_049
        var failingPaths: Set<String> = []
    }

    let state: Mutex<State>

    init(
        settings: [String: JSONValue] = ["ui": .object(["memory": .bool(true), "system": .string("Be brief.")])],
        name: String = "Ada Lovelace"
    ) {
        state = Mutex(State(
            settings: settings,
            profile: [
                "id": .string("u1"), "name": .string(name), "email": .string("ada@example.com"), "role": .string("user"),
                "profile_image_url": .string("/user.png"), "bio": .string("Mathematician"), "gender": .null, "date_of_birth": .null,
            ]
        ))
    }

    /// Makes requests to `path` (e.g. `"api/v1/auths/update/profile"`) fail with a 500.
    func fail(_ path: String) {
        state.withLock { _ = $0.failingPaths.insert(path) }
    }

    func addMemory(_ content: String, path: String? = nil, type: String = "user", at time: Double? = nil) {
        state.withLock { state in
            let id = "m\(state.nextID)"
            state.nextID += 1
            let stamp = JSONValue.number(time ?? state.now)
            state.memories.append([
                "id": .string(id), "user_id": .string("u1"), "type": .string(type), "path": path.map(JSONValue.string) ?? .null,
                "content": .string(content), "meta": .null, "created_at": stamp, "updated_at": stamp,
            ])
        }
    }

    var settings: [String: JSONValue] { state.withLock { $0.settings } }
    var profileName: String? { state.withLock { $0.profile["name"]?.stringValue } }
    var memoryContents: [String] { state.withLock { $0.memories.compactMap { $0["content"]?.stringValue } } }

    func install(on transport: StubTransport) {
        func route(_ method: String, _ path: String, _ handler: @escaping @Sendable (URLRequest, inout State) -> (Int, Data)) {
            transport.stub(method, path) { [self] request in
                state.withLock { state in
                    let requestPath = String((request.url?.path() ?? "").drop(while: { $0 == "/" }))
                    if state.failingPaths.contains(requestPath) { return (500, serverError) }
                    return handler(request, &state)
                }
            }
        }
        route("GET", "api/v1/users/user/settings") { _, state in (200, json(.object(state.settings))) }
        route("POST", "api/v1/users/user/settings/update") { request, state in
            var patch = body(request)
            if let ui = patch.removeValue(forKey: "ui")?.objectValue {
                var current = state.settings["ui"]?.objectValue ?? [:]
                for (key, value) in ui {
                    if value == .null { current.removeValue(forKey: key) } else { current[key] = value }
                }
                state.settings["ui"] = .object(current)
            }
            state.settings.merge(patch) { _, new in new }
            return (200, json(.object(state.settings)))
        }
        route("GET", "api/v1/auths/") { _, state in (200, json(.object(state.profile))) }
        route("POST", "api/v1/auths/update/profile") { request, state in
            for (key, value) in body(request) { state.profile[key] = value }
            return (200, json(.object(state.profile)))
        }
        route("GET", "api/v1/memories/") { _, state in (200, json(.array(state.memories.map(JSONValue.object)))) }
        route("POST", "api/v1/memories/add") { request, state in
            let form = body(request)
            let id = "m\(state.nextID)"
            state.nextID += 1
            state.now += 60
            let entry: [String: JSONValue] = [
                "id": .string(id), "user_id": .string("u1"), "type": form["type"] ?? .string("context"),
                "path": form["path"] ?? .null, "content": form["content"] ?? .string(""), "meta": .null,
                "created_at": .number(state.now), "updated_at": .number(state.now),
            ]
            state.memories.append(entry)
            return (200, json(.object(entry)))
        }
        route("DELETE", "api/v1/memories/delete/user") { _, state in
            state.memories.removeAll()
            return (200, json(.bool(true)))
        }
        // Per-entry routes: register them for the ids the fake hands out.
        for index in 1...20 {
            let id = "m\(index)"
            route("POST", "api/v1/memories/\(id)/update") { request, state in
                guard let position = state.memories.firstIndex(where: { $0["id"] == .string(id) }) else {
                    return (404, Data(#"{"detail":"Not found"}"#.utf8))
                }
                let form = body(request)
                state.now += 60
                if let content = form["content"] { state.memories[position]["content"] = content }
                if let path = form["path"] { state.memories[position]["path"] = path == .string("") ? .null : path }
                state.memories[position]["updated_at"] = .number(state.now)
                return (200, json(.object(state.memories[position])))
            }
            route("DELETE", "api/v1/memories/\(id)") { _, state in
                state.memories.removeAll { $0["id"] == .string(id) }
                return (200, json(.bool(true)))
            }
        }
    }
}
