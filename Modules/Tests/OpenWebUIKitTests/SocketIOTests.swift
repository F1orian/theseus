import Fixtures
import Foundation
@testable import OpenWebUIKit
import Testing

@Suite("Engine.IO / Socket.IO packets")
struct SocketPacketTests {
    @Test func parsesTheEngineHandshake() throws {
        let packet = try #require(EnginePacket(frame: #"0{"sid":"abc","upgrades":[],"pingTimeout":20000,"pingInterval":25000,"maxPayload":16777216}"#))
        #expect(packet == .open(EngineHandshake(sid: "abc", pingInterval: 25000, pingTimeout: 20000, maxPayload: 16_777_216)))
        #expect(EnginePacket(frame: "2") == .ping(""))
        #expect(EnginePacket.pong("probe").frame == "3probe")
        #expect(EnginePacket(frame: "") == nil)
        #expect(EnginePacket(frame: "9") == nil)
    }

    @Test func parsesSocketPackets() throws {
        #expect(SocketPacket(payload: #"0{"sid":"s1"}"#) == .connect(namespace: "/", payload: .object(["sid": .string("s1")])))
        #expect(SocketPacket(payload: #"0[{"id":"u","name":"N"}]"#) != nil)
        #expect(SocketPacket(payload: #"30[{"id":"u"}]"#) == .ack(namespace: "/", ackID: 0, arguments: [.object(["id": .string("u")])]))
        #expect(SocketPacket(payload: #"312[null]"#) == .ack(namespace: "/", ackID: 12, arguments: [.null]))
        #expect(SocketPacket(payload: #"2["events",{"a":1}]"#) == .event(namespace: "/", ackID: nil, name: "events", arguments: [.object(["a": .number(1)])]))
        #expect(SocketPacket(payload: #"212["events",{}]"#) == .event(namespace: "/", ackID: 12, name: "events", arguments: [.object([:])]))
        #expect(SocketPacket(payload: #"2/admin,3["x"]"#) == .event(namespace: "/admin", ackID: 3, name: "x", arguments: []))
        #expect(SocketPacket(payload: #"4{"message":"nope"}"#) == .connectError(namespace: "/", payload: .object(["message": .string("nope")])))
        #expect(SocketPacket(payload: "1") == .disconnect(namespace: "/"))
        #expect(SocketPacket(payload: "2not json") == nil)
        #expect(SocketPacket(payload: "51-[\"bin\"]") == nil)
    }

    @Test func encodesFramesTheServerAccepts() {
        let connect = SocketPacket.connect(namespace: "/", payload: .object(["token": .string("jwt")]))
        #expect(connect.frame == #"40{"token":"jwt"}"#)
        let join = SocketPacket.event(namespace: "/", ackID: 0, name: "user-join", arguments: [.object(["auth": .object(["token": .string("jwt")])])])
        #expect(join.frame == #"420["user-join",{"auth":{"token":"jwt"}}]"#)
        let ack = SocketPacket.ack(namespace: "/", ackID: 7, arguments: [.object(["n": .number(1)])])
        #expect(ack.frame == #"437[{"n":1}]"#)
    }

    @Test func socketURLKeepsSubPathsAndSwitchesScheme() throws {
        let secure = SocketIOClient.socketURL(for: try ServerURL.normalize("https://example.com/owui"))
        #expect(secure.absoluteString == "wss://example.com/owui/ws/socket.io/?EIO=4&transport=websocket")
        let local = SocketIOClient.socketURL(for: try ServerURL.normalize("http://192.168.1.5:8080"))
        #expect(local.absoluteString == "ws://192.168.1.5:8080/ws/socket.io/?EIO=4&transport=websocket")
    }

    @Test func backoffIsExponentialAndCapped() {
        let backoff = SocketIOClient.Backoff(initial: .seconds(1), maximum: .seconds(5))
        #expect((0...5).map(backoff.delay(attempt:)) == [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)])
    }
}

/// Waits (bounded) until `condition` holds.
func eventually(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("SocketIOClient replaying recorded frames")
struct SocketIOClientTests {
    func makeClient(_ replay: SocketReplay, token: String? = "jwt") -> SocketIOClient {
        SocketIOClient(
            server: Fixture.serverURL,
            connector: replay,
            backoff: .init(initial: .milliseconds(10), maximum: .milliseconds(20)),
            joinTimeout: .seconds(2)
        ) { token }
    }

    @Test func authenticatesAndJoinsBeforeReportingASessionID() async throws {
        let replay = try SocketReplay(scenario: "plain")
        let socket = makeClient(replay)
        await socket.start()
        let sessionID = try await socket.joinedSessionID(timeout: .seconds(5))

        // The Socket.IO sid from `40{"sid":…}`, not the Engine.IO sid.
        #expect(sessionID == "gh5iwfrnuZ-cZvaJAAAF")
        let sent = try #require(replay.sentFrames.first)
        #expect(sent.first == #"40{"token":"jwt"}"#)
        #expect(sent.dropFirst().first == #"420["user-join",{"auth":{"token":"jwt"}}]"#)
        await socket.stop()
        #expect(await socket.state == .idle)
    }

    @Test func deliversEventsAndAnswersPings() async throws {
        let replay = try SocketReplay(scenario: "stop")
        let socket = makeClient(replay)
        let events = await socket.events()
        await socket.start()
        _ = try await socket.joinedSessionID(timeout: .seconds(5))
        replay.open(.completion)
        replay.open(.stop)

        var names: [String] = []
        for await event in events {
            if let type = event.arguments.first?[path: "data.type"]?.stringValue { names.append(type) }
            if names.last == "chat:active", names.contains("chat:tasks:cancel") { break }
        }
        #expect(names.first == "chat:list")
        #expect(names.filter { $0 == "chat:tasks:cancel" }.count == 2)
        // The recorded server ping (after the cancel) is answered with a pong.
        #expect(await eventually { replay.sentFrames.first?.contains("3") == true })
        await socket.stop()
    }

    @Test func reconnectsAndRejoinsAfterTheConnectionDrops() async throws {
        let replay = try SocketReplay(scenario: "resume")
        let socket = makeClient(replay)
        let states = await socket.states()
        await socket.start()
        let first = try await socket.joinedSessionID(timeout: .seconds(5))
        replay.open(.completion)

        var joined: [String] = []
        var sawDisconnect = false
        for await state in states {
            if case .disconnected = state { sawDisconnect = true }
            if let id = state.sessionID, joined.last != id { joined.append(id) }
            if joined.count == 2 { break }
        }
        #expect(sawDisconnect)
        #expect(joined.first == first)
        #expect(joined.count == 2 && joined[0] != joined[1])
        #expect(replay.connectionCount == 2)
        await socket.stop()
    }

    @Test func aRejectedTokenStopsRetrying() async throws {
        let log = """
        {"t":0,"dir":"note","note":"socket: open wss://x"}
        {"t":1,"dir":"in","frame":"0{\\"sid\\":\\"e\\",\\"upgrades\\":[],\\"pingTimeout\\":20000,\\"pingInterval\\":25000}"}
        {"t":2,"dir":"out","frame":"40{}"}
        {"t":3,"dir":"in","frame":"40{\\"sid\\":\\"s\\"}"}
        {"t":4,"dir":"out","frame":"420[]"}
        {"t":5,"dir":"in","frame":"430[null]"}
        """
        let replay = try SocketReplay(log: log)
        let socket = makeClient(replay, token: "expired")
        await socket.start()
        await #expect(throws: SocketIOClient.Failure.unauthorized) {
            _ = try await socket.joinedSessionID(timeout: .seconds(5))
        }
        #expect(await eventually { await socket.state == .unauthorized })
        #expect(replay.connectionCount == 1)
        await socket.stop()
    }

    @Test func noTokenMeansUnauthorizedWithoutConnecting() async throws {
        let replay = try SocketReplay(scenario: "plain")
        let socket = makeClient(replay, token: nil)
        await socket.start()
        #expect(await eventually { await socket.state == .unauthorized })
        #expect(replay.connectionCount == 0)
        await socket.stop()
    }
}
