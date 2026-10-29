public import SwiftUI

/// "Nothing here yet" with the pixel mouse (brand.md §3–4, BRAND-04): the mouse in `pose`
/// (`.sleep` for empty lists, `.sit` for a quiet page), a New York headline and a one-line hint,
/// centred, with optional actions underneath. For screens without a painting (Connectors, the
/// sandbox, Settings pages); `ArtworkEmptyState` (ArtCollection) adds a framed work above it.
///
/// The mouse sits on its backdrop (`mouseBackdrop()`, #192), a soft lighter ellipse that lifts its
/// umber outline off the dark background and draws nothing in light mode. Title and message read as one
/// VoiceOver element; the mouse is decorative.
public struct MouseEmptyState<Actions: View>: View {
    private let pose: PixelMouse.Pose
    private let scale: Int
    private let title: Text
    private let message: Text?
    private let actions: Actions

    /// - Parameters:
    ///   - pose: Usually `.sleep` (nothing here) or `.sit`.
    ///   - scale: Points per sprite pixel (3 for full-screen states, 2 inside a list).
    public init(
        pose: PixelMouse.Pose = .sleep,
        scale: Int = 3,
        title: Text,
        message: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.pose = pose
        self.scale = scale
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Spacing.s) {
            PixelMouse(pose: pose, scale: scale)
                .mouseBackdrop()
                .padding(.bottom, Spacing.s)
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
        .padding(Spacing.xl)
        .frame(maxWidth: 420)
    }
}

extension MouseEmptyState where Actions == EmptyView {
    public init(pose: PixelMouse.Pose = .sleep, scale: Int = 3, title: Text, message: Text? = nil) {
        self.init(pose: pose, scale: scale, title: title, message: message) { EmptyView() }
    }
}

#Preview("Mouse empty states") {
    VStack(spacing: Spacing.xxl) {
        MouseEmptyState(pose: .sleep, title: Text(verbatim: "No connectors yet"), message: Text(verbatim: "Your Server admin can add them."))
        MouseEmptyState(pose: .sit, scale: 2, title: Text(verbatim: "No shared links"), message: Text(verbatim: "Chats you share appear here.")) {
            Button("Try again") {}.buttonStyle(.bordered)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .themedBackground()
}
