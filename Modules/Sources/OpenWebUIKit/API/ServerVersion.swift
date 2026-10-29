/// `GET /api/version`.
public struct ServerVersion: Sendable, Equatable, Decodable {
    public let version: String
    public let deploymentID: String?

    enum CodingKeys: String, CodingKey {
        case version
        case deploymentID = "deployment_id"
    }

    public init(version: String, deploymentID: String? = nil) {
        self.version = version
        self.deploymentID = deploymentID
    }

    /// Numeric `major.minor.patch` components (missing parts are 0; suffixes like `-dev` are ignored).
    public var components: [Int] {
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let numbers = core.split(separator: ".").map { Int($0) ?? 0 }
        return (numbers + [0, 0, 0]).prefix(3).map { $0 }
    }

    /// Whether this Server is at least `minimum` (e.g. `"0.12.0"`).
    public func isAtLeast(_ minimum: String) -> Bool {
        components.lexicographicallyPrecedes(ServerVersion(version: minimum).components) == false
    }
}
