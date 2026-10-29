import DesignSystem
import SwiftUI

/// Three theme thumbnails (Light, Dark, System) with the selection outlined (SET-02). Picking one
/// re-themes the whole app at once.
struct AppearancePicker: View {
    @Binding var selection: Appearance

    var body: some View {
        HStack(spacing: Spacing.m) {
            ForEach(Appearance.allCases) { appearance in
                Button {
                    selection = appearance
                } label: {
                    VStack(spacing: Spacing.s) {
                        AppearanceThumbnail(appearance: appearance)
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.medium)
                                    .strokeBorder(
                                        selection == appearance ? Palette.accent.color : Palette.separator.color,
                                        lineWidth: selection == appearance ? 2.5 : 1
                                    )
                            }
                        Text(appearance.title)
                            .font(Typography.callout)
                            .foregroundStyle(selection == appearance ? Palette.accent.color : Palette.textPrimary.color)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appearance.title)
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
                .accessibilityIdentifier("settings.appearance.\(appearance.rawValue)")
            }
        }
        .padding(.vertical, Spacing.s)
        .hapticFeedback(.selection, trigger: selection)
    }
}

/// A miniature of the app in one scheme: a card with two text lines and the accent dot, in the
/// palette's fixed light or dark values (plaster and gesso, nocturne and slate; brand.md §1), so
/// each thumbnail shows its scheme whatever the current one is. The dot is the current accent
/// (#179), read in `body` so it follows the choice.
private struct AppearanceThumbnail: View {
    let appearance: Appearance

    private typealias Colors = (canvas: Color, card: Color, line: Color, accent: Color)

    var body: some View {
        let accent = Palette.accent
        let light: Colors = (
            Palette.background.light.color, Palette.surface.light.color,
            Palette.textTertiary.light.color.opacity(0.55), accent.light.color
        )
        let dark: Colors = (
            Palette.background.dark.color, Palette.surface.dark.color,
            Palette.textTertiary.dark.color.opacity(0.8), accent.dark.color
        )
        ZStack {
            switch appearance {
            case .light: miniature(light)
            case .dark: miniature(dark)
            case .system:
                miniature(light)
                miniature(dark)
                    .mask { DiagonalHalf() }
            }
        }
        .aspectRatio(1.45, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.medium))
        .accessibilityHidden(true)
    }

    private func miniature(_ colors: Colors) -> some View {
        colors.canvas.overlay {
            RoundedRectangle(cornerRadius: Radius.small)
                .fill(colors.card)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(colors.line).frame(width: 34, height: 3)
                        Capsule().fill(colors.line).frame(width: 22, height: 3)
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(colors.accent).frame(width: 10, height: 10).padding(8)
                }
                .padding(6)
        }
    }
}

/// The lower-right triangle of a rectangle.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
