import AppFeature
import AppIntentsFeature
import SwiftUI

@main
struct TheseusApp: App {
    @State private var model = AppModel(
        environment: LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments).makeEnvironment()
    )

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // PLAT-03: `theseus://` links from widgets, Shortcuts, the Share extension and other apps.
                .onOpenURL { url in model.open(url: url) }
                .task {
                    // App Intents (Siri, Shortcuts, widget buttons) hand their links over here; ones
                    // that arrived during a cold launch are delivered now.
                    DeepLinkCenter.shared.setHandler { [model] link in model.open(link) }
                }
        }
        // PLAT-05: keyboard shortcuts and the iPad / Mac menu bar.
        .commands { TheseusCommands(model: model) }
    }
}
