public import SwiftUI

/// The mouse backdrop (#192, brand.md §3): on dark surfaces a soft, lighter ellipse behind every
/// mouse, centred on the drawing and fading to nothing at its edge, so the umber outline lifts off
/// Nocturne without a line around the pixels. Light mode draws nothing.
///
/// Set it once on a screen and every mouse below gets one, sized to its own drawing: a pose, the
/// head, a pettable mouse, a working-mouse scene at either size.
///
/// ```swift
/// ConversationView(...).mouseBackdrop()
/// PixelMouse(pose: .sleep, scale: 3).mouseBackdrop()
/// ```
///
/// The backdrop draws outside the mouse's frame and is never clipped by it; it doesn't change the
/// layout and doesn't take touches. Under Reduce Transparency it's a solid, very quiet ellipse.
extension View {
    /// Draws `PixelMouse`'s dark-mode backdrop behind the mice below (`PixelMouse`,
    /// `PixelMouseRunning`, `WorkingMouse`, `PettableMouse`, and the lockups and marks built on
    /// them). Pass `false` to turn it off for a subtree.
    public func mouseBackdrop(_ isEnabled: Bool = true) -> some View {
        environment(\.mouseBackdrop, isEnabled)
    }
}

extension EnvironmentValues {
    /// Whether the mice below draw their dark-mode backdrop; off by default. Set it with
    /// `mouseBackdrop(_:)`.
    @Entry public var mouseBackdrop = false
}

extension PixelMouse {
    /// The backdrop's colour: Graphite (#4A505B), from the approved mock-up (#192, option B).
    nonisolated public static let backdropColor = RGBA(hex: 0x4A505B)
    /// The backdrop's opacity at its centre; it fades to 0 at the edge of the ellipse.
    nonisolated public static let backdropOpacity = 0.27
    /// The solid fill under Reduce Transparency: the gradient's average over Nocturne, about a tenth
    /// of Graphite, opaque.
    nonisolated public static let backdropSolid = RGBA(hex: 0x17191F)

    /// How far the backdrop's ellipse reaches past the drawing on each side: 8 sprite pixels,
    /// between 12 and 28 points (16 pt for the chat's 2-pt mice, 24 pt at 3 pt per pixel).
    nonisolated public static func backdropPadding(scale: Int) -> CGFloat {
        min(max(CGFloat(max(scale, 1) * 8), 12), 28)
    }

    /// What the backdrop draws for an appearance: nothing in light mode; in dark the gradient, or
    /// the solid fill under Reduce Transparency.
    enum BackdropFill: Equatable {
        case gradient
        case solid
    }

    nonisolated static func backdropFill(colorScheme: ColorScheme, reduceTransparency: Bool) -> BackdropFill? {
        guard colorScheme == .dark else { return nil }
        return reduceTransparency ? .solid : .gradient
    }

    /// The gradient's stops: `backdropOpacity` at the centre easing out to 0 at the edge, so it reads
    /// as the mock-up's blurred ellipse rather than a cone with a rim.
    nonisolated static var backdropStops: [Gradient.Stop] {
        let tint = backdropColor
        return [(0, 1), (0.3, 0.88), (0.55, 0.58), (0.8, 0.22), (1, 0)].map { location, share in
            Gradient.Stop(color: Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue, opacity: backdropOpacity * share), location: location)
        }
    }
}

/// Draws the backdrop behind a mouse drawn at `scale` points per pixel, when the environment asks
/// for it (`mouseBackdrop(_:)`). The content's frame, layout and hit-testing are unchanged.
struct MouseBackdropBackground: ViewModifier {
    let scale: Int
    @Environment(\.mouseBackdrop) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if isEnabled, let fill = PixelMouse.backdropFill(colorScheme: colorScheme, reduceTransparency: reduceTransparency) {
                let padding = PixelMouse.backdropPadding(scale: scale)
                Group {
                    switch fill {
                    case .gradient:
                        EllipticalGradient(stops: PixelMouse.backdropStops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    case .solid:
                        // A little inside the gradient's reach, where it's still visible.
                        Ellipse()
                            .fill(PixelMouse.backdropSolid.color)
                            .padding(padding * 0.4)
                    }
                }
                // Negative padding grows the background past the drawing without touching layout.
                .padding(-padding)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// The mouse backdrop behind a drawing at `scale` points per pixel (internal: the mouse views
    /// call it; screens use `mouseBackdrop(_:)`).
    func mouseBackdropBackground(scale: Int) -> some View {
        modifier(MouseBackdropBackground(scale: scale))
    }
}
