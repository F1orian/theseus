import DesignSystem
import OpenWebUIKit
import SwiftUI

/// The Capabilities page (SET-05): switches with explanations, then a Memory section.
struct CapabilitiesSettingsView: View {
    @State private var model: CapabilitiesSettingsModel
    private let extensions: SettingsExtensions

    init(model: CapabilitiesSettingsModel, extensions: SettingsExtensions = SettingsExtensions()) {
        _model = State(initialValue: model)
        self.extensions = extensions
    }

    var body: some View {
        List {
            Section {
                ForEach(model.rows, id: \.self) { row in
                    SettingsToggleRow(
                        title: row.title,
                        systemImage: row.systemImage,
                        caption: row.caption,
                        isOn: Binding(
                            get: { model.isOn(row) },
                            set: { on in Task { await model.set(row, on: on) } }
                        )
                    )
                    .accessibilityIdentifier("capabilities.\(row.rawValue)")
                }
            } footer: {
                Text("Defaults for new chats. You can still turn these on or off in each chat.")
            }
            // #141: suggested next prompts, shared with the web client.
            Section {
                SettingsToggleRow(
                    title: "Suggest follow-ups",
                    systemImage: "text.bubble",
                    caption: "Show a few suggested next questions under the latest response.",
                    isOn: Binding(get: { model.followUps }, set: { on in Task { await model.setFollowUps(on) } })
                )
                .accessibilityIdentifier("capabilities.followUps")
            }
            // #140: the Server's Skills, read-only. Pick them per chat in Add to Chat.
            if !model.skills.isEmpty {
                Section {
                    ForEach(model.skills) { skill in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(Self.displayName(skill))
                                .font(Typography.body)
                                .foregroundStyle(Palette.textPrimary.color)
                            if let description = skill.description {
                                Text(description)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary.color)
                                    .lineLimit(3)
                            }
                        }
                        .settingsRowBackground()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("capabilities.skill")
                    }
                } header: {
                    Text("Skills")
                } footer: {
                    Text("Skills you can use. Models may use them when they fit, or you can pick them for a chat in Add to Chat. Add your own in Settings › Skills.")
                }
            }
            if model.showsMemory, let memory = extensions.content(for: .capabilitiesMemory) {
                memory
            } else if model.showsMemory {
                Section("Memory") {
                    NavigationLink(value: SettingsPage.extension(.memory)) {
                        SettingsRowLabel(title: "Memory", systemImage: "brain")
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("capabilities.memory")
                }
            }
        }
        .settingsList()
        .overlay {
            if model.isLoading, model.rows.isEmpty { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.errorMessage {
                SettingsErrorBanner(message: message) { model.dismissError() }
            }
        }
        .navigationTitle("Capabilities")
        .settingsInlineTitle()
        .task { await model.load() }
        .accessibilityIdentifier("settings.capabilities")
    }
}

extension CapabilitiesSettingsView {
    /// "deep-research" → "Deep research".
    static func displayName(_ skill: Skill) -> String {
        let base = skill.name == skill.id ? skill.id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") : skill.name
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}

extension CapabilitiesSettingsModel.Row {
    var title: String {
        switch self {
        case .artifacts: "Artifacts"
        case .sandbox: "Code execution and file creation"
        case .codeInterpreter: "Code execution"
        case .webSearch: "Web search"
        case .imageGeneration: "Image generation"
        case .askBeforeTools: "Ask before running tools"
        }
    }

    var systemImage: String {
        switch self {
        case .artifacts: "doc.richtext"
        case .sandbox: "doc.badge.gearshape"
        case .codeInterpreter: "chevron.left.forwardslash.chevron.right"
        case .webSearch: "globe"
        case .imageGeneration: "photo"
        case .askBeforeTools: "hand.raised"
        }
    }

    var caption: String {
        switch self {
        case .artifacts: "Open substantial documents, code, web pages and diagrams in their own viewer."
        case .sandbox: "Let models run code and create documents, spreadsheets, slides and PDFs in this Server's sandbox."
        case .codeInterpreter: "Let models run code to analyse data and work out answers."
        case .webSearch: "Let models search the web when they need current information."
        case .imageGeneration: "Let models create images from your descriptions."
        case .askBeforeTools: "Models pause before running a command or a connector, so you can allow or deny each step."
        }
    }
}

/// A dismissible error line docked at the bottom of a Settings page.
struct SettingsErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.destructive.color)
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.textSecondary.color)
        }
        .padding(Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.s)
        .accessibilityIdentifier("settings.error")
    }
}
