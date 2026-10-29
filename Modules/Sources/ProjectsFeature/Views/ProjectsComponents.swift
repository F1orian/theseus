import DesignSystem
public import SwiftUI

/// The floating primary pill ("+ New project"): verdigris, the screen's one accent (brand.md §1).
struct ProjectsPill: View {
    let title: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Typography.headline)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 48)
                .foregroundStyle(Palette.onAccent.color)
                .background(Palette.accent.color, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A centred empty state with the pixel mouse (brand.md §3): `.sleep` when there's nothing here,
/// `.peek` when something went wrong. The Projects list's own empty state adds Lorrain's painting
/// (`ArtworkEmptyState`).
struct ProjectsEmptyState: View {
    var pose: PixelMouse.Pose = .sleep
    let title: String
    let message: String

    var body: some View {
        MouseEmptyState(pose: pose, title: Text(title), message: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A list row: a title, a grey relative time and a chevron (Projects list, Project Chats, pickers).
struct TitleTimeRow: View {
    let title: String
    let date: Date
    var isStarred = false
    var showsChevron = true
    var isSelected = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                    .lineLimit(1)
                Text(date, format: .relative(presentation: .named, unitsStyle: .wide))
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer(minLength: Spacing.s)
            if isStarred {
                Image(systemName: "star.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
                    .accessibilityLabel("Starred")
                    .transition(.symbolEffect(.appear))
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                    .accessibilityLabel("Current project")
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(.rect)
        .motionSafeAnimation(Motion.bouncy, value: isStarred)
        .accessibilityElement(children: .combine)
    }
}

/// A labelled form field as in the create / Add text sheets: a grey question above a rounded input.
struct LabelledField<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(label)
                .font(Typography.callout.weight(.medium))
                .foregroundStyle(Palette.textSecondary.color)
                .padding(.horizontal, Spacing.l)
            field
        }
    }
}

/// A multiline input with a placeholder, styled like `fieldStyle()`.
struct MultilineField: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 140
    var identifier: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(Typography.body)
            .lineLimit(5...)
            .padding(Spacing.l)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color))
            .accessibilityIdentifier(identifier)
    }
}

/// A rounded single-line input for sheets.
struct SingleLineField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(Typography.body)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 50)
            .background(Palette.surface.color, in: .capsule)
            .overlay(Capsule().stroke(Palette.separator.color))
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// The sheet chrome Theseus uses everywhere: a round X on the left and a round check on the
    /// right that is only enabled when there is something to save.
    func sheetChrome(
        title: String,
        canConfirm: Bool,
        confirmIdentifier: String,
        onClose: @escaping () -> Void,
        onConfirm: (() -> Void)?
    ) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close, action: onClose)
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("sheet.close")
                }
                if let onConfirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm, action: onConfirm)
                            .tint(Palette.textPrimary.color)
                            .disabled(!canConfirm)
                            .accessibilityIdentifier(confirmIdentifier)
                    }
                }
            }
    }

    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Confirmations and failures from the Projects area: a dismissible card at the top of the screen
/// ("Chat moved to Meal plan", "You appear to be offline.").
public struct ProjectsNotice: View {
    private let library: ProjectLibrary

    public init(library: ProjectLibrary) {
        self.library = library
    }

    public var body: some View {
        if let message = library.errorMessage {
            card(message, symbol: "exclamationmark.circle", tint: Palette.destructive.color) { library.dismissError() }
                .accessibilityIdentifier("projects.error")
        } else if let notice = library.notice {
            card(notice, symbol: nil, tint: Palette.textPrimary.color) { library.dismissNotice() }
                .accessibilityIdentifier("projects.notice")
        }
    }

    private func card(_ text: String, symbol: String?, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Text(text)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, Spacing.l)
        .motionSafeTransition(.toast)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}

extension ToolbarItemPlacement {
    /// The leading edge of the navigation bar on iOS, `.navigation` elsewhere.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}
