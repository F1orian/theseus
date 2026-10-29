import ChatDomain
import Foundation
public import OnboardingFeature
import OpenWebUIKit
import VoiceFeature
import AppIntentsFeature

/// What the app's keyboard shortcuts and menu commands do in the signed-in shell (PLAT-05).
public enum ShellCommand: CaseIterable, Sendable {
    /// ⌘N
    case newChat
    /// ⌘⇧O
    case incognitoChat
    /// ⌘K: the Chats list with its search field focused.
    case searchChats
    /// ⌘,
    case settings

    /// The menu title.
    public var title: String {
        switch self {
        case .newChat: "New Chat"
        case .incognitoChat: "New Incognito Chat"
        case .searchChats: "Search Chats"
        case .settings: "Settings…"
        }
    }
}

// MARK: iPad & Mac (PLAT-05)

extension MainShellModel {
    /// Whether `command` does anything for this Account right now (ADR 0006: no Incognito chat
    /// when the Server doesn't offer it, no Chats search without saved Chats).
    public func canPerform(_ command: ShellCommand) -> Bool {
        switch command {
        case .newChat, .settings: true
        case .incognitoChat: incognitoPolicy == .available
        case .searchChats: incognitoPolicy.savesChats
        }
    }

    /// Runs a keyboard shortcut or menu command. Like a deep link, it leaves Voice mode and the
    /// sheets on top of the shell.
    public func perform(_ command: ShellCommand) {
        guard canPerform(command) else { return }
        if voice?.session != nil { voice?.endVoiceMode() }
        switch command {
        case .newChat:
            if chat != nil {
                show(.newChat(DeepLink.NewChat()))
            } else {
                navigate(to: .newChat())
            }
        case .incognitoChat:
            show(.incognitoChat(prompt: nil))
        case .searchChats:
            isSettingsPresented = false
            chatAddingToProject = nil
            navigate(to: .chatsList)
            isChatsSearchRequested = true
        case .settings:
            guard !isSettingsPresented else { return }
            navigate(to: .settings)
        }
    }

    /// The regular-width sidebar's "Hide sidebar" / "Show sidebar".
    public func toggleSidebar() {
        isSidebarHidden.toggle()
    }
}

extension AppModel {
    /// Whether `command` applies now: only while an Account is signed in (the menu disables it otherwise).
    public func canPerform(_ command: ShellCommand) -> Bool {
        if case .main(let shell) = route { shell.canPerform(command) } else { false }
    }

    /// Runs a keyboard shortcut or menu command in the signed-in shell (PLAT-05).
    public func perform(_ command: ShellCommand) {
        guard case .main(let shell) = route else { return }
        accountSwitcher = nil
        shell.perform(command)
    }
}

// MARK: Welcome (AUTH-08)

/// Whether an Account has seen the welcome on this device (AUTH-08, ADR 0112).
struct WelcomeRecord {
    /// Live UI walkthroughs launch with this so the sheet doesn't cover what they test.
    static let skipArgument = "-theseus-skip-welcome"
    /// Shows the welcome even when it was seen (its own walkthrough).
    static let showArgument = "-theseus-show-welcome"

    let defaults: UserDefaults
    let arguments: [String]

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        self.arguments = arguments
    }

    private func key(_ accountID: String) -> String { "theseus.welcome.seen.\(accountID)" }

    func shouldShow(accountID: String) -> Bool {
        if arguments.contains(Self.showArgument) { return true }
        if arguments.contains(Self.skipArgument) { return false }
        return !defaults.bool(forKey: key(accountID))
    }

    func markSeen(accountID: String) {
        defaults.set(true, forKey: key(accountID))
    }
}

extension MainShellModel {
    /// After the first load: the welcome for an Account that hasn't seen it, unless something
    /// else (a deep link's sheet, Settings, Voice mode) is already on screen.
    func prepareWelcome(features: ServerFeatures) async {
        guard welcomeRecord.shouldShow(accountID: account.id), welcome == nil else { return }
        let capabilities = library.capabilities
        await connectors.loadIfNeeded()
        let audio = try? await client.send(.audioConfig)
        let summary = WelcomeSummary(
            host: ServerDisplay.host(account.server.url, fallback: account.server.name),
            capabilities: capabilities,
            savesChats: incognitoPolicy.savesChats,
            speechOnDevice: SpeechEngines.choose(for: audio) == SpeechEngines(),
            connectorNames: capabilities.contains(.connectors) ? connectors.usable.map(\.name) : []
        )
        guard !isSettingsPresented, chatAddingToProject == nil, voice?.session == nil else { return }
        welcome = summary
    }

    /// The welcome was closed: never again for this Account on this device.
    public func finishWelcome() {
        welcomeRecord.markSeen(accountID: account.id)
        welcome = nil
    }
}
