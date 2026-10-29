public import Entitlements
public import Observation

/// The paywall sheet's state (ADR 0173): the offer, a purchase or restore in flight, Ask to Buy,
/// and the thank-you once Pro is unlocked.
@MainActor
@Observable
public final class PaywallModel {
    public enum Phase: Equatable {
        case offer
        /// Pro is unlocked (bought or restored just now): the thank-you.
        case unlocked
    }

    public let store: ProStore
    public let request: PaywallRequest
    public private(set) var phase: Phase
    /// The last problem, shown under the button.
    public private(set) var message: String?

    public init(store: ProStore, request: PaywallRequest, serverSupport: ServerSupport = .unknown) {
        self.store = store
        self.request = request
        self.serverSupport = serverSupport
        phase = store.isPro ? .unlocked : .offer
    }

    /// What the active Account's Server offers (ADR 0173); the view sets it from the environment.
    public var serverSupport: ServerSupport = .unknown

    /// The checklist, with the feature that opened the paywall first, without what the Server
    /// lacks (and Server-dependent lines qualified while unknown, `detail(for:)`).
    public var checklist: [ProFeature] {
        serverSupport.checklist(leading: request.feature)
    }

    /// The line under a checklist item, as true as the Server allows.
    public func detail(for feature: ProFeature) -> String {
        serverSupport.detail(for: feature)
    }

    public var headline: String {
        request.feature?.gateHeadline ?? "Theseus Pro"
    }

    public var subheadline: String {
        request.feature?.gateMessage ?? "Pay once and it's yours for good. Every future update included."
    }

    /// "Unlock Pro · $9.99", or a plain title until the price loads.
    public var buttonTitle: String {
        if store.isPending { return "Waiting for approval" }
        guard let price = store.product?.displayPrice else { return "Unlock Pro" }
        return "Unlock Pro · \(price)"
    }

    public var canPurchase: Bool {
        store.product != nil && !store.isBusy && !store.isPending
    }

    /// The line under the button.
    public var footnote: String {
        if store.isPending {
            return "Pro unlocks as soon as the purchase is approved."
        }
        if store.product == nil, store.productUnavailable {
            return "The App Store isn't reachable right now."
        }
        return store.product?.isFamilyShareable == false ? "One-time purchase" : "One-time purchase · Family Sharing"
    }

    public func appear() async {
        if store.product == nil { await store.loadProduct() }
    }

    public func purchase() async {
        message = nil
        switch await store.purchase() {
        case .purchased: phase = .unlocked
        case .pending, .cancelled: break
        case .failed(let reason): message = "The purchase didn't go through. \(reason)"
        }
    }

    public func restore() async {
        message = nil
        switch await store.restore() {
        case .restored: phase = .unlocked
        case .nothingToRestore: message = "There's no Theseus Pro purchase on this Apple Account yet."
        case .failed(let reason): message = "Couldn't restore. \(reason)"
        }
    }

    /// Pro arrived from outside the sheet (Ask to Buy approved, another device).
    public func entitlementChanged() {
        if store.isPro { phase = .unlocked }
    }
}
