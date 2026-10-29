import DesignSystem
import SwiftUI

/// A Settings row label: a leading monochrome icon and a title (Visual language: inset-grouped cards).
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = Palette.textPrimary.color

    var body: some View {
        Label {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(tint)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint == Palette.textPrimary.color ? Palette.textSecondary.color : tint)
        }
    }
}

/// A switch row with an icon, a title and an optional grey caption inside the row.
struct SettingsToggleRow: View {
    let title: String
    let systemImage: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(ui: title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                    if let caption {
                        Text(ui: caption)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        }
        .hapticFeedback(.selection, trigger: isOn)
        .settingsRowBackground()
    }
}

/// A title / value pair (e.g. "Version · 0.12.3").
struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title).foregroundStyle(Palette.textPrimary.color)
        }
        .font(Typography.body)
        .settingsRowBackground()
    }
}

/// A centred empty or placeholder state with the pixel mouse only (brand.md §3, BRAND-04): `.sleep`
/// when a list is empty, `.sit` for a page still to come, `.peek` when loading failed.
struct SettingsEmptyState: View {
    let title: String
    let message: String
    var pose: PixelMouse.Pose = .sleep

    var body: some View {
        MouseEmptyState(pose: pose, title: Text(ui: title), message: Text(ui: message))
            .frame(maxWidth: .infinity)
    }
}

/// Stand-in for a page another Feature area will plug in (`SettingsExtensions`).
struct SettingsPlaceholderPage: View {
    let page: SettingsExtensionPage

    var body: some View {
        SettingsEmptyState(title: page.title, message: page.placeholderMessage, pose: .sit)
            .frame(maxHeight: .infinity)
            .themedBackground()
            .navigationTitle(page.title)
            .settingsInlineTitle()
            .accessibilityIdentifier("settings.placeholder.\(page.rawValue)")
    }
}

extension SettingsExtensionPage {
    var title: String {
        switch self {
        case .profile: "Profile"
        case .instructions: "Instructions"
        case .memory: "Memory"
        case .styles: "Styles"
        case .models: "Models"
        case .connectors: "Connectors"
        case .permissions: "Permissions"
        case .voice: "Voice"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: "person.crop.circle"
        case .instructions: "text.quote"
        case .memory: "brain"
        case .styles: "paintbrush"
        case .models: "cpu"
        case .connectors: "square.grid.2x2"
        case .permissions: "switch.2"
        case .voice: "waveform"
        }
    }

    var placeholderMessage: String {
        switch self {
        case .profile: "Your name and how Theseus addresses you will be editable here soon."
        case .instructions: "Instructions that apply to all your chats will be editable here soon."
        case .memory: "What this Server remembers about you will be shown here soon."
        case .styles: "Writing styles will be managed here soon."
        case .models: "Choose the model new chats start with."
        case .connectors: "Connectors from this Server will be listed here soon."
        case .permissions: "Device permissions will be managed here soon."
        case .voice: "Voice settings will be available here soon."
        }
    }
}

extension View {
    /// The grouped-row surface used by every Settings card.
    func settingsRowBackground() -> some View {
        listRowBackground(Palette.surface.color)
    }

    /// A grouped list on the warm canvas.
    func settingsList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .themedBackground()
        #else
        scrollContentBackground(.hidden)
            .themedBackground()
        #endif
    }

    func settingsInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
