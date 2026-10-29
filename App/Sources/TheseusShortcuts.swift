import AppIntents
import AppIntentsFeature

/// Pulls the App Intents defined in `AppIntentsFeature` into the app's metadata (PLAT-03).
struct TheseusAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [AppIntentsFeaturePackage.self]
    }
}

/// Theseus's App Shortcuts: available in Siri, Spotlight and Shortcuts without any setup.
/// Phrases are a public contract once shipped: add new ones, don't rename or remove them.
struct TheseusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskTheseusIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask Theseus",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a chat in \(.applicationName)",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: StartVoiceModeIntent(),
            phrases: [
                "Start voice mode in \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Voice Mode",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: NewIncognitoChatIntent(),
            phrases: ["New incognito chat in \(.applicationName)"],
            shortTitle: "Incognito Chat",
            systemImageName: "theatermasks"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a chat in \(.applicationName)",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
