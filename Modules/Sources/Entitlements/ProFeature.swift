/// What Theseus Pro unlocks (ADR 0173). Everything else (Chats, Projects, Artifacts,
/// attachments, web search, Memory, Styles, Incognito, Dictation, read aloud and the
/// iPad and Mac layout) is free, without limits.
public enum ProFeature: String, CaseIterable, Sendable, Identifiable, Hashable {
    /// Code execution without the free daily allowance: in the Server's sandbox (code and files), or
    /// through its Jupyter code interpreter. The case keeps its first name, `sandbox`.
    case sandbox
    /// The Server's Skills (#140): Add to Chat › Skills and the `/` menu.
    case skills
    /// Turning Connectors on in a chat (CONN-02): the Server's tools, tool servers and MCP servers,
    /// and personal connectors. The Connectors a model comes with stay free, and so does setting
    /// them up in Settings › Connectors.
    case connectors
    /// Hands-free Voice mode (VOICE-03). Dictation stays free.
    case voiceMode
    /// More than one Account or Server on this device (AUTH-07).
    case accounts
    /// Widgets, Shortcuts, Siri, the Share sheet and `theseus://` links (PLAT-01, PLAT-03, PLAT-04).
    case platform
    /// The alternate app icons (BRAND-02). The Renoir stays free.
    case appIcons

    public var id: String { rawValue }

    /// The paywall's checklist title.
    public var title: String {
        switch self {
        case .sandbox: "Unlimited code execution"
        case .skills: "Skills"
        case .connectors: "Connectors"
        case .voiceMode: "Voice mode"
        case .accounts: "Several Servers and Accounts"
        case .platform: "Widgets, Shortcuts and sharing"
        case .appIcons: "App icons from The Collection"
        }
    }

    /// One line under the title, for when the Server isn't known: Server-dependent features say
    /// "when your Server supports it". `ServerSupport.detail(for:)` drops that once it is.
    public var detail: String {
        switch self {
        case .sandbox:
            "Run code and create files as often as you like, when your Server supports it. Free includes \(SandboxAllowance.dailyLimit) runs a day."
        case .skills: "Use Skills, like deep research and documents, when your Server supports them."
        case .connectors:
            "Turn on tools and MCP servers in any chat, when your Server supports them. The ones a model comes with stay free."
        case .voiceMode: "Talk with your models hands-free."
        case .accounts: "Sign in to more than one Server or Account and switch in a tap."
        case .platform: "Start chats from the Home Screen, Siri, Shortcuts and the Share sheet."
        case .appIcons: "Choose from \(Self.alternateIconCount) more icons with paintings from The Collection."
        }
    }

    public var systemImage: String {
        switch self {
        case .sandbox: "chevron.left.forwardslash.chevron.right"
        case .skills: "sparkles"
        case .connectors: "square.grid.2x2"
        case .voiceMode: "waveform"
        case .accounts: "person.2"
        case .platform: "square.grid.2x2"
        case .appIcons: "app.badge"
        }
    }

    /// The paywall's headline when it opens from this feature ("Voice mode is part of Theseus Pro").
    public var gateHeadline: String {
        switch self {
        case .sandbox: "You've used today's free code execution runs"
        case .skills: "Skills are part of Theseus Pro"
        case .connectors: "Connectors are part of Theseus Pro"
        case .voiceMode: "Voice mode is part of Theseus Pro"
        case .accounts: "More Accounts are part of Theseus Pro"
        case .platform: "Widgets, Shortcuts and sharing are part of Theseus Pro"
        case .appIcons: "This icon is part of Theseus Pro"
        }
    }

    /// The line under the gate headline.
    public var gateMessage: String {
        switch self {
        case .sandbox:
            "Code execution is back tomorrow with \(SandboxAllowance.dailyLimit) more free runs, or unlimited with Pro."
        case .skills: "Pick Skills for a chat, or type / to find one, once Pro is unlocked."
        case .connectors: "The Connectors a model comes with stay free. Pro lets you turn on any Connector in a chat."
        case .voiceMode: "Dictation stays free. Pro adds hands-free conversations."
        case .accounts: "Your first Account is free. Pro lets you add more and switch between them."
        case .platform: "Pro starts chats from widgets, Siri, Shortcuts, the Share sheet and links."
        case .appIcons: "The Renoir stays free. Pro unlocks every icon in the picker."
        }
    }

    /// The paywall checklist's order (`ServerSupport.checklist(leading:)` leaves out what the
    /// Server lacks).
    public static let checklist: [ProFeature] = [.sandbox, .skills, .connectors, .voiceMode, .accounts, .platform, .appIcons]

    /// The shipped alternate icons (BRAND-02, `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
    public static let alternateIconCount = 11
}

/// What stays free, for the paywall's "Free stays free" line.
public enum FreeTier {
    public static let summary =
        "Chats, Projects, Artifacts, attachments, web search, Memory, Styles, Incognito, dictation and the iPad layout stay free, without limits."
}
