public import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Applies the Account's `Appearance` to the whole window, including sheets (SET-02).
    ///
    /// On iOS this sets the window's `overrideUserInterfaceStyle`: `preferredColorScheme(nil)`
    /// doesn't hand control back to the system once a scheme was forced, so "System" would stick
    /// to the last explicit choice.
    public func appearance(_ appearance: Appearance) -> some View {
        #if os(iOS)
        background(WindowAppearance(style: appearance.interfaceStyle).frame(width: 0, height: 0))
        #else
        preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(iOS)
extension Appearance {
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
    }
}

/// An invisible view that styles the window it lands in.
private struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> WindowStyleView {
        WindowStyleView()
    }

    func updateUIView(_ view: WindowStyleView, context: Context) {
        view.style = style
    }

    final class WindowStyleView: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { apply() }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            // Signed out: the window follows the system again.
            if newWindow == nil {
                window?.overrideUserInterfaceStyle = .unspecified
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                window.overrideUserInterfaceStyle = self.style
            }
        }
    }
}
#endif
