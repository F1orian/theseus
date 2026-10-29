#if os(iOS)
import UIKit

/// Keeps the drawer's drag out of text selection (#176). While text is selected in the window,
/// the drawer must not move: a drag there belongs to the selection (its handles, the loupe, a long
/// press that selected a word and drags on). `DrawerPanGesture` asks it when a touch arrives
/// (`mayOpen`) and again when the drag would begin.
///
/// Only the window's first responder holds a live selection, and only read-only text counts: a
/// non-editable `UITextView` (a finished Response's prose, #175) and SwiftUI's
/// `textSelection(.enabled)` (iOS 26: one `TextSelectionInteractionView` per `Text`, a `UITextInput`
/// that becomes first responder with a non-empty `selectedTextRange` while text is selected). The handles and the loupe only exist while it does, so they need no check of their
/// own; views that resigned keep stale ranges and are ignored (#177).
@MainActor
enum TextSelectionGuard {
    /// Whether the drawer may start from a touch on `view`: not while text is selected in its
    /// window.
    static func allowsDrawer(touchingView view: UIView?) -> Bool {
        allowsDrawer(in: view?.window)
    }

    /// Whether the drawer's drag may begin in `window`: no text is selected there.
    static func allowsDrawer(in window: UIWindow?) -> Bool {
        guard let window else { return true }
        return !hasActiveSelection(in: window)
    }

    /// Whether some view in `window` shows a non-empty text selection. Only the window's first
    /// responder can: a text view, field or selectable `Text` that resigned keeps its last range
    /// (a selection left in a Chat that's no longer on screen, a draft's range), and that must
    /// never hold the drawer shut (#177).
    static func hasActiveSelection(in window: UIWindow) -> Bool {
        guard let responder = firstResponder(in: window), !isEditable(responder) else { return false }
        return hasSelection(responder)
    }

    /// A field being typed in (the composer, a search field) never holds the drawer, whatever its
    /// range: a caret, or the range a keyboard keeps while it types (inline predictions, marked
    /// text), isn't a selection to protect, and a drag that starts inside the field is already its
    /// own (`DrawerPanGesture.mayOpen`). Only read-only text (a Response, a selectable `Text`)
    /// counts (#177).
    static func isEditable(_ view: UIView) -> Bool {
        if let textView = view as? UITextView { return textView.isEditable }
        return view is UITextField
    }

    /// The view that is first responder in `window`, if any.
    static func firstResponder(in window: UIWindow) -> UIView? {
        var stack: [UIView] = [window]
        var visited = 0
        while let view = stack.popLast() {
            visited += 1
            // A transcript is a few thousand views at most; stop well before that gets costly.
            if visited > 20_000 { break }
            if view.isHidden || view.alpha < 0.01 { continue }
            if view.isFirstResponder { return view }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// `view` (the first responder) shows a non-empty selection, as a text input itself or
    /// through its text interactions.
    static func hasSelection(_ view: UIView) -> Bool {
        if let input = view as? UITextInput, isNonEmpty(input.selectedTextRange) { return true }
        for interaction in view.interactions {
            if let text = interaction as? UITextInteraction, let input = text.textInput, isNonEmpty(input.selectedTextRange) {
                return true
            }
            if let display = interaction as? UITextSelectionDisplayInteraction, display.isActivated,
               let input = display.textInput, isNonEmpty(input.selectedTextRange) {
                return true
            }
        }
        return false
    }

    private static func isNonEmpty(_ range: UITextRange?) -> Bool {
        guard let range else { return false }
        return !range.isEmpty
    }
}
#endif
