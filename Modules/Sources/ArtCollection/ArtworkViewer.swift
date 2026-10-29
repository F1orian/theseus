import DesignSystem
public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An artwork full screen (#178): the whole painting, uncropped, on the gallery's night wall;
/// pinch or double-tap to zoom in and drag to look around. Its plaque and a "View at <museum>"
/// link sit underneath, the close button at the top. Present it with `fullScreenCover`.
///
/// ```swift
/// .fullScreenCover(item: $viewing) { ArtworkViewer($0) }
/// ```
public struct ArtworkViewer: View {
    private let artwork: Artwork
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var image: CGImage?

    public init(_ artwork: Artwork) {
        self.artwork = artwork
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.background.color.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.l) {
                Group {
                    if let image {
                        ZoomableArtwork(image: image)
                    } else {
                        artwork.placeholder.color
                            .aspectRatio(artwork.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement()
                .accessibilityLabel(Text(artwork.credit))
                .accessibilityAddTraits(.isImage)
                .accessibilityHint(Text("Pinch or double-tap to zoom"))
                .accessibilityIdentifier("artwork.viewer.image")

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Plaque(artwork, style: .full)
                    Button {
                        openURL(artwork.url)
                    } label: {
                        Text(ui: "View at \(artwork.museum) ›").plaqueStyle(color: Palette.accent)
                            .frame(minHeight: AccessibilityMetrics.minimumHitTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(ui: "View at \(artwork.museum)"))
                    .accessibilityHint(Text("Opens the museum's page in the browser"))
                    .accessibilityIdentifier("artwork.viewer.museum")
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.m)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textPrimary.color)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(Spacing.l)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("artwork.viewer.close")
        }
        // The gallery after hours: the art on the night wall, in light mode too.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artwork.viewer")
        .task {
            // The full 1600 px image, decoded off the main thread.
            image = await artwork.loadImage()
        }
    }
}

#if canImport(UIKit)
/// A `UIScrollView` zooming an image: pinch from 1× (the whole work) to 4×, double-tap to zoom
/// in on a point and back out; the image stays centred while it's smaller than the screen.
private struct ZoomableArtwork: UIViewRepresentable {
    let image: CGImage

    func makeUIView(context: Context) -> ZoomingView {
        ZoomingView(image: UIImage(cgImage: image))
    }

    func updateUIView(_ view: ZoomingView, context: Context) {}

    final class ZoomingView: UIScrollView, UIScrollViewDelegate {
        private let imageView: UIImageView

        init(image: UIImage) {
            imageView = UIImageView(image: image)
            super.init(frame: .zero)
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            backgroundColor = .clear
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale == minimumZoomScale, bounds.width > 0 else { return }
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale {
                setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                     animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
}
#else
private struct ZoomableArtwork: View {
    let image: CGImage
    @State private var zoom: CGFloat = 1

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .gesture(MagnifyGesture().onChanged { zoom = min(max(1, $0.magnification), 4) })
            .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2.5 }
    }
}
#endif
