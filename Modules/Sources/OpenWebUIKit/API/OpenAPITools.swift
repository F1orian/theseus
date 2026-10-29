public import Foundation

/// A function the model may call, made from one OpenAPI operation, in the shape Open WebUI's
/// clients send as a direct tool server's `specs` (`{name, description, parameters}`).
///
/// The rules mirror how Open WebUI turns a spec into tools (`B/utils/tools.py`
/// `convert_openapi_to_tool_payload`; the web client does the same for direct tool servers), so
/// the model sees the same tools whichever client sent them: every operation with an
/// `operationId` is a tool; path- and operation-level parameters merge (operation wins);
/// a JSON request body's properties join the parameters.
public struct OpenAPIToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    /// A JSON schema object (`{type: object, properties, required}`).
    public let parameters: JSONValue

    public var jsonValue: JSONValue {
        .object(["name": .string(name), "description": .string(description), "parameters": parameters])
    }

    /// The HTTP methods OpenAPI 3 allows under a path (other keys are `parameters`, `x-…`).
    static let httpMethods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    /// The tools of an OpenAPI document, in document order.
    public static func tools(from document: JSONValue) -> [OpenAPIToolSpec] {
        guard let paths = document[path: "paths"]?.objectValue else { return [] }
        let components = document[path: "components"]
        var tools: [OpenAPIToolSpec] = []
        for (_, item) in orderedEntries(paths) {
            guard let methods = item.objectValue else { continue }
            for (method, operation) in orderedEntries(methods) where httpMethods.contains(method) {
                guard let operationID = operation[path: "operationId"]?.stringValue else { continue }
                tools.append(spec(operationID: operationID, operation: operation, pathItem: item, components: components))
            }
        }
        return tools
    }

    private static func spec(operationID: String, operation: JSONValue, pathItem: JSONValue, components: JSONValue?) -> OpenAPIToolSpec {
        let summary = operation[path: "description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? operation[path: "summary"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? "No description available."
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        for parameter in mergedParameters(operation: operation, pathItem: pathItem) {
            guard let name = parameter[path: "name"]?.stringValue else { continue }
            let schema = parameter[path: "schema"] ?? .object([:])
            var text = schema[path: "description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? parameter[path: "description"]?.stringValue ?? ""
            if let options = schema[path: "enum"]?.arrayValue {
                text += ". Possible values: " + options.map(describe).joined(separator: ", ")
            }
            var property: [String: JSONValue] = ["description": .string(text)]
            if let type = schema[path: "type"] { property["type"] = type }
            properties[name] = .object(property)
            if parameter[path: "required"]?.boolValue == true, !required.contains(name) { required.append(name) }
        }
        var parameters: JSONValue = .object([:])
        if let bodySchema = operation[path: "requestBody.content"]?.objectValue?["application/json"]?[path: "schema"] {
            let resolved = resolveSchema(bodySchema, components: components)
            if let bodyProperties = resolved[path: "properties"]?.objectValue {
                properties.merge(bodyProperties) { _, body in body }
                for name in resolved[path: "required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !required.contains(name) {
                    required.append(name)
                }
            } else if resolved[path: "type"]?.stringValue == "array" {
                // A body that is a bare array is the whole parameter schema.
                parameters = resolved
            }
        }
        if parameters == .object([:]) {
            parameters = .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ])
        }
        return OpenAPIToolSpec(name: operationID, description: summary, parameters: parameters)
    }

    /// Path-item parameters, overridden by operation parameters with the same name and `in`.
    static func mergedParameters(operation: JSONValue, pathItem: JSONValue) -> [JSONValue] {
        var order: [String] = []
        var merged: [String: JSONValue] = [:]
        for parameter in (pathItem[path: "parameters"]?.arrayValue ?? []) + (operation[path: "parameters"]?.arrayValue ?? []) {
            guard let name = parameter[path: "name"]?.stringValue else { continue }
            let key = "\(name):\(parameter[path: "in"]?.stringValue ?? "")"
            if merged[key] == nil { order.append(key) }
            merged[key] = parameter
        }
        return order.compactMap { merged[$0] }
    }

    /// Resolves `$ref`s against `components.schemas` into a plain JSON schema (cycles end in `{}`).
    public static func resolveSchema(_ schema: JSONValue?, components: JSONValue?, seen: Set<String> = []) -> JSONValue {
        guard let schema, let object = schema.objectValue else { return .object([:]) }
        if let reference = object["$ref"]?.stringValue {
            let name = String(reference.split(separator: "/").last ?? "")
            guard !seen.contains(name) else { return .object([:]) }
            return resolveSchema(components?[path: "schemas"]?.objectValue?[name], components: components, seen: seen.union([name]))
        }
        var resolved: [String: JSONValue] = [:]
        if let type = object["type"] {
            resolved["type"] = type
            if let description = object["description"] { resolved["description"] = description }
            switch type.stringValue {
            case "object":
                let properties = object["properties"]?.objectValue ?? [:]
                resolved["properties"] = .object(properties.mapValues { resolveSchema($0, components: components, seen: seen) })
                resolved["required"] = object["required"] ?? .array([])
            case "array":
                resolved["items"] = resolveSchema(object["items"], components: components, seen: seen)
            default:
                for key in ["enum", "format", "default"] where object[key] != nil { resolved[key] = object[key] }
            }
        }
        for keyword in ["oneOf", "anyOf", "allOf"] {
            if let options = object[keyword]?.arrayValue {
                resolved[keyword] = .array(options.map { resolveSchema($0, components: components, seen: seen) })
            }
        }
        if object["type"] == nil, !resolved.isEmpty, let description = object["description"] {
            resolved["description"] = description
        }
        return .object(resolved)
    }

    /// JSON objects decode into dictionaries, which lose the document's order. Tools keep a
    /// stable (sorted) order instead, so requests are reproducible.
    static func orderedEntries(_ object: [String: JSONValue]) -> [(String, JSONValue)] {
        object.keys.sorted().compactMap { key in object[key].map { (key, $0) } }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        default: ""
        }
    }
}

/// Calls one operation of an OpenAPI tool server **from the device** (personal connectors,
/// ADR 0095): builds the HTTP request the way Open WebUI's clients do for a direct tool server
/// (`execute:tool`), and shapes the answer as the Server expects it back: `[data, headers]`, or
/// `[{error}, null]` when the call failed.
public struct OpenAPIToolInvocation: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case unknownOperation(String)
        case invalidURL
    }

    /// The server's base URL (`url` of the connection).
    public let baseURL: String
    /// The OpenAPI document fetched from the server.
    public let document: JSONValue

    public init(baseURL: String, document: JSONValue) {
        self.baseURL = baseURL
        self.document = document
    }

    /// The request for operation `name` with the model's `params`.
    public func request(
        operation name: String,
        params: [String: JSONValue],
        bearerToken: String?,
        sessionID: String?
    ) throws(Failure) -> URLRequest {
        guard let paths = document[path: "paths"]?.objectValue else { throw .unknownOperation(name) }
        var match: (route: String, method: String, operation: JSONValue, item: JSONValue)?
        search: for (route, item) in OpenAPIToolSpec.orderedEntries(paths) {
            guard let methods = item.objectValue else { continue }
            for (method, operation) in OpenAPIToolSpec.orderedEntries(methods)
            where OpenAPIToolSpec.httpMethods.contains(method) && operation[path: "operationId"]?.stringValue == name {
                match = (route, method, operation, item)
                break search
            }
        }
        guard let match else { throw .unknownOperation(name) }

        var route = match.route
        var query: [URLQueryItem] = []
        var declared = Set<String>()
        for parameter in OpenAPIToolSpec.mergedParameters(operation: match.operation, pathItem: match.item) {
            guard let parameterName = parameter[path: "name"]?.stringValue else { continue }
            declared.insert(parameterName)
            guard let value = params[parameterName], value != .null else { continue }
            switch parameter[path: "in"]?.stringValue {
            case "path":
                let encoded = Self.text(value).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
                route = route.replacingOccurrences(of: "{\(parameterName)}", with: encoded)
            case "query":
                if case .string("") = value, parameter[path: "required"]?.boolValue != true { continue }
                query.append(URLQueryItem(name: parameterName, value: Self.text(value)))
            default:
                break
            }
        }

        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + route) else { throw .invalidURL }
        if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
        guard let url = components.url else { throw .invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = match.method.uppercased()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Session-Id") }

        if ["post", "put", "patch", "delete"].contains(match.method), match.operation[path: "requestBody"] != nil {
            let schema = OpenAPIToolSpec.resolveSchema(
                match.operation[path: "requestBody.content"]?.objectValue?["application/json"]?[path: "schema"],
                components: document[path: "components"]
            )
            let composed = ["allOf", "anyOf", "oneOf"].contains { schema[path: $0] != nil }
            let bodyProperties = composed ? [:] : (schema[path: "properties"]?.objectValue ?? [:])
            // Strict servers reject declared (path/query) parameters in the body.
            let body = bodyProperties.isEmpty ? params : params.filter { bodyProperties[$0.key] != nil || !declared.contains($0.key) }
            request.httpBody = try? WireCoding.encoder.encode(JSONValue.object(body))
        }
        return request
    }

    /// The `execute:tool` answer for a response: `[data, headers]`. JSON bodies stay JSON, text
    /// stays text, anything else becomes a `data:` URL. Error statuses become `[{error}, null]`.
    public static func result(data: Data, response: HTTPURLResponse) -> JSONValue {
        guard (200..<400).contains(response.statusCode) else {
            let text = String(decoding: data.prefix(2_000), as: UTF8.self)
            return failure("HTTP error! Status: \(response.statusCode). Message: \(text)")
        }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let body: JSONValue
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            body = json
        } else if contentType.isEmpty || contentType.hasPrefix("text/") {
            body = .string(String(decoding: data, as: UTF8.self))
        } else {
            body = .string("data:\(contentType);base64,\(data.base64EncodedString())")
        }
        var headers: [String: JSONValue] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key.lowercased()] = .string("\(value)") }
        }
        return .array([body, .object(headers)])
    }

    /// The `execute:tool` answer for a call that failed before or without a response.
    public static func failure(_ message: String) -> JSONValue {
        .array([.object(["error": .string(message)]), .null])
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default:
            return (try? WireCoding.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}
