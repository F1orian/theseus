import DesignSystem
public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Drives a `SelectableTextView` from SwiftUI: select everything, copy the selection.
@MainActor
public final class SelectableTextController {
    #if canImport(UIKit)
    weak var textView: UITextView?
    #endif

    public init() {}

    /// Selects the whole text and shows the system handles and edit menu.
    public func selectAll() {
        #if canImport(UIKit)
        guard let textView else { return }
        textView.becomeFirstResponder()
        textView.selectAll(nil)
        #endif
    }

    /// The selected text, or `nil` when nothing is selected.
    public var selectedText: String? {
        #if canImport(UIKit)
        guard let textView, let range = textView.selectedTextRange, !range.isEmpty else { return nil }
        return textView.text(in: range)
        #else
        return nil
        #endif
    }
}

/// One read-only, selectable text view for a whole attributed string (#175): a TextKit 2
/// `UITextView`, so a selection can span paragraphs, list items and headings, with the system
/// handles, loupe, Copy and Select All. It scrolls itself; give it the room it should fill.
///
/// ```swift
/// SelectableTextView(text: MarkdownAttributedText.make(markdown: markdown), controller: controller)
/// ```
public struct SelectableTextView: View {
    private let text: NSAttributedString
    private let controller: SelectableTextController?

    public init(text: NSAttributedString, controller: SelectableTextController? = nil) {
        self.text = text
        self.controller = controller
    }

    public var body: some View {
        #if canImport(UIKit)
        TextViewRepresentable(text: text, controller: controller)
        #else
        ScrollView {
            Text(AttributedString(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        #endif
    }
}

#if canImport(UIKit)
private struct TextViewRepresentable: UIViewRepresentable {
    let text: NSAttributedString
    let controller: SelectableTextController?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.accent.color), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.accessibilityIdentifier = "selectText.text"
        view.attributedText = text
        controller?.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != text { view.attributedText = text }
        controller?.textView = view
    }
}
#endif

