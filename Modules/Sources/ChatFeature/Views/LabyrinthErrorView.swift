import ArtCollection
import DesignSystem
import SwiftUI

/// The full-screen error (brand.md §4: error / offline / server unreachable): Piranesi's
/// *Drawbridge* in its frame with the mouse `peek`ing over the top edge, "Lost in the labyrinth.",
/// what went wrong (naming the Server), and the one primary action, "Try again". Errors inside
/// the transcript stay compact (`ResponseErrorView`).
struct LabyrinthErrorView: View {
    let message: String
    let onRetry: () -> Void

    /// The peeking mouse's scale; its ledge (the sprite's bottom rows) rests on the frame's rule
    /// and mat, never on the painting.
    static let mouseScale = 3
    static let mat: CGFloat = 6
    static let frameHeight: CGFloat = 200

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    framed
                    Plaque(.error, style: .short)
                        .padding(.top, Spacing.m)
                    Text(ui: "Lost in the labyrinth.")
                        .font(Typography.display)
                        .foregroundStyle(Palette.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Spacing.xl)
                    Text(message)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, Spacing.s)
                    Button("Try again", action: onRetry)
                        .buttonStyle(.accentPill)
                        .padding(.top, Spacing.xl)
                        .accessibilityIdentifier("conversation.retryLoad")
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.horizontal, Spacing.xl - 2)
                .padding(.vertical, Spacing.xxl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var framed: some View {
        let mouse = PixelMouse.size(of: .peek, scale: Self.mouseScale)
        // The ledge overlaps exactly the gilt rule and the mat.
        let overlap = FramedArtwork.ruleWidth + Self.mat
        return FramedArtwork(.error, height: Self.frameHeight, mat: Self.mat)
            .padding(.top, mouse.height - overlap)
            .overlay(alignment: .top) {
                PixelMouse(pose: .peek, scale: Self.mouseScale)
            }
    }
}

#Preview("Lost in the labyrinth") {
    LabyrinthErrorView(message: "chat.example.com isn't answering. Try again in a moment.") {}
        .themedBackground()
}
