import SwiftUI
#if os(iOS)
import UIKit

/// Reports when a finger lands on and leaves the transcript (#183). SwiftUI's scroll phases miss a
/// touch that doesn't move, and a touch during a follow animation, yet either must stop the
/// transcript from following a stream. The recognizer only watches: it never recognizes, cancels
/// or delays a touch, so scrolling, taps, text selection and the drawer's drag work as before.
struct TranscriptTouchObserver: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> TouchWatcher {
        let recognizer = TouchWatcher()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: TouchWatcher, context: Context) {
        recognizer.onBegan = onBegan
        recognizer.onEnded = onEnded
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    /// Stays `possible` while fingers are down and fails when the last one lifts.
    final class TouchWatcher: UIGestureRecognizer {
        var onBegan: () -> Void = {}
        var onEnded: () -> Void = {}
        private var touching = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if touching == 0 { onBegan() }
            touching += touches.count
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            lift(touches.count)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            lift(touches.count)
        }

        private func lift(_ count: Int) {
            touching = max(0, touching - count)
            guard touching == 0 else { return }
            onEnded()
            state = .failed
        }

        override func reset() {
            super.reset()
            touching = 0
        }

        // Never prevents another recognizer, and is never one that must fail first.
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
#endif

extension View {
    /// Calls `began` when a finger lands on the view and `ended` when the last one lifts
    /// (iOS; elsewhere nothing).
    func onTouches(began: @escaping () -> Void, ended: @escaping () -> Void) -> some View {
        #if os(iOS)
        gesture(TranscriptTouchObserver(onBegan: began, onEnded: ended))
        #else
        self
        #endif
    }
}
