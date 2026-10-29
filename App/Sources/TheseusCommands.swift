import AppFeature
import SwiftUI

/// PLAT-05: the menu bar (iPad, Mac "Designed for iPad") and its keyboard shortcuts: ⌘N new
/// Chat, ⌘⇧O new Incognito chat, ⌘K search Chats, ⌘, Settings. Return / ⇧Return live in the composer.
struct TheseusCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            button(.newChat).keyboardShortcut("n")
            button(.incognitoChat).keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            button(.searchChats).keyboardShortcut("k")
        }
        CommandGroup(replacing: .appSettings) {
            button(.settings).keyboardShortcut(",")
        }
    }

    /// Always enabled: a menu's enabled state isn't re-evaluated as the shell changes, and
    /// `perform` does nothing where the command doesn't apply (signed out, no Incognito chats).
    private func button(_ command: ShellCommand) -> some View {
        Button(command.title) { model.perform(command) }
    }
}
