import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A run of a finished Response's prose (paragraphs, headings, lists, quotes) as **one** selectable
/// text (#175, ADR 0150): a read-only, non-scrolling, self-sizing TextKit 2 `UITextView`, so a
/// selection made in place extends across paragraphs, headings and list items. Code blocks,
/// tables, math and Artifacts stay their own views between runs. Links (and citation markers) go
/// to the environment's `openURL`, like `Text` links.
struct SelectableProseView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if canImport(UIKit)
        let edges = MarkdownAttributedText.edgeAdjustments(for: blocks)
        ProseTextView(blocks: blocks, style: "\(dynamicTypeSize)|\(colorScheme)", openURL: openURL)
            .padding(.top, edges.top)
            .padding(.bottom, edges.bottom)
        #else
        VStack(alignment: .leading, spacing: ResponseTypography.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in BlockView(block: block) }
        }
        #endif
    }
}

extension MarkdownBlock {
    /// Prose that reads as text: a paragraph or heading without math, or a list or quote made
    /// only of such prose. These join one selectable run in a finished Response.
    var isSelectableProse: Bool {
        switch self {
        case .heading(_, let content), .paragraph(let content):
            !content.runs.contains { if case .math = $0 { true } else { false } }
        case .list(_, _, let items):
            items.allSatisfy { $0.blocks.allSatisfy(\.isSelectableProse) }
        case .quote(let blocks):
            blocks.allSatisfy(\.isSelectableProse)
        case .code, .math, .table, .rule:
            false
        }
    }
}

/// Blocks grouped for a finished Response: runs of prose (one text each) and everything else.
enum MarkdownSegment {
    case prose([MarkdownBlock])
    case block(MarkdownBlock)

    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var run: [MarkdownBlock] = []
        for block in blocks {
            if block.isSelectableProse {
                run.append(block)
            } else {
                if !run.isEmpty { segments.append(.prose(run)) }
                run = []
                segments.append(.block(block))
            }
        }
        if !run.isEmpty { segments.append(.prose(run)) }
        return segments
    }
}

#if canImport(UIKit)
private struct ProseTextView: UIViewRepresentable {
    let blocks: [MarkdownBlock]
    /// Changes when the text must be rebuilt for the same blocks (Dynamic Type, appearance).
    let style: String
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.accent.color)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "response.prose"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        let key = Coordinator.Key(blocks: blocks, style: style)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        view.attributedText = MarkdownAttributedText.make(blocks: blocks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        struct Key: Equatable {
            let blocks: [MarkdownBlock]
            let style: String
        }

        var key: Key?
        var openURL: OpenURLAction?

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }
    }
}
#endif
