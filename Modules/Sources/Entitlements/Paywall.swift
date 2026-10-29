public import SwiftUI
import DesignSystem

/// Why the paywall opens: a Pro feature someone tried (its headline leads), or `nil` for the
/// plain upgrade from Settings.
public struct PaywallRequest: Identifiable, Hashable, Sendable {
    public let feature: ProFeature?

    public init(_ feature: ProFeature? = nil) {
        self.feature = feature
    }

    public var id: String { feature?.rawValue ?? "upgrade" }
}

/// Builds the paywall sheet for a request. The app installs the real one (`PaywallFeature`);
/// Feature areas only present it with `.paywall(_:)`, so they don't depend on its module.
public struct PaywallContent {
    private let make: @MainActor (PaywallRequest) -> AnyView

    public init(_ make: @escaping @MainActor (PaywallRequest) -> AnyView) {
        self.make = make
    }

    @MainActor
    public func callAsFunction(_ request: PaywallRequest) -> AnyView {
        make(request)
    }
}

extension EnvironmentValues {
    @Entry public var paywallContent = PaywallContent { _ in AnyView(EmptyView()) }
    /// The app's Theseus Pro store, for views that gate or badge. `nil` (previews, hosts without a
    /// store) counts as unlocked.
    @Entry public var proStore: ProStore?
}

extension View {
    /// Presents the paywall while `request` is set (ADR 0173). Every gate keeps its own request
    /// state, so the sheet comes from the screen or sheet the user is on.
    public func paywall(_ request: Binding<PaywallRequest?>, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(PaywallPresenter(request: request, onDismiss: onDismiss))
    }
}

private struct PaywallPresenter: ViewModifier {
    @Binding var request: PaywallRequest?
    let onDismiss: (() -> Void)?
    @Environment(\.paywallContent) private var content

    func body(content view: Content) -> some View {
        view.sheet(item: $request, onDismiss: onDismiss) { request in
            content(request)
        }
    }
}

/// A small `PRO` plaque next to a gated row (brand.md §2: Departure Mono, 13 pt or smaller).
public struct ProBadge: View {
    public init() {}

    public var body: some View {
        Text("Pro")
            .plaqueStyle(10, color: Palette.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.accent.color, lineWidth: 1))
            .accessibilityLabel("Theseus Pro")
    }
}
