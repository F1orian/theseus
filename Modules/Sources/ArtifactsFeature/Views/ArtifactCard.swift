import DesignSystem
import SwiftUI

extension Artifact.Kind {
    /// The SF Symbol on the card's tile.
    var symbol: String {
        switch self {
        case .webPage: "macwindow"
        case .image: "photo"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .component: "atom"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension Artifact {
    var symbol: String { origin == .toolEmbed ? "wrench.and.screwdriver" : kind.symbol }

    /// "Interactive artifact · Version 2", or "Writing…" while it streams.
    var subtitle: String {
        if !isComplete { return "Writing…" }
        return version > 1 ? "\(typeLabel) · Version \(version)" : typeLabel
    }
}

/// An Artifact in the transcript (ART-01): title, type and version, and a tilted tile with the
/// kind's symbol. Tapping opens the viewer.
struct ArtifactCard: View {
    let artifact: Artifact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(artifact.title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: Spacing.xs) {
                        if !artifact.isComplete {
                            ProgressView().controlSize(.mini)
                        }
                        Text(artifact.subtitle)
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    // "Writing…" → "Interactive artifact · Version 2" once it's complete.
                    .motionSafeAnimation(Motion.smooth, value: artifact.isComplete)
                }
                Spacer(minLength: Spacing.s)
                ArtifactTile(symbol: artifact.symbol)
            }
            .padding(.leading, Spacing.l)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(Palette.surface.color, in: .rect(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
            .clipShape(.rect(cornerRadius: Radius.medium))
            .contentShape(.rect(cornerRadius: Radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artifact.title), \(artifact.subtitle)")
        .accessibilityHint("Opens the artifact")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("artifact.card")
    }
}

/// The page-like tile peeking out of the card's trailing edge.
struct ArtifactTile: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.small)
            .fill(Palette.background.color)
            .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Palette.separator.color))
            .overlay {
                // Centred in the part of the tile the card doesn't clip.
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Palette.textSecondary.color)
                    .offset(x: -2, y: -8)
            }
            .frame(width: 76, height: 84)
            .rotationEffect(.degrees(3), anchor: .bottomLeading)
            .offset(x: 4, y: 14)
            .accessibilityHidden(true)
    }
}

/// A small icon tile for lists (the Chat's Artifacts, the library).
struct ArtifactIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17))
            .foregroundStyle(Palette.textSecondary.color)
            .frame(width: 40, height: 40)
            .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.small))
            .accessibilityHidden(true)
    }
}

#Preview("Artifact cards") {
    VStack(spacing: Spacing.l) {
        ForEach(ArtifactPreviewData.catalog.artifacts) { artifact in
            ArtifactCard(artifact: artifact) {}
        }
        ArtifactCard(artifact: ArtifactPreviewData.writing) {}
    }
    .padding()
    .themedBackground()
}
