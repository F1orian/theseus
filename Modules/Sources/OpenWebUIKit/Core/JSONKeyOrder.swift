import Foundation

/// Reads the **document order** of object keys, which `JSONDecoder` discards. Open WebUI's
/// Python dicts keep insertion order, so admin-defined menus (model controls, their options)
/// arrive in the order the admin wrote them; this scanner recovers it.
///
/// `JSONKeyOrder(data)?.keys(at: ["data", 0, "info"])` lists the keys of that object in order.
struct JSONKeyOrder {
    indirect enum Node {
        case object([(key: String, value: Node)])
        case array([Node])
        case scalar
    }

    enum PathComponent: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case key(String)
        case index(Int)

        init(stringLiteral value: String) { self = .key(value) }
        init(integerLiteral value: Int) { self = .index(value) }
    }

    let root: Node

    init?(_ data: Data) {
        var scanner = Scanner(bytes: Array(data))
        guard let root = scanner.value() else { return nil }
        self.root = root
    }

    /// The keys of the object at `path`, in document order (`[]` if it isn't an object).
    func keys(at path: [PathComponent]) -> [String] {
        guard case .object(let members) = node(at: path) else { return [] }
        return members.map(\.key)
    }

    func node(at path: [PathComponent]) -> Node? {
        var current = root
        for component in path {
            switch (component, current) {
            case (.key(let key), .object(let members)):
                guard let next = members.last(where: { $0.key == key })?.value else { return nil }
                current = next
            case (.index(let index), .array(let items)):
                guard items.indices.contains(index) else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        mutating func value() -> Node? {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string() == nil ? nil : .scalar
            default: return scalar()
            }
        }

        private mutating func object() -> Node? {
            index += 1
            var members: [(key: String, value: Node)] = []
            skipWhitespace()
            if peek(UInt8(ascii: "}")) { index += 1; return .object(members) }
            while index < bytes.count {
                skipWhitespace()
                guard let key = string() else { return nil }
                skipWhitespace()
                guard peek(UInt8(ascii: ":")) else { return nil }
                index += 1
                guard let value = value() else { return nil }
                members.append((key, value))
                skipWhitespace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                if peek(UInt8(ascii: "}")) { index += 1; return .object(members) }
                return nil
            }
            return nil
        }

        private mutating func array() -> Node? {
            index += 1
            var items: [Node] = []
            skipWhitespace()
            if peek(UInt8(ascii: "]")) { index += 1; return .array(items) }
            while index < bytes.count {
                guard let item = value() else { return nil }
                items.append(item)
                skipWhitespace()
                if peek(UInt8(ascii: ",")) { index += 1; continue }
                if peek(UInt8(ascii: "]")) { index += 1; return .array(items) }
                return nil
            }
            return nil
        }

        /// A string literal, unescaped well enough for object keys.
        private mutating func string() -> String? {
            guard peek(UInt8(ascii: "\"")) else { return nil }
            index += 1
            let start = index
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    let literal = Data(bytes[(start - 1)...index])
                    index += 1
                    return (try? JSONDecoder().decode(String.self, from: literal)) ?? String(decoding: literal, as: UTF8.self)
                }
                index += 1
            }
            return nil
        }

        private mutating func scalar() -> Node? {
            let start = index
            while index < bytes.count, !Self.delimiters.contains(bytes[index]) {
                index += 1
            }
            return index > start ? .scalar : nil
        }

        private static let delimiters: Set<UInt8> = [
            UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: " "),
            UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"),
        ]

        private func peek(_ byte: UInt8) -> Bool {
            index < bytes.count && bytes[index] == byte
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(bytes[index]) {
                index += 1
            }
        }
    }
}
