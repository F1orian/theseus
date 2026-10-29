import DesignSystem
public import SwiftUI

// MARK: FramedArtwork

/// An artwork in its frame (brand.md §4): a 2-pt `gilt` rule, a `frameInk` mat and a soft drop
/// shadow, the painting cropped around its focal point. Decorative (hidden from VoiceOver): put a
/// `Plaque` under it, or credit it on About › The Collection.
///
/// Sizing:
/// - `height` only: that height, as wide as offered (the crop keeps the focal point in view).
/// - `aspectRatio` only: the frame's width over height, fitted to the space offered.
/// - both: exactly `height` tall and `height × aspectRatio` wide.
/// - neither: the work's own proportions, uncropped.
public struct FramedArtwork: View {
    private let artwork: Artwork
    private let height: CGFloat?
    private let aspectRatio: CGFloat?
    private let focal: UnitPoint
    private let mat: CGFloat

    /// - Parameters:
    ///   - focal: Overrides the work's own focal point for this crop.
    ///   - mat: The dark inner frame's width (about 6 to 10 pt; 4 for thumbnails).
    public init(
        _ artwork: Artwork,
        height: CGFloat? = nil,
        aspectRatio: CGFloat? = nil,
        focal: UnitPoint? = nil,
        mat: CGFloat = 8
    ) {
        self.artwork = artwork
        self.height = height
        self.aspectRatio = aspectRatio
        self.focal = focal ?? artwork.focal
        self.mat = mat
    }

    /// The gilt rule's width.
    public static let ruleWidth: CGFloat = 2
    static let cornerRadius: CGFloat = 2

    public var body: some View {
        framed
            .modifier(FrameSizing(height: height, aspectRatio: aspectRatio, natural: naturalAspect))
            .background {
                // The board's `0 12px 30px -12px`: a shadow pulled in by its own spread, so it
                // grounds the frame without darkening the plaque just below it (whose text must
                // keep 4.5:1 on the background).
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(FramedArtwork.shadow)
                    .padding(12)
                    .offset(y: 12)
                    .blur(radius: 12)
            }
            .accessibilityHidden(true)
    }

    /// The frame's outer proportions when the painting is uncropped (mat included).
    private var naturalAspect: CGFloat { artwork.aspectRatio }

    private var framed: some View {
        ArtworkImage(artwork: artwork, focal: focal)
            .padding(mat)
            .background(Palette.frameInk.color)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Palette.gilt.color, lineWidth: Self.ruleWidth)
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
    }

    /// Ink, 35 % (brand board: `0 12px 30px -12px rgba(22,24,29,.35)`).
    static let shadow = Color(.sRGB, red: 22 / 255, green: 24 / 255, blue: 29 / 255, opacity: 0.35)
}

private struct FrameSizing: ViewModifier {
    let height: CGFloat?
    let aspectRatio: CGFloat?
    let natural: CGFloat

    func body(content: Content) -> some View {
        switch (height, aspectRatio) {
        case let (height?, aspect?):
            content.frame(width: height * aspect, height: height)
        case let (height?, nil):
            content.frame(maxWidth: .infinity).frame(height: height)
        case let (nil, aspect?):
            content.aspectRatio(aspect, contentMode: .fit)
        case (nil, nil):
            content.aspectRatio(natural, contentMode: .fit)
        }
    }
}

// MARK: Plaque

/// The credit for an artwork in Departure Mono (brand.md §4), in `textTertiary` with the title in
/// `textPrimary`. Every artwork shown anywhere has one, or is credited on About › The Collection.
/// It reads as one VoiceOver element.
public struct Plaque: View {
    public enum Style: Sendable, CaseIterable {
        /// "**View of Florence**, Thomas Cole, 1837 · Cleveland Museum of Art · CC0": under a frame.
        case full
        /// "**View of Florence**, Thomas Cole, 1837 · CC0": where space is tight (error, cards).
        case short
        /// "COLE · 1837": an uppercase label, e.g. on a Project cover.
        case compact
        /// "View of Florence · Thomas Cole · 1837" in white at 88 % with a small shadow, over a
        /// full-bleed image (`ArtworkHero`).
        case overArt
    }

    private let artwork: Artwork
    private let style: Style

    public init(_ artwork: Artwork, style: Style = .full) {
        self.artwork = artwork
        self.style = style
    }

    public var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(Self.accessibilityLabel(for: artwork, style: style)))
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .full, .short:
            let title = Text(artwork.title).foregroundStyle(Palette.textPrimary.color)
            Text("\(title)\(Self.text(for: artwork, style: style))")
                .plaqueFont()
                .lineSpacing(2)
                .foregroundStyle(Palette.textTertiary.color)
        case .compact:
            Text(Self.text(for: artwork, style: style)).plaqueStyle()
        case .overArt:
            Text(Self.text(for: artwork, style: style))
                .plaqueFont()
                .foregroundStyle(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
        }
    }

    /// The plaque's text after the title (`full`, `short`), or all of it (`compact`, `overArt`).
    nonisolated static func text(for artwork: Artwork, style: Style) -> String {
        switch style {
        case .full: ", \(artwork.artist), \(artwork.date) · \(artwork.museum) · \(artwork.licence)"
        case .short: ", \(artwork.artist), \(artwork.date) · \(artwork.licence)"
        case .compact: "\(artwork.shortArtist) · \(artwork.date)"
        case .overArt: "\(artwork.title) · \(artwork.artist) · \(artwork.date)"
        }
    }

    nonisolated static func accessibilityLabel(for artwork: Artwork, style: Style) -> String {
        switch style {
        case .full: "\(artwork.credit). \(artwork.museum). \(artwork.licence)"
        case .short: "\(artwork.credit). \(artwork.licence)"
        case .compact: "\(artwork.shortArtist), \(artwork.date)"
        case .overArt: artwork.credit
        }
    }
}

// MARK: ArtworkHero

/// A full-bleed artwork at the top of a screen (welcome, incognito): it extends under the status
/// bar and to the edges, fades through a scrim into `Palette.background`, and carries an over-art
/// caption. Lay content out below it; the view itself stays inside the safe area, so the caption
/// clears the status bar.
public struct ArtworkHero: View {
    private let artwork: Artwork
    private let height: CGFloat
    private let focal: UnitPoint
    private let showsCaption: Bool
    private let captionAlignment: HorizontalAlignment

    /// - Parameters:
    ///   - height: The hero's height inside the safe area (the art extends above it).
    ///   - focal: Overrides the work's own focal point.
    ///   - showsCaption: The over-art plaque; turn it off only if the work is credited nearby.
    ///   - captionAlignment: `.trailing` when a close or cancel button sits at the top leading corner.
    public init(
        _ artwork: Artwork,
        height: CGFloat = 320,
        focal: UnitPoint? = nil,
        showsCaption: Bool = true,
        captionAlignment: HorizontalAlignment = .leading
    ) {
        self.artwork = artwork
        self.height = height
        self.focal = focal ?? artwork.focal
        self.showsCaption = showsCaption
        self.captionAlignment = captionAlignment
    }

    public var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                ArtworkImage(artwork: artwork, focal: focal)
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: Palette.background.color.opacity(0), location: 0.4),
                                .init(color: Palette.background.color.opacity(0.75), location: 0.8),
                                .init(color: Palette.background.color, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
            }
            .overlay(alignment: Alignment(horizontal: captionAlignment, vertical: .top)) {
                if showsCaption {
                    Plaque(artwork, style: .overArt)
                        .multilineTextAlignment(captionAlignment == .trailing ? .trailing : .leading)
                        .padding(.horizontal, Spacing.l)
                        .padding(.top, Spacing.s)
                }
            }
    }
}

// MARK: Credits

/// About › The Collection (BRAND-04 puts it in Settings › About): the mouse's lineage, every
/// artwork with its plaque and museum link, and the plaque typeface's licence. Sections, so put it
/// inside a `List` or `Form`.
public struct CollectionCreditsList: View {
    public init() {}

    public var body: some View {
        Section {
            LineageRow()
        } header: {
            Text("Lineage, not imitation")
        }
        Section {
            ForEach(Self.inTheApp) { artwork in
                CreditRow(artwork: artwork)
            }
        } header: {
            Text("The Collection")
        }
        Section {
            ForEach(Self.behindTheIcons) { artwork in
                CreditRow(artwork: artwork)
            }
        } header: {
            Text("Behind the app icons")
        } footer: {
            Text(ui: "Every work is in the public domain. Museum names are credits, not endorsements.")
        }
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(ui: PlaqueFont.credit).font(Typography.callout)
                DisclosureGroup("Licence") {
                    Text(verbatim: PlaqueFont.licence)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Palette.textSecondary.color)
                        .textSelection(.enabled)
                }
                .font(Typography.callout)
            }
        } header: {
            Text("Typeface")
        }
    }

    /// The works the screens show (thresholds, covers, About), in catalog order.
    nonisolated static var inTheApp: [Artwork] { Artwork.all.filter { !$0.slots.contains(.icon) } }

    /// The paintings behind the app icons (BRAND-02), including those that also rotate through
    /// "Today in the collection" or the Project covers, so every work is credited exactly once.
    nonisolated static var behindTheIcons: [Artwork] { Artwork.all.filter { $0.slots.contains(.icon) } }
}

private struct LineageRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .bottom, spacing: Spacing.l) {
                FramedArtwork(.mascotOrigin, height: 120, aspectRatio: 0.85, mat: 5)
                Text(verbatim: "→").plaqueStyle(13, relativeTo: .footnote).padding(.bottom, Spacing.xl)
                PixelMouse(pose: .sit, scale: 3).mouseBackdrop().padding(.bottom, Spacing.s)
            }
            Text(ui: "Theseus is drawn after Shibata Zeshin's Mouse (1847): a white coat, a grey saddle, rose ears. The pixel is the machine; the art is human.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            Plaque(.mascotOrigin)
        }
        .padding(.vertical, Spacing.s)
    }
}

private struct CreditRow: View {
    let artwork: Artwork

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            FramedArtwork(artwork, height: 64, aspectRatio: min(max(artwork.aspectRatio, 0.7), 1.6), mat: 3)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Plaque(artwork)
                Link(destination: artwork.url) {
                    Text(verbatim: "View at \(artwork.museum) ↗").plaqueStyle(color: Palette.textSecondary)
                }
                .accessibilityLabel(Text(ui: "\(artwork.title) at \(artwork.museum)"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: Previews

#Preview("FramedArtwork + Plaque") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                FramedArtwork(.welcome)
                Plaque(.welcome)
            }
            VStack(alignment: .leading, spacing: Spacing.m) {
                FramedArtwork(.error, height: 220)
                Plaque(.error, style: .short)
            }
            HStack(alignment: .top, spacing: Spacing.l) {
                ForEach(Array(Artwork.projectCovers.prefix(3))) { artwork in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        FramedArtwork(artwork, height: 90, mat: 5)
                        Plaque(artwork, style: .compact)
                    }
                }
            }
        }
        .padding(Spacing.xl)
    }
    .themedBackground()
}

#Preview("ArtworkHero") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        ArtworkHero(.welcome)
        Text("Welcome to Theseus").font(Typography.display).padding(.horizontal, Spacing.l)
        Spacer()
    }
    .themedBackground()
}

#Preview("ArtworkHero, incognito (dark)") {
    VStack(alignment: .leading, spacing: Spacing.l) {
        ArtworkHero(.incognito, height: 260)
        Text("Incognito chat").font(Typography.title).padding(.horizontal, Spacing.l)
        Spacer()
    }
    .themedBackground()
    .preferredColorScheme(.dark)
}

#Preview("Collection credits") {
    List { CollectionCreditsList() }
}
