import Foundation

/// The Engine.IO v4 `open` handshake (`0{"sid":…,"pingInterval":…,"pingTimeout":…}`).
public struct EngineHandshake: Sendable, Equatable, Decodable {
    public let sid: String
    /// Milliseconds between server pings.
    public let pingInterval: Int
    /// Milliseconds the server waits for a pong (and we wait for a ping past the interval).
    public let pingTimeout: Int
    public let maxPayload: Int?

    public init(sid: String, pingInterval: Int, pingTimeout: Int, maxPayload: Int? = nil) {
        self.sid = sid
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.maxPayload = maxPayload
    }
}

/// One Engine.IO v4 packet over a WebSocket text frame. Binary frames aren't used by Open WebUI.
public enum EnginePacket: Sendable, Equatable {
    case open(EngineHandshake)
    case close
    /// In v4 the **server** pings and the client answers `pong` with the same payload.
    case ping(String)
    case pong(String)
    /// A Socket.IO packet.
    case message(String)
    case upgrade
    case noop

    public init?(frame: String) {
        guard let type = frame.first else { return nil }
        let payload = String(frame.dropFirst())
        switch type {
        case "0":
            guard let handshake = try? JSONDecoder().decode(EngineHandshake.self, from: Data(payload.utf8)) else { return nil }
            self = .open(handshake)
        case "1": self = .close
        case "2": self = .ping(payload)
        case "3": self = .pong(payload)
        case "4": self = .message(payload)
        case "5": self = .upgrade
        case "6": self = .noop
        default: return nil
        }
    }

    public var frame: String {
        switch self {
        case .open(let handshake):
            "0{\"sid\":\"\(handshake.sid)\",\"pingInterval\":\(handshake.pingInterval),\"pingTimeout\":\(handshake.pingTimeout)}"
        case .close: "1"
        case .ping(let payload): "2\(payload)"
        case .pong(let payload): "3\(payload)"
        case .message(let payload): "4\(payload)"
        case .upgrade: "5"
        case .noop: "6"
        }
    }
}

/// One Socket.IO v4 packet: `<type>[<namespace>,][<ack id>][<JSON>]`. Only the default
/// namespace `/` is used by Open WebUI, and binary attachments are unsupported.
public enum SocketPacket: Sendable, Equatable {
    case connect(namespace: String, payload: JSONValue?)
    case disconnect(namespace: String)
    case event(namespace: String, ackID: Int?, name: String, arguments: [JSONValue])
    case ack(namespace: String, ackID: Int, arguments: [JSONValue])
    case connectError(namespace: String, payload: JSONValue?)

    public init?(payload: String) {
        var rest = Substring(payload)
        guard let type = rest.first else { return nil }
        rest = rest.dropFirst()

        var namespace = "/"
        if rest.first == "/" {
            guard let comma = rest.firstIndex(of: ",") else { return nil }
            namespace = String(rest[..<comma])
            rest = rest[rest.index(after: comma)...]
        }
        let digits = rest.prefix(while: \.isNumber)
        let ackID = digits.isEmpty ? nil : Int(digits)
        rest = rest.dropFirst(digits.count)
        let json: JSONValue? = rest.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: Data(rest.utf8))
        if !rest.isEmpty, json == nil { return nil }

        switch type {
        case "0":
            self = .connect(namespace: namespace, payload: json)
        case "1":
            self = .disconnect(namespace: namespace)
        case "2":
            guard case .array(let items)? = json, case .string(let name)? = items.first else { return nil }
            self = .event(namespace: namespace, ackID: ackID, name: name, arguments: Array(items.dropFirst()))
        case "3":
            guard let ackID, case .array(let items)? = json else { return nil }
            self = .ack(namespace: namespace, ackID: ackID, arguments: items)
        case "4":
            self = .connectError(namespace: namespace, payload: json)
        default:
            // 5/6 are binary events/acks.
            return nil
        }
    }

    public var payload: String {
        func prefix(_ type: String, _ namespace: String, _ ackID: Int?) -> String {
            type + (namespace == "/" ? "" : namespace + ",") + (ackID.map(String.init) ?? "")
        }
        switch self {
        case .connect(let namespace, let payload):
            return prefix("0", namespace, nil) + (payload.map(Self.encode) ?? "")
        case .disconnect(let namespace):
            return prefix("1", namespace, nil)
        case .event(let namespace, let ackID, let name, let arguments):
            return prefix("2", namespace, ackID) + Self.encode(.array([.string(name)] + arguments))
        case .ack(let namespace, let ackID, let arguments):
            return prefix("3", namespace, ackID) + Self.encode(.array(arguments))
        case .connectError(let namespace, let payload):
            return prefix("4", namespace, nil) + (payload.map(Self.encode) ?? "")
        }
    }

    /// The Engine.IO frame carrying this packet.
    public var frame: String { EnginePacket.message(payload).frame }

    private static func encode(_ value: JSONValue) -> String {
        (try? String(decoding: SocketJSON.encoder.encode(value), as: UTF8.self)) ?? "null"
    }
}

enum SocketJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
