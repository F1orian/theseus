import Entitlements
import Foundation
import Testing

@MainActor
@Suite("SandboxAllowance")
struct SandboxAllowanceTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "theseus.tests.allowance.\(UUID().uuidString)")!
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    @Test func startsFullAndCountsDown() {
        let allowance = SandboxAllowance(defaults: defaults(), limit: 3, calendar: calendar) { self.date("2026-10-25T10:00:00Z") }
        #expect(allowance.remaining == 3)
        allowance.recordUse()
        allowance.recordUse()
        #expect(allowance.remaining == 1)
        #expect(allowance.summary == "1 of 3 free runs left today")
        allowance.recordUse()
        #expect(allowance.isExhausted)
        allowance.recordUse()
        #expect(allowance.remaining == 0)
        #expect(allowance.usedToday == 3)
    }

    @Test func refillsAtLocalMidnight() {
        var now = date("2026-10-25T21:30:00Z") // 23:30 in Berlin
        let store = defaults()
        let allowance = SandboxAllowance(defaults: store, limit: 2, calendar: calendar) { now }
        allowance.recordUse()
        allowance.recordUse()
        #expect(allowance.isExhausted)
        #expect(allowance.refillsAt == date("2026-10-25T23:00:00Z"))
        now = date("2026-10-25T23:30:00Z") // 00:30 the next day in Berlin
        #expect(allowance.remaining == 2)
        allowance.recordUse()
        #expect(allowance.remaining == 1)
    }

    @Test func persistsAcrossInstances() {
        let store = defaults()
        let now = date("2026-10-25T10:00:00Z")
        SandboxAllowance(defaults: store, limit: 5, calendar: calendar) { now }.recordUse()
        let reopened = SandboxAllowance(defaults: store, limit: 5, calendar: calendar) { now }
        #expect(reopened.remaining == 4)
    }
}

@MainActor
@Suite("ProStore")
struct ProStoreTests {
    @Test func startsFreeAndLoadsThePrice() async {
        let store = ProStore(backend: InMemoryProBackend())
        #expect(store.status == .unknown)
        await store.start()
        #expect(store.status == .free)
        #expect(store.product?.displayPrice == "$9.99")
        #expect(!store.allows(.voiceMode))
        #expect(store.canUseSandbox)
    }

    @Test func purchaseUnlocksEverything() async {
        let store = ProStore(backend: InMemoryProBackend())
        await store.start()
        let outcome = await store.purchase()
        #expect(outcome == .purchased)
        #expect(store.isPro)
        for feature in ProFeature.allCases { #expect(store.allows(feature)) }
    }

    @Test func cancelledAndFailedPurchasesStayFree() async {
        let backend = InMemoryProBackend()
        let store = ProStore(backend: backend)
        await store.start()
        await backend.setNextOutcome(.cancelled)
        #expect(await store.purchase() == .cancelled)
        await backend.setNextOutcome(.failed("Nope"))
        #expect(await store.purchase() == .failed("Nope"))
        #expect(store.status == .free)
        #expect(!store.isBusy)
    }

    @Test func askToBuyWaitsThenUnlocksFromAnUpdate() async throws {
        let backend = InMemoryProBackend()
        let store = ProStore(backend: backend)
        await store.start()
        await backend.setNextOutcome(.pending)
        #expect(await store.purchase() == .pending)
        #expect(store.isPending)
        #expect(!store.isPro)
        // The parent approves: StoreKit delivers the transaction through `Transaction.updates`.
        try await Task.sleep(for: .milliseconds(50))
        await backend.deliverUpdate(entitled: true)
        try await waitUntil { store.isPro }
        #expect(!store.isPending)
    }

    @Test func aRefundLocksAgain() async throws {
        let backend = InMemoryProBackend(entitled: true)
        let store = ProStore(backend: backend)
        await store.start()
        #expect(store.isPro)
        try await Task.sleep(for: .milliseconds(50))
        await backend.deliverUpdate(entitled: false)
        try await waitUntil { store.status == .free }
    }

    @Test func restore() async {
        let backend = InMemoryProBackend()
        let store = ProStore(backend: backend)
        await store.start()
        #expect(await store.restore() == .nothingToRestore)
        await backend.setOwnedElsewhere(true)
        #expect(await store.restore() == .restored)
        #expect(store.isPro)
    }

    @Test func restoreFailure() async {
        let backend = InMemoryProBackend()
        await backend.setSyncError("You're offline.")
        let store = ProStore(backend: backend)
        await store.start()
        #expect(await store.restore() == .failed("You're offline."))
    }

    @Test func unreachableStore() async {
        let store = ProStore(backend: InMemoryProBackend(offered: nil))
        await store.start()
        #expect(store.productUnavailable)
        #expect(store.product == nil)
    }

    @Test func sandboxAllowanceOnlyCountsInTheFreeTier() async {
        let allowance = SandboxAllowance(limit: 2)
        let store = ProStore(backend: InMemoryProBackend(), allowance: allowance)
        await store.start()
        store.recordSandboxUse()
        store.recordSandboxUse()
        #expect(!store.canUseSandbox)
        #expect(!store.allows(.sandbox))
        await store.purchase()
        #expect(store.canUseSandbox)
        store.recordSandboxUse()
        #expect(allowance.usedToday == 2)
    }

    @Test func checklistCoversEveryFeature() {
        #expect(Set(ProFeature.checklist) == Set(ProFeature.allCases))
        for feature in ProFeature.allCases {
            #expect(!feature.title.isEmpty && !feature.detail.isEmpty && !feature.gateHeadline.isEmpty)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
