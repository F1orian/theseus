import Foundation
public import Observation

/// Whether this Apple Account owns Theseus Pro.
public enum ProStatus: Equatable, Sendable {
    /// Not checked yet (launch). Gates treat it as free, but nothing nags while it's unknown.
    case unknown
    case free
    case pro
}

/// How "Restore purchase" ended.
public enum RestoreOutcome: Equatable, Sendable {
    case restored
    case nothingToRestore
    case failed(String)
}

/// Theseus Pro for the whole app (ADR 0173): one non-consumable, bought once through the App
/// Store, with Family Sharing. It answers "is this unlocked?" for every gate, owns the free
/// sandbox allowance, and runs purchases and restores for the paywall.
///
/// One per app, created by `AppModel` and shared by every Account's shell. There's no account,
/// receipt server or analytics behind it: StoreKit verifies transactions on the device.
@MainActor
@Observable
public final class ProStore {
    public private(set) var status: ProStatus = .unknown
    /// The App Store's product (price), once loaded.
    public private(set) var product: ProProduct?
    /// Whether the product couldn't be loaded (offline, App Store unreachable).
    public private(set) var productUnavailable = false
    /// A purchase or restore is in flight.
    public private(set) var isBusy = false
    /// A purchase waits for approval (Ask to Buy).
    public private(set) var isPending = false
    /// The free daily code execution runs (sandbox and code interpreter).
    public let allowance: SandboxAllowance

    @ObservationIgnored private let backend: any ProStoreBackend
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(backend: any ProStoreBackend, allowance: SandboxAllowance? = nil) {
        self.backend = backend
        self.allowance = allowance ?? SandboxAllowance()
    }

    /// A store that's already Pro (tests, previews, and the default for modules whose host app
    /// didn't hand one over).
    public static func unlocked() -> ProStore {
        let store = ProStore(backend: InMemoryProBackend(entitled: true))
        store.status = .pro
        return store
    }

    /// A free store with the sample price (previews and tests).
    public static func free(allowance: SandboxAllowance? = nil) -> ProStore {
        let store = ProStore(backend: InMemoryProBackend(), allowance: allowance)
        store.status = .free
        store.product = InMemoryProBackend.sampleProduct
        return store
    }

    public var isPro: Bool { status == .pro }

    /// Whether `feature` is unlocked. The sandbox is "allowed" in the free tier while runs remain;
    /// use `canUseSandbox` for it.
    public func allows(_ feature: ProFeature) -> Bool {
        feature == .sandbox ? canUseSandbox : isPro
    }

    /// Whether the next request may use code execution (attach the sandbox, or turn on the code
    /// interpreter): always with Pro, else while free runs remain.
    public var canUseSandbox: Bool {
        isPro || !allowance.isExhausted
    }

    /// Counts a Response that ran code against the free allowance (nothing with Pro).
    public func recordSandboxUse() {
        guard !isPro else { return }
        allowance.recordUse()
    }

    // MARK: Lifecycle

    /// Reads the entitlement and the product, then follows transactions. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        let stream = backend.transactionUpdates()
        updates = Task { [weak self] in
            for await _ in stream {
                await self?.refreshEntitlement()
            }
        }
        await refreshEntitlement()
        await loadProduct()
    }

    /// Re-reads the entitlement (e.g. when the app becomes active).
    public func refreshEntitlement() async {
        #if DEBUG
        if let debugOverride {
            status = debugOverride ? .pro : .free
            return
        }
        #endif
        let entitled = await backend.isEntitled()
        status = entitled ? .pro : .free
        if entitled { isPending = false }
    }

    /// Loads the price; called by `start()` and again by the paywall when it failed before.
    public func loadProduct() async {
        do {
            product = try await backend.product()
            productUnavailable = product == nil
        } catch {
            productUnavailable = product == nil
        }
    }

    // MARK: Buying

    /// Buys Pro through the App Store sheet.
    @discardableResult
    public func purchase() async -> PurchaseOutcome {
        guard !isBusy else { return .cancelled }
        isBusy = true
        defer { isBusy = false }
        let outcome = await backend.purchase()
        switch outcome {
        case .purchased:
            status = .pro
            isPending = false
        case .pending:
            isPending = true
        case .cancelled, .failed:
            break
        }
        return outcome
    }

    /// "Restore purchase": syncs with the App Store (it may ask to sign in) and re-reads the entitlement.
    @discardableResult
    public func restore() async -> RestoreOutcome {
        guard !isBusy else { return .nothingToRestore }
        isBusy = true
        defer { isBusy = false }
        do {
            try await backend.sync()
        } catch {
            return .failed(error.localizedDescription)
        }
        await refreshEntitlement()
        return isPro ? .restored : .nothingToRestore
    }

    /// The Pro transaction, for `refundRequestSheet(for:isPresented:)`.
    public func transactionID() async -> UInt64? {
        await backend.transactionID()
    }

    #if DEBUG
    /// Debug builds only: pretend Pro is (`true`) or isn't (`false`) unlocked, whatever the App
    /// Store says, e.g. on a device install before the product exists in App Store Connect.
    /// Kept in the standard defaults; `nil` asks the App Store again.
    public var debugOverride: Bool? {
        get {
            _ = status
            return UserDefaults.standard.object(forKey: Self.debugOverrideKey) as? Bool
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.debugOverrideKey)
            Task { await refreshEntitlement() }
        }
    }

    static let debugOverrideKey = "theseus.debug.proOverride"
    #endif

    isolated deinit {
        updates?.cancel()
    }
}
