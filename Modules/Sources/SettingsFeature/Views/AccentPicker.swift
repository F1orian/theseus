import DesignSystem
import SwiftUI

/// "Accent colour" (#179): one swatch per `AccentChoice`, a circle in the pigment with its name
/// below, the current one ringed and ticked. Picking one recolours the whole app at once (ADR 0145).
/// The swatches use each pigment's own tokens, so they follow light, dark and Increase Contrast.
/// At the accessibility text sizes they stack as rows, the name beside the circle.
struct AccentPicker: View {
    @Binding var selection: AccentChoice
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.m))
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ui: "Accent colour")
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            layout {
                ForEach(AccentChoice.allCases) { choice in
                    AccentSwatch(choice: choice, isSelected: selection == choice, isLarge: isLarge) {
                        selection = choice
                    }
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .hapticFeedback(.selection, trigger: selection)
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let isLarge: Bool
    let select: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 36

    var body: some View {
        Button(action: select) {
            let layout = isLarge
                ? AnyLayout(HStackLayout(spacing: Spacing.m))
                : AnyLayout(VStackLayout(spacing: Spacing.s))
            layout {
                circle
                Text(ui: choice.displayName)
                    .font(Typography.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Palette.textPrimary.color)
                    .multilineTextAlignment(isLarge ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
                if isLarge { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ui: "\(choice.displayName), accent colour"))
        .accessibilityValue(isSelected ? Text(ui: "selected") : Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("settings.accent.\(choice.rawValue)")
    }

    /// The pigment, ringed (a gap of the row's surface between) and ticked when it's current.
    private var circle: some View {
        let tokens = choice.tokens
        let size = min(diameter, 56)
        return Circle()
            .fill(tokens.accent.color)
            .frame(width: size, height: size)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(tokens.onAccent.color)
                }
            }
            .padding(4)
            .overlay {
                Circle().strokeBorder(isSelected ? tokens.accent.color : .clear, lineWidth: 2.5)
            }
    }
}

#Preview("Accent colour") {
    @Previewable @State var selection = AccentChoice.ultramarine
    List {
        Section("Appearance") {
            AccentPicker(selection: $selection)
        }
    }
}
