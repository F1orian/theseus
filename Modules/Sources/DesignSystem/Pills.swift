public import SwiftUI

/// The full-width primary-action pill: black in light mode, white in dark mode ("Continue with …",
/// "Continue"). Use `.primary` for accent-filled actions instead.
public struct PillButtonStyle: ButtonStyle {
    public enum Prominence: Sendable {
        /// Filled with the primary text colour.
        case filled
        /// Outlined on the surface colour, for secondary choices.
        case outlined
        /// Filled with the verdigris `accent` (brand.md §1): the one primary action of a screen.
        case accent
    }

    @Environment(\.isEnabled) private var isEnabled
    private let prominence: Prominence

    public init(_ prominence: Prominence = .filled) {
        self.prominence = prominence
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.l)
            .foregroundStyle(foreground.color)
            .background(fill.color, in: .capsule)
            .overlay {
                if prominence == .outlined {
                    Capsule().stroke(Palette.separator.color)
                }
            }
            .contentShape(.capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }

    private var foreground: ColorToken {
        switch prominence {
        case .filled: Palette.background
        case .outlined: Palette.textPrimary
        case .accent: Palette.onAccent
        }
    }

    private var fill: ColorToken {
        switch prominence {
        case .filled: Palette.textPrimary
        case .outlined: Palette.surface
        case .accent: Palette.accent
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// Black (white in dark mode) full-width pill.
    public static var pill: PillButtonStyle { PillButtonStyle() }
    /// Outlined full-width pill on `surface`.
    public static var outlinedPill: PillButtonStyle { PillButtonStyle(.outlined) }
    /// Verdigris full-width pill, for the screen's one primary action.
    public static var accentPill: PillButtonStyle { PillButtonStyle(.accent) }
}

/// A capsule input on `surface` with an optional trailing accessory (submit arrow, spinner).
public struct PillField<Field: View, Accessory: View>: View {
    private let field: Field
    private let accessory: Accessory

    public init(@ViewBuilder field: () -> Field, @ViewBuilder accessory: () -> Accessory) {
        self.field = field()
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: Spacing.s) {
            field
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
            accessory
        }
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.xs + 2)
        .frame(minHeight: 52)
        .background(Palette.surface.color, in: .capsule)
        .overlay(Capsule().stroke(Palette.separator.color))
    }
}

extension PillField where Accessory == EmptyView {
    public init(@ViewBuilder field: () -> Field) {
        self.init(field: field) { EmptyView() }
    }
}

/// The round inline submit button that sits inside a `PillField` (an arrow, or a spinner while busy).
public struct InlineSubmitButton: View {
    private let isBusy: Bool
    private let isEnabled: Bool
    private let accessibilityLabel: String
    private let isAccent: Bool
    private let action: () -> Void

    /// - Parameter isAccent: Fill the arrow with the verdigris `accent` (the screen's primary
    ///   action) instead of the primary text colour.
    public init(
        isBusy: Bool,
        isEnabled: Bool,
        accessibilityLabel: String = "Continue",
        isAccent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.isAccent = isAccent
        self.action = action
    }

    public var body: some View {
        if isBusy {
            ProgressView()
                .frame(width: 42, height: 42)
                .accessibilityLabel("Working")
        } else if isEnabled {
            Button(action: action) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isAccent ? Palette.onAccent.color : Palette.background.color)
                    .frame(width: 42, height: 42)
                    .background(isAccent ? Palette.accent.color : Palette.textPrimary.color, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .transition(.scale.combined(with: .opacity))
        }
    }
}
