import DesignSystem
import Rendering
import SwiftUI

/// "Select text" (#175): the whole Message as one read-only text, so a selection
/// can span paragraphs, list items and headings; the system handles, loupe, Copy and Select All
/// work as anywhere else. "Select all" in the header selects everything; "Copy" copies the
/// selection (or everything, when nothing is selected).
struct SelectTextSheet: View {
    let draft: MessageActions.SelectTextDraft
    let actions: MessageActions
    @State private var controller = SelectableTextController()
    @State private var text: NSAttributedString
    @Environment(\.dismiss) private var dismiss

    init(draft: MessageActions.SelectTextDraft, actions: MessageActions) {
        self.draft = draft
        self.actions = actions
        _text = State(initialValue: draft.isMarkdown
            ? MarkdownAttributedText.make(markdown: draft.text)
            : MarkdownAttributedText.make(plain: draft.text))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Select text", close: { dismiss() })
            SelectableTextView(text: text, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: Spacing.m) {
                Button("Select all", systemImage: "selection.pin.in.out") { controller.selectAll() }
                    .accessibilityIdentifier("selectText.selectAll")
                Spacer()
                Button("Copy", systemImage: "square.on.square") {
                    actions.copy(controller.selectedText ?? text.string, messageID: draft.messageID)
                    dismiss()
                }
                .accessibilityIdentifier("selectText.copy")
            }
            .font(Typography.callout.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Palette.textPrimary.color)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
        .themedBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectText.sheet")
    }
}
