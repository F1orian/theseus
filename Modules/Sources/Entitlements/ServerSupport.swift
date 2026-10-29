public import SwiftUI

/// What the active Account's Server offers of Theseus Pro's Server-dependent features (ADR 0173):
/// code execution (its sandbox, or a Jupyter code interpreter), Skills and Connectors. The paywall, Settings ›
/// Theseus Pro and the upgrade card promise only what it offers, and qualify what isn't known yet
/// ("when your Server supports it").
///
/// The shell knows the Server's Capabilities; Entitlements and the paywall don't. The shell sets
/// this where the gates live, and every paywall below it reads it:
///
/// ```swift
/// MainShellView(model: shell)
///     .environment(\.serverSupport, shell.serverSupport)
/// ```
public struct ServerSupport: Sendable, Hashable {
    public enum CodeExecution: Sendable, Hashable {
        /// Not known yet (signed out, still loading).
        case unknown
        /// The Server's sandbox: the model runs code and creates files.
        case sandbox
        /// Only the Server's Jupyter code interpreter: the model runs code.
        case interpreter
        /// Neither.
        case none
    }

    public var codeExecution: CodeExecution
    /// Whether the Account can use Skills on this Server; `nil` while unknown.
    public var skills: Bool?
    /// Whether the Account has Connectors to turn on (the Server's, or personal ones); `nil` while
    /// unknown.
    public var connectors: Bool?

    public init(codeExecution: CodeExecution, skills: Bool?, connectors: Bool? = nil) {
        self.codeExecution = codeExecution
        self.skills = skills
        self.connectors = connectors
    }

    /// Nothing known: every feature shows, Server-dependent ones with the qualifier.
    public static let unknown = ServerSupport(codeExecution: .unknown, skills: nil, connectors: nil)

    /// Whether the Server offers `feature`, or `nil` while that isn't known. Features that don't
    /// depend on the Server are always offered.
    public func offers(_ feature: ProFeature) -> Bool? {
        switch feature {
        case .sandbox:
            switch codeExecution {
            case .unknown: nil
            case .sandbox, .interpreter: true
            case .none: false
            }
        case .skills: skills
        case .connectors: connectors
        case .voiceMode, .accounts, .platform, .appIcons: true
        }
    }

    /// Whether the free code execution runs mean anything here (Settings' "Code execution today").
    public var mentionsCodeExecutionRuns: Bool { offers(.sandbox) != false }

    /// The checklist without what the Server lacks, so it leads with what it offers. The feature a
    /// gate opened the paywall from stays first either way.
    public func checklist(leading feature: ProFeature? = nil) -> [ProFeature] {
        let offered = ProFeature.checklist.filter { offers($0) != false }
        guard let feature else { return offered }
        return [feature] + offered.filter { $0 != feature }
    }

    /// The line under a feature's title: plain when the Server offers it, qualified when unknown.
    public func detail(for feature: ProFeature) -> String {
        let free = "Free includes \(SandboxAllowance.dailyLimit) runs a day."
        switch (feature, offers(feature)) {
        case (.sandbox, true?) where codeExecution == .interpreter:
            return "Run code as often as you like. \(free)"
        case (.sandbox, true?):
            return "Run code and create files as often as you like. \(free)"
        case (.skills, true?):
            return "Use your Server's Skills, like deep research and documents."
        case (.connectors, true?):
            return "Turn on tools and MCP servers in any chat. The ones a model comes with stay free."
        default:
            return feature.detail
        }
    }

    /// The upgrade card's line in Settings: what the Server offers for sure first, then what may
    /// come with the qualifier.
    public var upgradeSummary: String {
        let names: [(ProFeature, String)] = [(.sandbox, "unlimited code execution"), (.skills, "Skills")]
        let sure = names.filter { offers($0.0) == true }.map(\.1)
        let maybe = names.filter { offers($0.0) == nil }.map(\.1)
        let items = Array((sure + ["Voice mode", "widgets", "more Accounts"]).prefix(maybe.isEmpty ? 3 : 2))
        var line = items.joined(separator: ", ") + " and more"
        if !maybe.isEmpty {
            let them = maybe.count == 1 && maybe[0] != "Skills" ? "it" : "them"
            line += ", plus \(maybe.joined(separator: " and ")) when your Server supports \(them)"
        }
        return line.prefix(1).uppercased() + line.dropFirst() + "."
    }
}

extension EnvironmentValues {
    /// What the active Account's Server offers (ADR 0173); `.unknown` outside a signed-in shell.
    @Entry public var serverSupport: ServerSupport = .unknown
}
