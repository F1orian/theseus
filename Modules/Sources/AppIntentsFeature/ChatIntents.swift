public import AppIntents
public import Foundation

/// What a new Chat opens with (widget buttons, Shortcuts). Raw values are stored in saved
/// shortcuts: never change them, only add.
public enum ChatStartOption: String, AppEnum, Sendable {
    case camera
    case photos
    case dictation
    case voiceMode = "voice"

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Start with")
    public static let caseDisplayRepresentations: [ChatStartOption: DisplayRepresentation] = [
        .camera: DisplayRepresentation(title: "Camera", image: .init(systemName: "camera")),
        .photos: DisplayRepresentation(title: "Photos", image: .init(systemName: "photo.on.rectangle")),
        .dictation: DisplayRepresentation(title: "Dictation", image: .init(systemName: "mic")),
        .voiceMode: DisplayRepresentation(title: "Voice mode", image: .init(systemName: "waveform")),
    ]

    var start: DeepLink.NewChat.Start {
        switch self {
        case .camera: .camera
        case .photos: .photos
        case .dictation: .dictation
        case .voiceMode: .voiceMode
        }
    }
}

/// Opens Theseus on a new Chat, optionally with the camera, photos, Dictation or Voice mode.
public struct NewChatIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Chat"
    public static let description = IntentDescription("Starts a new chat in Theseus.")
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Start with")
    public var start: ChatStartOption?

    public static var parameterSummary: some ParameterSummary {
        Summary("Start a new chat with \(\.$start)")
    }

    public init() {}

    public init(start: ChatStartOption?) {
        self.start = start
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.open(.newChat(DeepLink.NewChat(start: start?.start)))
        return .result()
    }
}

/// Opens a new Chat and sends the prompt ("Ask Theseus").
public struct AskTheseusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask Theseus"
    public static let description = IntentDescription("Opens a new chat in Theseus and sends your prompt.")
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Prompt", inputOptions: .init(multiline: true), requestValueDialog: "What would you like to ask?")
    public var prompt: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Ask Theseus \(\.$prompt)")
    }

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw $prompt.needsValueError("What would you like to ask?")
        }
        DeepLinkCenter.shared.open(.newChat(DeepLink.NewChat(prompt: prompt, sendsImmediately: true)))
        return .result()
    }
}

/// Opens a new Chat in Voice mode.
public struct StartVoiceModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Voice Mode"
    public static let description = IntentDescription("Opens Theseus in Voice mode for a spoken conversation.")
    public static let supportedModes: IntentModes = .foreground

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.open(.newChat(DeepLink.NewChat(start: .voiceMode)))
        return .result()
    }
}

/// Opens a new Incognito chat (never saved). Falls back to a regular new Chat when the Server
/// doesn't allow Incognito chats for this Account.
public struct NewIncognitoChatIntent: AppIntent {
    public static let title: LocalizedStringResource = "New Incognito Chat"
    public static let description = IntentDescription("Starts a chat in Theseus that isn't saved.")
    public static let supportedModes: IntentModes = .foreground

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.open(.incognitoChat(prompt: nil))
        return .result()
    }
}

/// Opens one of the active Account's saved Chats.
public struct OpenChatIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Chat"
    public static let description = IntentDescription("Opens a chat in Theseus.")

    @Parameter(title: "Chat")
    public var target: ChatEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    public init() {}

    public init(chat: ChatEntity) {
        target = chat
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.open(.chat(id: target.id))
        return .result()
    }
}

/// Registers this module's intents with the app and extensions that include it.
public struct AppIntentsFeaturePackage: AppIntentsPackage {}
