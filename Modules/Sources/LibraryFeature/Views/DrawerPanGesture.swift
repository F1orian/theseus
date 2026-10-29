#if os(iOS)
import SwiftUI
import UIKit

/// The drawer's drag (CHATS-01, ADR 0130 addendum): a `UIPanGestureRecognizer` brought into
/// SwiftUI with `UIGestureRecognizerRepresentable`, because the arbitration it needs isn't
/// expressible with SwiftUI gestures alone:
///
/// - **Closed:** it begins anywhere on the content, but only for a predominantly horizontal,
///   rightward drag, and never when the touch starts in a horizontally scrolling view that can
///   still scroll left (code blocks, tables, chip rows), in a text field, or in a navigation stack
///   that can pop (the system back swipe owns those). A horizontal scroller already at its left
///   edge yields to the drawer.
/// - **Open:** any predominantly horizontal drag tracks the drawer, to close it (or keep it open).
///
/// Once it begins, scroll views under the finger stop: the drawer and the transcript never move
/// together.
struct DrawerPanGesture: UIGestureRecognizerRepresentable {
    /// Whether the drawer shows (open drags may go either way).
    var isOpen: Bool
    /// Off while the drawer takes the whole screen (its search, #172).
    var isEnabled = true
    /// The finger's horizontal travel since the drag began (points).
    var onChanged: (CGFloat) -> Void
    /// Released: travel, velocity (points per second) and the projected end of the travel.
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat, _ predicted: CGFloat) -> Void
    /// The system cancelled the drag.
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            onEnded(translation, velocity, translation + Self.projection(of: velocity))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    /// How far a release at `velocity` would carry with the system's normal deceleration.
    static func projection(of velocity: CGFloat) -> CGFloat {
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        return velocity / 1000 * rate / (1 - rate)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard !isOpen else { return true }
            return DrawerPanGesture.mayOpen(from: touch.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            guard TextSelectionGuard.allowsDrawer(in: pan.view?.window) else { return false }
            let velocity = pan.velocity(in: pan.view)
            let translation = pan.translation(in: pan.view)
            let dx = abs(velocity.x) > 1 ? velocity.x : translation.x
            let dy = abs(velocity.x) > 1 ? velocity.y : translation.y
            // Predominantly horizontal: at most ~35° off the horizontal.
            guard abs(dx) > abs(dy) * 1.4 else { return false }
            return isOpen || dx > 0
        }

        /// While closed, scroll views under the finger wait for the drawer to decide. It decides at
        /// the same point a scroll would start: a vertical drag fails it at once (the transcript
        /// scrolls), a rightward one claims it (a horizontal scroller at its left edge yields).
        /// Scrollers that can still scroll left never get here: `shouldReceive` refused the touch.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            guard !isOpen, let scrollView = other.view as? UIScrollView else { return false }
            return other === scrollView.panGestureRecognizer
        }

        /// Once the drawer moves, nothing under the finger acts on the touch: the card travels
        /// with the finger, so a button there (the home's artwork card) would otherwise take the
        /// release for a tap.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }

    /// Whether a closed drawer may start opening from a touch on `view`: not in a text field,
    /// not in a horizontal scroller that can still scroll left, not in a stack that can go back.
    @MainActor
    static func mayOpen(from view: UIView?) -> Bool {
        guard TextSelectionGuard.allowsDrawer(touchingView: view) else { return false }
        var current = view
        while let candidate = current {
            if candidate is UITextField || candidate is UITextView, (candidate as? UITextView)?.isEditable ?? true {
                return false
            }
            if let scrollView = candidate as? UIScrollView, scrollView.scrollsHorizontally, scrollView.canScrollLeft {
                return false
            }
            current = candidate.superview
        }
        var responder: UIResponder? = view
        while let next = responder {
            if let navigation = next as? UINavigationController, navigation.viewControllers.count > 1 {
                return false
            }
            responder = next.next
        }
        return true
    }
}

extension UIScrollView {
    /// Its content is wider than it is (with insets): it scrolls sideways.
    var scrollsHorizontally: Bool {
        contentSize.width + adjustedContentInset.left + adjustedContentInset.right > bounds.width + 1
    }

    /// It isn't at its leading edge yet.
    var canScrollLeft: Bool {
        contentOffset.x > -adjustedContentInset.left + 1
    }
}
#endif
