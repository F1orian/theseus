import DesignSystem
import SwiftUI

/// The round check confirm in a page or sheet header. It fills only when there are changes
/// (Visual language: "the confirm turns filled black when there are changes").
struct ConfirmButton: View {
    let hasChanges: Bool
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        if isSaving {
            ProgressView()
        } else if hasChanges {
            Button("Save", systemImage: "checkmark", action: action)
                .buttonStyle(.glassProminent)
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("personalization.save")
        } else {
            Button("Save", systemImage: "checkmark", action: action)
                .disabled(true)
                .accessibilityIdentifier("personalization.save")
        }
    }
}

/// A dismissible error line docked at the bottom of a page or sheet.
struct ErrorBanner: View {
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
        .accessibilityIdentifier("personalization.error")
    }
}

extension View {
    /// The grouped-row surface used by Settings cards.
    func cardRowBackground() -> some View {
        listRowBackground(Palette.surface.color)
    }

    /// A grouped list on the warm canvas, like the Settings pages.
    func groupedCardList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .themedBackground()
        #else
        scrollContentBackground(.hidden)
            .themedBackground()
        #endif
    }

    func inlineNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        navigationTitle(title)
        #endif
    }

    /// Docks `message` as an error banner at the bottom.
    func errorBanner(_ message: String?, dismiss: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom) {
            if let message {
                ErrorBanner(message: message, dismiss: dismiss)
            }
        }
    }
}
