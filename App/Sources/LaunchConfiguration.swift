import AppFeature
import Entitlements

/// Launch arguments understood by the app (used by UI tests and local debugging).
struct LaunchConfiguration: Equatable {
    /// `-theseus-ui-testing`: nothing persists (in-memory credentials, registry and databases).
    static let uiTestingArgument = "-theseus-ui-testing"
    /// `-theseus-reset`: forget every Account (Keychain items, registry, databases) before launch.
    static let resetArgument = "-theseus-reset"
    /// `-theseus-pro free` / `-theseus-pro pro`: Theseus Pro from memory instead of the App Store
    /// (ADR 0173). UI-testing launches are Pro unless they pass `free`.
    static let proArgument = "-theseus-pro"

    enum ProOverride: String, Equatable {
        case free
        case pro
    }

    let isUITesting: Bool
    let resetsState: Bool
    let pro: ProOverride?

    init(arguments: [String]) {
        isUITesting = arguments.contains(Self.uiTestingArgument)
        resetsState = arguments.contains(Self.resetArgument)
        pro = arguments.firstIndex(of: Self.proArgument)
            .flatMap { arguments.indices.contains($0 + 1) ? ProOverride(rawValue: arguments[$0 + 1]) : nil }
    }

    func makeEnvironment() -> AppEnvironment {
        let backend = pro.map { InMemoryProBackend(entitled: $0 == .pro) }
        if isUITesting {
            return .ephemeral(pro: backend ?? InMemoryProBackend(entitled: true))
        }
        var environment = AppEnvironment.live(reset: resetsState)
        if let backend { environment.proBackend = backend }
        return environment
    }
}
