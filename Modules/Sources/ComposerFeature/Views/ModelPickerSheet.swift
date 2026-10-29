import DesignSystem
import OpenWebUIKit
import SwiftUI

/// "Select model" (MODEL-01): the primary models with a one-line description and a check on the
/// current one, a greyed row for a Chat model the Server no longer offers, then the Effort row
/// (MODEL-02) and More models (MODEL-03).
struct ModelPickerSheet: View {
    let model: ComposerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                let catalog = model.services.catalog
                Section {
                    if let missing = model.unavailableModelID {
                        UnavailableModelRow(modelID: missing)
                    }
                    ForEach(catalog.primary) { option in
                        ModelRow(option: option, isSelected: option.id == model.selectedModelID, isDefault: isDefault(option)) {
                            choose(option)
                        }
                    }
                }
                .listRowBackground(Palette.recessedSurface.color)
                if let effort = model.effort {
                    Section {
                        NavigationLink {
                            EffortPage(model: model)
                        } label: {
                            ValueRow(title: effort.hasEffortLevels ? "Effort" : "Model options", value: effort.level(in: model.effortSelection)?.label)
                        }
                        .accessibilityIdentifier("modelPicker.effort")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                if !catalog.more.isEmpty {
                    Section {
                        NavigationLink {
                            MoreModelsPage(model: model) { dismiss() }
                        } label: {
                            ValueRow(
                                title: "More models",
                                value: catalog.isInMore(model.selectedModelID) ? model.selectedModel?.name : nil
                            )
                        }
                        .accessibilityIdentifier("modelPicker.more")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
            }
            .modifier(SheetListStyle())
            .navigationTitle("Select model")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("modelPicker.close")
                }
            }
        }
        .tint(Palette.textPrimary.color)
        // A partial detent: the native iOS 26 sheet floats inset with corners
        // concentric with the display's, and morphs edge to edge when pulled to large (ADR 0130).
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationBackground(Palette.background.color)
        .accessibilityIdentifier("modelPicker")
    }

    private func isDefault(_ option: Model) -> Bool {
        if let setting = model.services.defaultModelSetting { return option.id == setting }
        return model.services.adminDefaultModelIDs.first == option.id
    }

    private func choose(_ option: Model) {
        model.select(option.id)
        dismiss()
    }
}

/// "More models" (MODEL-03): the models outside the primary list.
struct MoreModelsPage: View {
    let model: ComposerModel
    let onChoose: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(model.services.catalog.more) { option in
                    ModelRow(option: option, isSelected: option.id == model.selectedModelID, isDefault: false) {
                        model.select(option.id)
                        onChoose()
                    }
                }
            }
            .listRowBackground(Palette.recessedSurface.color)
        }
        .modifier(SheetListStyle())
        .navigationTitle("More models")
        .inlineTitle()
        .accessibilityIdentifier("modelPicker.morePage")
    }
}

/// Effort (MODEL-02): the levels as a radio list with a caption, the Thinking switch, and any
/// further admin-defined options.
struct EffortPage: View {
    let model: ComposerModel

    var body: some View {
        List {
            if let effort = model.effort {
                let selection = model.effortSelection
                if let key = effort.effortKey, effort.hasEffortLevels {
                    Section {
                        ForEach(effort.levels) { level in
                            OptionRow(
                                title: level.label,
                                detail: level.detail,
                                badge: level.id == effort.defaultLevelID && effort.source == .modelControls ? "Default" : nil,
                                isSelected: effort.level(in: selection)?.id == level.id
                            ) {
                                model.setEffort(level.id, for: key)
                            }
                            .accessibilityIdentifier("effort.level.\(level.id)")
                        }
                    } footer: {
                        Text("More effort gives more thorough responses, which take longer.")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                if let thinking = effort.thinking, let on = thinking.onOption, let off = thinking.offOption {
                    Section {
                        Toggle(isOn: Binding(
                            get: { effort.isThinkingOn(in: model.effortSelection) },
                            set: { model.setEffort($0 ? on.id : off.id, for: thinking.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thinking.label).font(Typography.body)
                                Text(thinking.description ?? "Reasons before answering harder questions")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary.color)
                            }
                        }
                        .tint(Palette.accent.color)
                        .accessibilityIdentifier("effort.thinking")
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
                ForEach(effort.extras) { control in
                    Section {
                        ForEach(control.options) { option in
                            OptionRow(
                                title: option.label,
                                detail: nil,
                                badge: option.id == control.defaultOptionID ? "Default" : nil,
                                isSelected: (selection.picks[control.id] ?? control.defaultOptionID) == option.id
                            ) {
                                model.setEffort(option.id, for: control.id)
                            }
                        }
                    } header: {
                        Text(control.label)
                    } footer: {
                        if let description = control.description { Text(ui: description) }
                    }
                    .listRowBackground(Palette.recessedSurface.color)
                }
            }
        }
        .modifier(SheetListStyle())
        // PLAT-02: a selection tick for each Effort change.
        .hapticCue(.selection, trigger: model.effortSelection)
        .navigationTitle(model.effort?.hasEffortLevels == false ? "Model options" : "Effort")
        .inlineTitle()
        .accessibilityIdentifier("effortPage")
    }
}

struct ModelRow: View {
    let option: Model
    let isSelected: Bool
    let isDefault: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.s) {
                        Text(option.name)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary.color)
                        if isDefault { Badge(text: "Default") }
                    }
                    if let subtitle = option.pickerSubtitle {
                        Text(ui: subtitle)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                            // PLAT-06: the whole description at the accessibility sizes.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    }
                }
                Spacer(minLength: Spacing.s)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent.color)
                        .transition(.symbolEffect(.appear))
                }
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("modelPicker.model.\(option.id)")
    }
}

/// A Chat's model that the Server doesn't offer any more: greyed, with a badge, not selectable.
private struct UnavailableModelRow: View {
    let modelID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.s) {
                Text(modelID).font(Typography.body)
                Badge(text: "Unavailable")
            }
            Text("This Server no longer offers this model.")
                .font(Typography.callout)
        }
        .foregroundStyle(Palette.textTertiary.color)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelPicker.unavailable")
    }
}

private struct OptionRow: View {
    let title: String
    let detail: String?
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.s) {
                        Text(title).font(Typography.body).foregroundStyle(Palette.textPrimary.color)
                        if let badge { Badge(text: badge) }
                    }
                    if let detail {
                        Text(ui: detail).font(Typography.callout).foregroundStyle(Palette.textSecondary.color)
                    }
                }
                Spacer(minLength: Spacing.s)
                if isSelected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accent.color)
                        .transition(.symbolEffect(.appear))
                }
            }
            // MODEL-02: the check moves to the picked Effort.
            .motionSafeAnimation(Motion.snappy, value: isSelected)
            .padding(.vertical, Spacing.xxs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ValueRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Text(title).font(Typography.body).foregroundStyle(Palette.textPrimary.color)
            Spacer()
            if let value {
                Text(value).font(Typography.body).foregroundStyle(Palette.textSecondary.color)
            }
        }
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(Palette.textSecondary.color)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 2)
            .background(Palette.background.color.opacity(0.8), in: .capsule)
    }
}

/// Inset-grouped rounded rows on the warm canvas, like every settings-like sheet.
struct SheetListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(Palette.background.color)
    }
}

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
