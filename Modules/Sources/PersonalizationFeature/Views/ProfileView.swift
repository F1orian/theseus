import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The Profile page (PERS-01): Full name and Nickname in one card, then the Instructions field
/// (PERS-02) when the Account may set it. The check button in the header saves.
public struct ProfileView: View {
    @State private var model: ProfileModel

    public init(model: ProfileModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        List {
            Section {
                ProfileField(title: "Full name", text: $model.fullName, prompt: "Your name")
                    .nameContentType()
                    .accessibilityIdentifier("profile.fullName")
                ProfileField(title: "Nickname", text: $model.nickname, prompt: "Optional")
                    .accessibilityIdentifier("profile.nickname")
            } footer: {
                Text("The home screen greets you by this name.")
            }
            if model.showsInstructions {
                Section {
                    TextField(
                        "Instructions",
                        text: $model.instructions,
                        prompt: Text("For example: keep answers short and use metric units."),
                        axis: .vertical
                    )
                    .lineLimit(1...8)
                    .font(Typography.body)
                    .cardRowBackground()
                    .accessibilityIdentifier("profile.instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Your instructions apply to all your chats on this Server.")
                }
            }
        }
        .groupedCardList()
        .disabled(!model.isLoaded)
        .overlay {
            if model.isLoading, !model.isLoaded { ProgressView() }
        }
        .errorBanner(model.errorMessage) { model.dismissError() }
        .inlineNavigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(hasChanges: model.canSave, isSaving: model.isSaving) {
                    Task { await model.save() }
                }
            }
        }
        .task {
            if !model.isLoaded { await model.load() }
        }
        .accessibilityIdentifier("personalization.profile")
    }
}

/// A grey leading label with a trailing, right-aligned text field (the Profile card).
private struct ProfileField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Palette.textPrimary.color)
                .submitLabel(.done)
        } label: {
            Text(title).foregroundStyle(Palette.textSecondary.color)
        }
        .font(Typography.body)
        .cardRowBackground()
    }
}

/// The Instructions page (PERS-02): a full-height editor for Instructions that apply to all Chats.
public struct InstructionsView: View {
    @State private var model: InstructionsModel
    @FocusState private var isFocused: Bool

    public init(model: InstructionsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("For example: keep answers short, explain code step by step, and use metric units.")
                        .foregroundStyle(Palette.textTertiary.color)
                        .padding(.horizontal, Spacing.xs + 1)
                        .padding(.vertical, Spacing.s)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .accessibilityIdentifier("instructions.editor")
            }
            .font(Typography.body)
            .padding(Spacing.m)
            .frame(maxHeight: .infinity)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
            Text("Your instructions apply to all your chats on this Server, in Theseus and in the web app.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .padding(.horizontal, Spacing.l)
        }
        .padding(Spacing.l)
        .themedBackground()
        .disabled(!model.isLoaded)
        .errorBanner(model.errorMessage) { model.dismissError() }
        .inlineNavigationTitle("Instructions")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(hasChanges: model.hasChanges, isSaving: model.isSaving) {
                    isFocused = false
                    Task { await model.save() }
                }
            }
        }
        .task {
            if !model.isLoaded { await model.load() }
        }
    }
}

extension View {
    fileprivate func nameContentType() -> some View {
        #if os(iOS)
        textContentType(.name)
        #else
        self
        #endif
    }
}
