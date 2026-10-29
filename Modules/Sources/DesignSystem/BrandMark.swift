public import SwiftUI

/// The Theseus mark: the pixel mouse (ADR 0140; it replaced the labyrinth rings). It draws the
/// mouse at the largest whole-number scale that fits the frame you give it, centred, so it stays
/// crisp at any size. Decorative: hidden from accessibility.
///
/// - `BrandMark()`: the `head`, for small places (widgets, headers, the splash).
/// - `BrandMark(showsRoute: true)`: the illustration variant for welcome screens, the mouse
///   `stand`ing to say hello. (The name is kept from the labyrinth, whose way in it drew.)
public struct BrandMark: View {
    private let pose: PixelMouse.Pose

    /// - Parameter showsRoute: The larger illustration variant (the standing mouse) used on the
    ///   welcome screen, rather than the head.
    public init(showsRoute: Bool = false) {
        pose = showsRoute ? .stand : .head
    }

    /// A mark in a specific pose (e.g. `.sit` beside a wordmark).
    public init(pose: PixelMouse.Pose) {
        self.pose = pose
    }

    public var body: some View {
        GeometryReader { proxy in
            PixelMouse(pose: pose, scale: PixelMouse.largestScale(for: pose, fitting: proxy.size))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(CGFloat(pose.sprite.width) / CGFloat(max(pose.sprite.height, 1)), contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mouse next to the "Theseus" wordmark in New York (splash, welcome and sign-in headers).
/// `size` is the wordmark's cap-to-baseline scale, as before: the mouse sits at about that height.
public struct BrandLockup: View {
    private let size: CGFloat
    private let pose: PixelMouse.Pose

    /// - Parameters:
    ///   - size: The lockup's height in points; the wordmark is set at `size × 1.1`.
    ///   - pose: `.sit` (default) or `.head`.
    public init(size: CGFloat = 28, pose: PixelMouse.Pose = .sit) {
        self.size = size
        self.pose = pose
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.3) {
            PixelMouse(pose: pose, scale: Self.scale(for: pose, size: size))
                .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
            Text("Theseus")
                .font(.system(size: size * 1.1, weight: .regular, design: .serif))
                .foregroundStyle(Palette.textPrimary.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theseus")
    }

    /// Whole points per pixel so the mouse is about `size` tall (at least 1).
    nonisolated static func scale(for pose: PixelMouse.Pose, size: CGFloat) -> Int {
        max(Int((size / CGFloat(max(pose.sprite.height, 1))).rounded()), 1)
    }
}

#Preview("Lockup and marks") {
    VStack(spacing: 32) {
        BrandLockup()
        BrandLockup(size: 40)
        BrandLockup(size: 26, pose: .head)
        HStack(spacing: 24) {
            BrandMark().frame(width: 22, height: 22)
            BrandMark().frame(width: 28, height: 28)
            BrandMark().frame(width: 56, height: 56)
        }
        BrandMark(showsRoute: true).frame(width: 200, height: 200)
    }
    .padding()
    .themedBackground()
}
