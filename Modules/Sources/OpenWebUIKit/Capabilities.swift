/// A feature the current Server, Account permissions and selected Model jointly allow (ADR 0006).
/// UI shows a control only if its Capability resolves; it never hard-codes availability.
public enum Capability: String, CaseIterable, Sendable, Hashable {
    case webSearch
    case imageGeneration
    case codeInterpreter
    /// Attach files to a Message.
    case fileUpload
    /// Attach photos the model can see.
    case imageInput
    case memory
    /// Projects (server term: folders).
    case projects
    case notes
    case channels
    case dictation
    case readAloud
    case voiceMode
    /// Incognito chat (server term: temporary chat).
    case incognitoChat
    case shareChat
    /// Open a Chat link to every signed-in user of the Server (MSG-08, ADR 0050).
    case publicChatLink
    case rateResponse
    case editMessage
    case regenerateResponse
    case continueResponse
    case deleteChat
    case deleteMessage
    case sources
    case apiKeys
    /// Profile Instructions for all Chats (server term: system prompt in user settings).
    case instructions
    /// Send request parameters such as `reasoning_effort` (Effort fallback, MODEL-02).
    case modelParams
    /// Pick from admin-defined model controls (`params.model_controls`, MODEL-02). The server
    /// drops the picks unless both `chat.controls` and `chat.params` are granted.
    case modelControls
    /// Connectors (server terms: tools, tool servers, MCP servers; CONN-02). The Server lists only
    /// what the Account may use, so this gates on the Server flags alone.
    case connectors
    /// The Server's Open Terminal sandbox: the model runs commands and creates files there
    /// (code execution & file creation, CONN-08, epic #139, ADR 0120).
    case sandbox
    /// Ask before tools run (`params.tool_approval_mode: "ask"`, OT-06): the admin allows it with
    /// tool permissions (`enable_tool_permissions`); otherwise every call runs at once.
    case toolApprovals
}

/// The resolved set of `Capability` values for one (Server, Account, Model?) combination.
public struct Capabilities: Sendable, Equatable {
    public let enabled: Set<Capability>

    public init(enabled: Set<Capability>) {
        self.enabled = enabled
    }

    public func contains(_ capability: Capability) -> Bool {
        enabled.contains(capability)
    }

    /// Resolves every Capability from its three inputs:
    /// - **Server**: `features.enable_*` from an *authenticated* `/api/config` (missing = off);
    /// - **Account**: the `permissions` tree (missing = denied). Admins bypass permissions, as the
    ///   server and web client do; pending users get nothing;
    /// - **Model** (optional): `info.meta.capabilities` (missing = supported, like the web client).
    ///   When `model` is `nil`, model requirements are ignored (e.g. for settings screens).
    ///
    /// `terminals` are the terminal servers the Account may use (`GET /api/v1/terminals/`); `nil`
    /// (not loaded) resolves no `sandbox`. With a model, its `terminalId` must name one of them;
    /// without one (settings screens), any terminal will do.
    public static func resolve(
        features: ServerFeatures,
        user: SessionUser,
        model: Model?,
        terminals: [TerminalServer]? = nil
    ) -> Capabilities {
        guard user.role != .pending else { return Capabilities(enabled: []) }
        let savesChats = IncognitoPolicy(user: user).savesChats
        let enabled = Capability.allCases.filter { capability in
            let rule = capability.rule
            // Enforced Incognito chats are never saved, so no Chat can be filed in a Project (INCOG-02).
            if capability == .projects, !savesChats { return false }
            if let flag = rule.serverFlag, !features.isEnabled(flag) { return false }
            if !rule.anyServerFlags.isEmpty, !rule.anyServerFlags.contains(where: features.isEnabled) { return false }
            if capability == .codeInterpreter, !features.runsCodeServerSide { return false }
            if capability == .sandbox {
                guard let terminals, !terminals.isEmpty else { return false }
                if let model, !terminals.contains(where: { $0.id == model.terminalID }) { return false }
            }
            if let permission = rule.permission, user.role != .admin, !user.permissions.allows(permission) {
                return false
            }
            if let permission = rule.alsoRequires, user.role != .admin, !user.permissions.allows(permission) {
                return false
            }
            if let required = rule.modelCapability, let model, !model.capabilities.supports(required) {
                return false
            }
            return true
        }
        return Capabilities(enabled: Set(enabled))
    }
}

private struct CapabilityRule {
    var serverFlag: String?
    var permission: String?
    var modelCapability: String?
    /// A second permission that must also be granted.
    var alsoRequires: String?
    /// At least one of these Server flags must be on.
    var anyServerFlags: [String] = []
}

extension Capability {
    // Sources: B/main.py (features), B/config.py DEFAULT_USER_PERMISSIONS, and the web client's
    // MessageInput gating (server flag ∧ (admin ∨ permission) ∧ model capability).
    fileprivate var rule: CapabilityRule {
        switch self {
        case .webSearch:
            CapabilityRule(serverFlag: "enable_web_search", permission: "features.web_search", modelCapability: "web_search")
        case .imageGeneration:
            CapabilityRule(
                serverFlag: "enable_image_generation",
                permission: "features.image_generation",
                modelCapability: "image_generation"
            )
        case .codeInterpreter:
            CapabilityRule(
                serverFlag: "enable_code_interpreter",
                permission: "features.code_interpreter",
                modelCapability: "code_interpreter"
            )
        case .fileUpload: CapabilityRule(permission: "chat.file_upload", modelCapability: "file_upload")
        case .imageInput: CapabilityRule(permission: "chat.file_upload", modelCapability: "vision")
        case .memory: CapabilityRule(serverFlag: "enable_memories", permission: "features.memories", modelCapability: "memory")
        case .projects: CapabilityRule(serverFlag: "enable_folders", permission: "features.folders")
        case .notes: CapabilityRule(serverFlag: "enable_notes", permission: "features.notes")
        case .channels: CapabilityRule(serverFlag: "enable_channels", permission: "features.channels")
        // Dictation/voice run on-device (ADR 0002), so they don't depend on the server's STT/TTS engine.
        case .dictation: CapabilityRule(permission: "chat.stt")
        case .readAloud: CapabilityRule(permission: "chat.tts")
        case .voiceMode: CapabilityRule(permission: "chat.call")
        case .incognitoChat: CapabilityRule(permission: "chat.temporary")
        case .shareChat: CapabilityRule(permission: "chat.share")
        case .publicChatLink: CapabilityRule(permission: "chat.share", alsoRequires: "sharing.public_chats")
        case .rateResponse: CapabilityRule(serverFlag: "enable_message_rating", permission: "chat.rate_response")
        case .editMessage: CapabilityRule(permission: "chat.edit")
        case .regenerateResponse: CapabilityRule(permission: "chat.regenerate_response")
        case .continueResponse: CapabilityRule(permission: "chat.continue_response")
        case .deleteChat: CapabilityRule(permission: "chat.delete")
        case .deleteMessage: CapabilityRule(permission: "chat.delete_message")
        case .sources: CapabilityRule(modelCapability: "citations")
        case .apiKeys: CapabilityRule(serverFlag: "enable_api_keys", permission: "features.api_keys")
        // The server drops `ui.system` from settings updates unless both are granted (B/routers/users.py).
        case .instructions: CapabilityRule(permission: "chat.system_prompt", alsoRequires: "chat.controls")
        case .modelParams: CapabilityRule(permission: "chat.params")
        case .modelControls: CapabilityRule(permission: "chat.controls", alsoRequires: "chat.params")
        // Workspace tools need `enable_tools`, tool and MCP servers `enable_tool_servers` (B/routers/tools.py).
        case .connectors: CapabilityRule(anyServerFlags: ["enable_tools", "enable_tool_servers"])
        // Terminals are tool servers: off with `enable_tool_servers`, and per model with the `terminal`
        // capability (missing = on, like the web client). Access is the Server's: it lists only the
        // terminals this Account may use (B/routers/terminals.py).
        case .sandbox: CapabilityRule(serverFlag: "enable_tool_servers", modelCapability: "terminal")
        case .toolApprovals: CapabilityRule(serverFlag: "enable_tool_permissions")
        }
    }
}
