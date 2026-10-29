import Entitlements
import PaywallFeature
import Testing

@MainActor
@Suite("PaywallModel")
struct PaywallModelTests {
    @Test func contextualHeadlineLeadsTheChecklist() {
        let model = PaywallModel(store: .free(), request: PaywallRequest(.voiceMode))
        #expect(model.headline == ProFeature.voiceMode.gateHeadline)
        #expect(model.checklist.first == .voiceMode)
        #expect(Set(model.checklist) == Set(ProFeature.allCases))
    }

    @Test func plainUpgrade() {
        let model = PaywallModel(store: .free(), request: PaywallRequest())
        #expect(model.headline == "Theseus Pro")
        #expect(model.checklist == ProFeature.checklist)
        #expect(model.buttonTitle == "Unlock Pro · $9.99")
        #expect(model.footnote == "One-time purchase · Family Sharing")
    }

    // MARK: What the Server offers (ADR 0173 addendum)

    @Test func aServerWithoutCodeExecutionOrSkillsLeadsWithWhatItOffers() {
        let model = PaywallModel(store: .free(), request: PaywallRequest(), serverSupport: ServerSupport(codeExecution: .none, skills: false, connectors: false))
        #expect(model.checklist == [.voiceMode, .accounts, .platform, .appIcons])
        #expect(!model.checklist.map(model.detail(for:)).contains { $0.contains("Free includes") })
    }

    @Test func unknownServersShowEveryItemWithTheQualifier() {
        let model = PaywallModel(store: .free(), request: PaywallRequest())
        #expect(model.checklist.first == .sandbox)
        #expect(model.detail(for: .sandbox).contains("when your Server supports it"))
        #expect(model.detail(for: .skills).contains("when your Server supports them"))
    }

    @Test func aKnownSandboxDropsTheQualifier() {
        let model = PaywallModel(store: .free(), request: PaywallRequest(), serverSupport: ServerSupport(codeExecution: .sandbox, skills: true, connectors: true))
        #expect(model.checklist == ProFeature.checklist)
        #expect(model.detail(for: .sandbox) == "Run code and create files as often as you like. Free includes 5 runs a day.")
    }

    @Test func aGatesPaywallKeepsItsHeadlineAndLeads() {
        let model = PaywallModel(store: .free(), request: PaywallRequest(.sandbox), serverSupport: ServerSupport(codeExecution: .interpreter, skills: false, connectors: true))
        #expect(model.headline == "You've used today's free code execution runs")
        #expect(model.checklist == [.sandbox, .connectors, .voiceMode, .accounts, .platform, .appIcons])
        #expect(model.detail(for: .sandbox) == "Run code as often as you like. Free includes 5 runs a day.")
    }

    @Test func theConnectorsGateHasItsOwnHeadline() {
        let model = PaywallModel(store: .free(), request: PaywallRequest(.connectors))
        #expect(model.headline == "Connectors are part of Theseus Pro")
        #expect(model.checklist.first == .connectors)
    }

    @Test func purchaseShowsTheThankYou() async {
        let store = ProStore(backend: InMemoryProBackend())
        await store.start()
        let model = PaywallModel(store: store, request: PaywallRequest(.skills))
        #expect(model.canPurchase)
        await model.purchase()
        #expect(model.phase == .unlocked)
        #expect(store.isPro)
    }

    @Test func failedPurchaseExplains() async {
        let backend = InMemoryProBackend()
        await backend.setNextOutcome(.failed("Payment declined."))
        let store = ProStore(backend: backend)
        await store.start()
        let model = PaywallModel(store: store, request: PaywallRequest())
        await model.purchase()
        #expect(model.phase == .offer)
        #expect(model.message == "The purchase didn't go through. Payment declined.")
    }

    @Test func askToBuy() async {
        let backend = InMemoryProBackend()
        await backend.setNextOutcome(.pending)
        let store = ProStore(backend: backend)
        await store.start()
        let model = PaywallModel(store: store, request: PaywallRequest())
        await model.purchase()
        #expect(model.buttonTitle == "Waiting for approval")
        #expect(!model.canPurchase)
        #expect(model.footnote == "Pro unlocks as soon as the purchase is approved.")
    }

    @Test func restoreWithNothingToRestore() async {
        let store = ProStore(backend: InMemoryProBackend())
        await store.start()
        let model = PaywallModel(store: store, request: PaywallRequest())
        await model.restore()
        #expect(model.message == "There's no Theseus Pro purchase on this Apple Account yet.")
        await model.restore()
        #expect(model.phase == .offer)
    }

    @Test func unreachableStore() async {
        let store = ProStore(backend: InMemoryProBackend(offered: nil))
        await store.start()
        let model = PaywallModel(store: store, request: PaywallRequest())
        #expect(!model.canPurchase)
        #expect(model.buttonTitle == "Unlock Pro")
        #expect(model.footnote == "The App Store isn't reachable right now.")
    }

    @Test func alreadyProOpensOnTheThankYou() {
        let model = PaywallModel(store: .unlocked(), request: PaywallRequest())
        #expect(model.phase == .unlocked)
    }

    @Test func promiseSaysNoAdsAndNoTracking() {
        let titles = ProPromise.items.map(\.title)
        #expect(titles.contains("No ads"))
        #expect(titles.contains("No tracking"))
        #expect(titles.contains("No subscription"))
    }
}
