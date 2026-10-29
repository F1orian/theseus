import ArtCollection
import DesignSystem
import OpenWebUIKit
import SwiftUI

/// One Project in the Projects grid (PROJ-01, BRAND-04): its cover in a thin frame, the name and
/// the work's compact plaque ("COROT · C. 1830"). One VoiceOver element, a button.
struct ProjectCard: View {
    let project: Project
    let cover: Artwork
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            FramedArtwork(cover, height: dynamicTypeSize.isAccessibilitySize ? 160 : 112, mat: 4)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(project.name)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if project.isStarred {
                        Image(systemName: "star.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary.color)
                            .accessibilityLabel("Starred")
                            .transition(.symbolEffect(.appear))
                    }
                }
                Plaque(cover, style: .compact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .motionSafeAnimation(Motion.bouncy, value: project.isStarred)
        .accessibilityElement(children: .combine)
    }
}

/// "Change cover" (BRAND-04): every `project-cover` work, framed with its plaque; the current one
/// is ringed and ticked, the Project's default is marked. The choice stays on this device.
struct ChangeCoverSheet: View {
    let covers: ProjectCovers
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 140), spacing: Spacing.l, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.xl) {
                    ForEach(covers.choices) { artwork in
                        choice(artwork)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.s)
                Text("Covers come from The Collection and stay on this device.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.l)
            }
            .themedBackground()
            .sheetChrome(
                title: "Change cover",
                canConfirm: false,
                confirmIdentifier: "project.cover.confirm",
                onClose: { dismiss() },
                onConfirm: nil
            )
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project.cover.sheet")
    }

    private func choice(_ artwork: Artwork) -> some View {
        let isCurrent = covers.cover(for: project.id) == artwork
        let isDefault = Artwork.projectCover(for: project.id) == artwork
        return Button {
            covers.setCover(artwork, for: project.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                FramedArtwork(artwork, height: 100, mat: 4)
                    .padding(Spacing.xs)
                    .overlay {
                        // The selection ring sits outside the frame, never on the painting.
                        RoundedRectangle(cornerRadius: Radius.small)
                            .strokeBorder(isCurrent ? Palette.accent.color : .clear, lineWidth: 2)
                    }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(artwork.title)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textPrimary.color)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(Typography.callout.weight(.semibold))
                            .foregroundStyle(Palette.accent.color)
                    }
                }
                Plaque(artwork, style: .compact)
                if isDefault {
                    Text("Default").plaqueStyle(color: Palette.textSecondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ui: "\(artwork.title), \(artwork.artist), \(artwork.date)\(isDefault ? ", default" : "")"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("project.cover.\(artwork.id)")
    }
}

/// The top of a Project's detail (BRAND-04): its cover as a short full-width hero, fading through a
/// scrim into the background, with the work's plaque under it. (An over-art caption would sit on
/// the sky of most covers, too light for white text in light mode.)
struct ProjectCoverHero: View {
    let cover: Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ArtworkHero(cover, height: 168, showsCaption: false)
            Plaque(cover, style: .short)
                .padding(.horizontal, Spacing.l)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.cover")
    }
}
