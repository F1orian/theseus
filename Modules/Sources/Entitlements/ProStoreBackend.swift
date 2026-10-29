public import Foundation
import StoreKit

/// The Theseus Pro product as the paywall shows it.
public struct ProProduct: Equatable, Sendable {
    public var id: String
    public var displayName: String
    /// Localized by the App Store, e.g. "$9.99" or "9,99 €".
    public var displayPrice: String
    public var isFamilyShareable: Bool

    public init(id: String, displayName: String, displayPrice: String, isFamilyShareable: Bool) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.isFamilyShareable = isFamilyShareable
    }
}

/// How a purchase ended.
public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    /// Waiting for approval (Ask to Buy) or for the payment method; it unlocks when it clears.
    case pending
    case cancelled
    case failed(String)
}

/// The App Store side of Theseus Pro, behind a seam so tests and UI-test launches don't need
/// StoreKit. `StoreKitProBackend` is the live one; `InMemoryProBackend` the test double.
public protocol ProStoreBackend: Sendable {
    /// The product, or `nil` when the App Store doesn't offer it (yet).
    func product() async throws -> ProProduct?
    /// Whether this Apple Account owns Pro (bought, restored or shared through Family Sharing),
    /// and the purchase hasn't been refunded.
    func isEntitled() async -> Bool
    /// Buys Pro. Verifies and finishes the transaction.
    func purchase() async -> PurchaseOutcome
    /// Asks the App Store to sync this Apple Account's purchases ("Restore purchase").
    func sync() async throws
    /// Yields whenever a transaction arrives outside a purchase (Ask to Buy approved, a refund,
    /// a purchase on another device, Family Sharing). Consumers re-read `isEntitled()`.
    func transactionUpdates() -> AsyncStream<Void>
    /// The Pro transaction's id, for a refund request.
    func transactionID() async -> UInt64?
}

/// The App Store, through StoreKit 2. Transactions are verified on the device (JWS); nothing goes
/// to a server of ours, because there is none.
public actor StoreKitProBackend: ProStoreBackend {
    /// The non-consumable's product id in App Store Connect and `App/Theseus.storekit`.
    public static let productID = "dev.unrush.theseus.pro"

    private let productID: String
    private var loaded: Product?

    public init(productID: String = StoreKitProBackend.productID) {
        self.productID = productID
    }

    public func product() async throws -> ProProduct? {
        guard let product = try await storeProduct() else { return nil }
        return ProProduct(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            isFamilyShareable: product.isFamilyShareable
        )
    }

    public func isEntitled() async -> Bool {
        await currentTransaction() != nil
    }

    public func purchase() async -> PurchaseOutcome {
        do {
            guard let product = try await storeProduct() else {
                return .failed("Theseus Pro isn't available in the App Store right now.")
            }
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                return transaction.revocationDate == nil ? .purchased : .failed("This purchase was refunded.")
            case .success(.unverified(_, let error)):
                return .failed("The App Store couldn't verify the purchase. \(error.localizedDescription)")
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func sync() async throws {
        try await AppStore.sync()
    }

    public nonisolated func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result { await transaction.finish() }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func transactionID() async -> UInt64? {
        await currentTransaction()?.id
    }

    private func storeProduct() async throws -> Product? {
        if let loaded { return loaded }
        let product = try await Product.products(for: [productID]).first
        loaded = product
        return product
    }

    private func currentTransaction() async -> Transaction? {
        for await result in Transaction.currentEntitlements(for: productID) {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                return transaction
            }
        }
        return nil
    }
}

/// A store in memory: tests, previews and UI-test launches (`-theseus-pro free|pro`).
public actor InMemoryProBackend: ProStoreBackend {
    public private(set) var entitled: Bool
    /// What the next `purchase()` returns; `.purchased` also unlocks.
    public var nextOutcome: PurchaseOutcome = .purchased
    /// What the store offers; `nil` simulates an unreachable App Store.
    public var offered: ProProduct?
    /// Whether a sync ("Restore purchase") finds an earlier purchase.
    public var ownedElsewhere = false
    public var syncError: String?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(entitled: Bool = false, offered: ProProduct? = InMemoryProBackend.sampleProduct) {
        self.entitled = entitled
        self.offered = offered
    }

    public static let sampleProduct = ProProduct(
        id: StoreKitProBackend.productID,
        displayName: "Theseus Pro",
        displayPrice: "$9.99",
        isFamilyShareable: true
    )

    public func product() async throws -> ProProduct? { offered }

    public func isEntitled() async -> Bool { entitled }

    public func purchase() async -> PurchaseOutcome {
        if nextOutcome == .purchased { entitled = true }
        return nextOutcome
    }

    public func sync() async throws {
        if let syncError { throw SyncFailure(message: syncError) }
        if ownedElsewhere { entitled = true }
    }

    public nonisolated func transactionUpdates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let id = UUID()
        Task { await self.add(continuation, id: id) }
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        return stream
    }

    public func transactionID() async -> UInt64? { entitled ? 1 : nil }

    // MARK: Test controls

    public func setNextOutcome(_ outcome: PurchaseOutcome) { nextOutcome = outcome }
    public func setOffered(_ product: ProProduct?) { offered = product }
    public func setOwnedElsewhere(_ owned: Bool) { ownedElsewhere = owned }
    public func setSyncError(_ message: String?) { syncError = message }

    /// A transaction arrived from outside (Ask to Buy approved, a refund): set the entitlement
    /// and tell listeners.
    public func deliverUpdate(entitled: Bool) {
        self.entitled = entitled
        for continuation in continuations.values { continuation.yield() }
    }

    private func add(_ continuation: AsyncStream<Void>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func remove(_ id: UUID) {
        continuations[id] = nil
    }

    struct SyncFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
