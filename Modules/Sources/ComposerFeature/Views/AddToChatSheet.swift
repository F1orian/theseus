import DesignSystem
import Entitlements
import OpenWebUIKit
public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Rows other Feature areas put into the Add to Chat sheet. Without a registration, Add to
/// project shows a placeholder page and Connectors stays hidden.
public struct AddToChatExtensions {
    /// Add to project (PROJ-06, Projects epic): the destination and the current value.
    public var project: (@MainActor () -> AnyView)?
    public var projectValue: (@MainActor () -> String?)?
    /// Connectors for this Chat (CONN-02, Connectors & tools epic): the page, given the Chat's
    /// composer (its per-Chat switches), and the row's value (e.g. "2 on").
    public var connectors: (@MainActor (ComposerModel) -> AnyView)?
    public var connectorsValue: (@MainActor (ComposerModel) -> String?)?
    /// Choose style (PERS-05, Memory & personalization epic): the page and the chosen Style's name.
    /// Shown when the `instructions` Capability resolves (a Style is part of the system prompt).
    public var style: (@MainActor () -> AnyView)?
    public var styleValue: (@MainActor () -> String?)?

    public init(
        project: (@MainActor () -> AnyView)? = nil,
        projectValue: (@MainActor () -> String?)? = nil,
        connectors: (@MainActor (ComposerModel) -> AnyView)? = nil,
        connectorsValue: (@MainActor (ComposerModel) -> String?)? = nil,
        style: (@MainActor () -> AnyView)? = nil,
        styleValue: (@MainActor () -> String?)? = nil
    ) {
        self.project = project
        self.projectValue = projectValue
        self.connectors = connectors
        self.connectorsValue = connectorsValue
        self.style = style
        self.styleValue = styleValue
    }
}

extension EnvironmentValues {
    @Entry public var addToChatExtensions = AddToChatExtensions()
}

/// "Add to Chat" (HOME-03): Camera / Photos / Files tiles, then Add to project, the Server's tool
/// switches (web search, image creation) and Connectors. Every entry is gated by its Capability
/// (ADR 0006): a model that can't see images gets no Camera or Photos, and so on.
struct AddToChatSheet: View {
    @Bindable var model: ComposerModel
    let onPick: (ComposerView.Picker) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.addToChatExtensions) private var extensions
    @State private var confirmingWebSearch = false
    /// ADR 0173: the paywall from this sheet (Skills, the sandbox allowance).
    @State private var paywall: PaywallRequest?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                if !tiles.isEmpty, dynamicTypeSize.isAccessibilitySize {
                    // PLAT-06: at the accessibility sizes the tiles become ordinary rows.
                    Section {
                        ForEach(tiles, id: \.picker) { tile in
                            Button { onPick(tile.picker) } label: {
                                Label {
                                    Text(tile.title).fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: tile.symbol)
                                }
                                .foregroundStyle(Palette.textPrimary.color)
                            }
                            .accessibilityIdentifier("addToChat.\(tile.title.lowercased())")
                        }
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                } else if !tiles.isEmpty {
                    Section {
                        HStack(spacing: Spacing.m) {
                            ForEach(tiles, id: \.picker) { tile in
                                Tile(title: tile.title, systemImage: tile.symbol) { onPick(tile.picker) }
                                    .accessibilityIdentifier("addToChat.\(tile.title.lowercased())")
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                if model.canAddToProject {
                    Section {
                        NavigationLink {
                            extensions.project?() ?? AnyView(ComingSoonPage(title: "Add to project", systemImage: "folder", message: "Adding a chat to a Project is coming to Theseus soon."))
                        } label: {
                            IconValueRow(title: "Add to project", systemImage: "folder", value: extensions.projectValue?() ?? "None")
                        }
                        .accessibilityIdentifier("addToChat.project")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                if !model.availableToggles.isEmpty {
                    Section {
                        ForEach(model.availableToggles, id: \.self) { feature in
                            Toggle(isOn: Binding(get: { model.isOn(feature) }, set: { set(feature, on: $0) })) {
                                Group {
                                    if dynamicTypeSize.isAccessibilitySize {
                                        // PLAT-06: the switch leaves the title too little room for an icon.
                                        Text(feature.title)
                                    } else {
                                        Label(feature.title, systemImage: feature.symbol)
                                    }
                                }
                                .foregroundStyle(Palette.textPrimary.color)
                            }
                            .tint(Palette.accent.color)
                            .accessibilityIdentifier("addToChat.toggle.\(feature.rawValue)")
                            // ADR 0173: the free tier's daily code execution runs, and the way to unlimited.
                            if feature == .codeInterpreter, let summary = model.sandboxAllowanceSummary {
                                SandboxAllowanceRow(summary: summary, isExhausted: model.services.pro.allowance.isExhausted) {
                                    paywall = PaywallRequest(.sandbox)
                                }
                            }
                        }
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                // PERS-05: a Style is part of the system prompt, so it needs the Instructions permission.
                if let style = extensions.style, model.capabilities.contains(.instructions) {
                    Section {
                        NavigationLink {
                            style()
                        } label: {
                            IconValueRow(title: "Choose style", systemImage: "pencil.and.scribble", value: extensions.styleValue?())
                        }
                        .accessibilityIdentifier("addToChat.style")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                // CONN-02: only when the Server offers Connectors and the Connectors area registered.
                if let connectors = extensions.connectors, model.capabilities.contains(.connectors) {
                    Section {
                        NavigationLink {
                            connectors(model)
                        } label: {
                            IconValueRow(title: "Connectors", systemImage: "square.grid.2x2", value: extensions.connectorsValue?(model))
                        }
                        .accessibilityIdentifier("addToChat.connectors")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                // #140: the Server's Skills, when it has any.
                if !model.services.skills.isEmpty {
                    Section {
                        if model.services.pro.allows(.skills) {
                            NavigationLink {
                                SkillsPickerPage(model: model)
                            } label: {
                                IconValueRow(
                                    title: "Skills",
                                    systemImage: "sparkles",
                                    value: model.selectedSkillIDs.isEmpty ? nil : "\(model.selectedSkills.count) on"
                                )
                            }
                            .accessibilityIdentifier("addToChat.skillsRow")
                        } else {
                            // ADR 0173: Skills are Pro; the row says so and opens the paywall.
                            Button {
                                paywall = PaywallRequest(.skills)
                            } label: {
                                HStack {
                                    Label("Skills", systemImage: "sparkles")
                                        .foregroundStyle(Palette.textPrimary.color)
                                    Spacer()
                                    ProBadge()
                                }
                            }
                            .accessibilityIdentifier("addToChat.skillsRow")
                        }
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("Add to Chat")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("addToChat.close")
                }
            }
        }
        .tint(Palette.textPrimary.color)
        .paywall($paywall)
        // CONN-01: the admin may require consent before queries go to the search provider.
        .alert("Turn on web search?", isPresented: $confirmingWebSearch) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On") { model.set(.webSearch, on: true) }
        } message: {
            Text(model.services.webSearchConfirmation ?? "")
        }
        // PLAT-06: the stacked tiles need the full height at the accessibility sizes.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationBackground(Palette.background.color)
        .accessibilityIdentifier("addToChat")
    }

    private func set(_ feature: FeatureToggle, on: Bool) {
        if feature == .webSearch, on, model.services.webSearchConfirmation != nil {
            confirmingWebSearch = true
        } else {
            model.set(feature, on: on)
        }
    }

    private struct TileSpec {
        let picker: ComposerView.Picker
        let title: String
        let symbol: String
    }

    private var tiles: [TileSpec] {
        var tiles: [TileSpec] = []
        if model.canAttachPhotos, CameraPicker.isAvailable {
            tiles.append(TileSpec(picker: .camera, title: "Camera", symbol: "camera"))
        }
        if model.canAttachPhotos {
            tiles.append(TileSpec(picker: .photos, title: "Photos", symbol: "photo"))
        }
        if model.canAttachFiles {
            tiles.append(TileSpec(picker: .files, title: "Files", symbol: "doc.badge.arrow.up"))
        }
        return tiles
    }
}

/// Under the Code execution switch in the free tier (ADR 0173): today's free code execution runs, and
/// "Unlimited with Pro" to the paywall.
private struct SandboxAllowanceRow: View {
    let summary: String
    let isExhausted: Bool
    let unlock: () -> Void

    var body: some View {
        Button(action: unlock) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    summaryText.fixedSize()
                    Spacer(minLength: Spacing.s)
                    unlockText.fixedSize()
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    summaryText.fixedSize(horizontal: false, vertical: true)
                    unlockText
                }
            }
        }
        .accessibilityIdentifier("addToChat.sandboxAllowance")
    }

    private var summaryText: some View {
        Text(ui: summary)
            .font(Typography.callout)
            .foregroundStyle(isExhausted ? Palette.textPrimary.color : Palette.textSecondary.color)
    }

    private var unlockText: some View {
        Text("Unlimited with Pro")
            .font(Typography.callout.weight(.medium))
            .foregroundStyle(Palette.accent.color)
    }
}

private struct Tile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.s) {
                // One icon height for every tile, so the labels share a baseline (the Files
                // glyph is taller than the camera and photo ones).
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Text(title).font(Typography.body)
            }
            .foregroundStyle(Palette.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.large))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct IconValueRow: View {
    let title: String
    let systemImage: String
    let value: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // #149: at the accessibility sizes the value goes under the title, so the title keeps the
        // row's width and wraps between words instead of inside one ("Choo / se style").
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                label
                if let value {
                    Text(ui: value).foregroundStyle(Palette.textSecondary.color)
                }
            }
        } else {
            HStack {
                label
                Spacer()
                if let value {
                    Text(ui: value).foregroundStyle(Palette.textSecondary.color)
                }
            }
        }
    }

    private var label: some View {
        Label {
            Text(ui: title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(Palette.textPrimary.color)
    }
}

/// A placeholder for rows another Feature area will own.
struct ComingSoonPage: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 48, height: 48)
                .background(Palette.recessedSurface.color, in: .circle)
            Text(title).font(Typography.headline)
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.color)
        .navigationTitle(title)
        .inlineTitle()
        .accessibilityIdentifier("addToChat.comingSoon")
    }
}

extension FeatureToggle {
    var title: String {
        switch self {
        case .webSearch: "Web search"
        case .imageGeneration: "Image creation"
        case .codeInterpreter: "Code execution"
        }
    }

    var symbol: String {
        switch self {
        case .webSearch: "globe"
        case .imageGeneration: "paintbrush"
        case .codeInterpreter: "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Camera (ATT-03)

#if os(iOS)
/// The system camera (Retake / Use Photo). Hands back JPEG bytes, or `nil` when cancelled.
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    static func filename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Photo \(formatter.string(from: now)).jpg"
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#else
struct CameraPicker {
    static var isAvailable: Bool { false }
    static func filename(now: Date = Date()) -> String { "Photo.jpg" }
}
#endif
