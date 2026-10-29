public import DesignSystem
public import SwiftUI

/// An empty state at a threshold (brand.md §4, BRAND-04): a framed work with its plaque, the pixel
/// mouse underneath it (on the plaque, never inside the painting), a New York headline and a hint.
/// "The library is quiet." over Yi Taek-gyun's shelves; the Projects list over Lorrain; Memory over
/// Dürer's study.
///
/// It scrolls when it doesn't fit (accessibility sizes, landscape) and is centred otherwise. Put it
/// where the list would be; it fills the space offered.
public struct ArtworkEmptyState<Actions: View>: View {
    private let artwork: Artwork
    private let frameHeight: CGFloat
    private let focal: UnitPoint?
    private let pose: PixelMouse.Pose
    private let title: Text
    private let message: Text?
    private let actions: Actions

    /// - Parameters:
    ///   - frameHeight: The frame's height; the crop (a detail) keeps the work's focal point.
    ///   - focal: Overrides the work's focal point for this crop.
    ///   - pose: `.sleep` for empty lists, `.read` for Memory.
    public init(
        _ artwork: Artwork,
        frameHeight: CGFloat = 160,
        focal: UnitPoint? = nil,
        pose: PixelMouse.Pose = .sleep,
        title: Text,
        message: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.artwork = artwork
        self.frameHeight = frameHeight
        self.focal = focal
        self.pose = pose
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                FramedArtwork(artwork, height: frameHeight, focal: focal, mat: 6)
                Plaque(artwork, style: .short)
            }
            PixelMouse(pose: pose, scale: 3)
                .mouseBackdrop()
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.xs)
            VStack(spacing: Spacing.xs) {
                title
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary.color)
                if let message {
                    message
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            actions
                .padding(.top, Spacing.s)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .frame(maxWidth: 420)
    }
}

extension ArtworkEmptyState where Actions == EmptyView {
    public init(
        _ artwork: Artwork,
        frameHeight: CGFloat = 160,
        focal: UnitPoint? = nil,
        pose: PixelMouse.Pose = .sleep,
        title: Text,
        message: Text? = nil
    ) {
        self.init(artwork, frameHeight: frameHeight, focal: focal, pose: pose, title: title, message: message) { EmptyView() }
    }
}

#Preview("Library empty") {
    ArtworkEmptyState(
        .libraryEmpty,
        title: Text(verbatim: "The library is quiet."),
        message: Text(verbatim: "Your conversations will be shelved here.")
    )
    .themedBackground()
}

#Preview("Projects empty (dark)") {
    ArtworkEmptyState(.projectsEmpty, title: Text(verbatim: "No projects yet")) {
        Button("New project") {}.buttonStyle(.bordered)
    }
    .themedBackground()
    .preferredColorScheme(.dark)
}
