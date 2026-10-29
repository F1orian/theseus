import DesignSystem
import Entitlements
import StoreKit
import SwiftUI

/// The card at the top of Settings in the free tier (ADR 0173):
/// what Pro adds on this Server, that it's one payment, and the button to the paywall.
struct ProUpgradeCard: View {
    let store: ProStore
    let unlock: () -> Void
    @Environment(\.serverSupport) private var serverSupport

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Get more from Theseus")
                .font(Typography.headline)
                .foregroundStyle(Palette.textPrimary.color)
            Text("\(serverSupport.upgradeSummary) Pay once: no subscription, no ads, no tracking.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: unlock) {
                Text(store.product.map { "Unlock Theseus Pro · \($0.displayPrice)" } ?? "Unlock Theseus Pro")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.onAccent.color)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 36)
                    .background(Palette.accent.color, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.xs)
            .accessibilityIdentifier("settings.pro.unlock")
        }
        .padding(.vertical, Spacing.xs)
        .settingsRowBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.pro.card")
    }
}

/// Settings › Theseus Pro (ADR 0173): the plan, today's free code execution runs, what Pro
/// includes on this Server, the promise, and Restore purchase / refunds.
struct ProSettingsView: View {
    let store: ProStore
    @State private var paywall: PaywallRequest?
    @State private var restoreMessage: String?
    @State private var refundTransactionID: UInt64?
    @State private var isRequestingRefund = false
    @Environment(\.openURL) private var openURL
    @Environment(\.serverSupport) private var serverSupport

    var body: some View {
        List {
            Section {
                SettingsValueRow(title: "Plan", value: store.isPro ? "Theseus Pro" : "Free")
                    .accessibilityIdentifier("settings.pro.plan")
                if !store.isPro {
                    if serverSupport.mentionsCodeExecutionRuns {
                        SettingsValueRow(
                            title: "Code execution today",
                            value: "\(store.allowance.remaining) of \(store.allowance.limit) free runs left"
                        )
                        .accessibilityIdentifier("settings.pro.allowance")
                    }
                    Button {
                        paywall = PaywallRequest()
                    } label: {
                        Text(store.product.map { "Unlock Theseus Pro · \($0.displayPrice)" } ?? "Unlock Theseus Pro")
                    }
                    .buttonStyle(.accentPill)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: 0, bottom: Spacing.s, trailing: 0))
                    .accessibilityIdentifier("settings.pro.pageUnlock")
                }
            } footer: {
                Text(store.isPro
                    ? "Thank you for supporting Theseus. Pro is yours on every device signed in to your Apple Account, and for your Family Sharing group."
                    : "One purchase, every future update included. Family Sharing shares it.")
            }

            Section(store.isPro ? "Included" : "Pro adds") {
                ForEach(serverSupport.checklist()) { feature in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Image(systemName: store.isPro ? "checkmark" : feature.systemImage)
                            .foregroundStyle(Palette.accent.color)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(ui: feature.title)
                                .font(Typography.body)
                                .foregroundStyle(Palette.textPrimary.color)
                            Text(ui: serverSupport.detail(for: feature))
                                .font(Typography.callout)
                                .foregroundStyle(Palette.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .settingsRowBackground()
                }
            }

            Section("Our promise") {
                ForEach(ProPromise.items) { item in
                    promiseRow(item)
                }
                if let url = ProPromise.sourceCodeURL {
                    Button { openURL(url) } label: { promiseRow(ProPromise.sourceCodeItem) }
                }
            }

            Section {
                Button {
                    Task { await restore() }
                } label: {
                    HStack {
                        SettingsRowLabel(title: "Restore purchase", systemImage: "arrow.clockwise")
                        Spacer()
                        if store.isBusy { ProgressView() }
                    }
                }
                .disabled(store.isBusy)
                .settingsRowBackground()
                .accessibilityIdentifier("settings.pro.restore")
                if store.isPro {
                    Button {
                        Task { await requestRefund() }
                    } label: {
                        SettingsRowLabel(title: "Request a refund", systemImage: "arrow.uturn.backward")
                    }
                    .settingsRowBackground()
                }
                if let terms = ProPromise.termsURL {
                    Button { openURL(terms) } label: {
                        SettingsRowLabel(title: "Terms of Use", systemImage: "doc.text")
                    }
                    .settingsRowBackground()
                }
            } footer: {
                if let restoreMessage {
                    Text(restoreMessage).accessibilityIdentifier("settings.pro.restoreMessage")
                }
            }
            #if DEBUG
            DebugProSection(store: store)
            #endif
        }
        .settingsList()
        .navigationTitle("Theseus Pro")
        .settingsInlineTitle()
        .paywall($paywall)
        .refundRequestSheet(for: refundTransactionID ?? 0, isPresented: $isRequestingRefund) { _ in
            Task { await store.refreshEntitlement() }
        }
        .task { await store.refreshEntitlement() }
        .accessibilityIdentifier("settings.pro.page")
    }

    private func promiseRow(_ item: ProPromise.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: item.systemImage)
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ui: item.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(ui: item.detail)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .settingsRowBackground()
    }

    private func restore() async {
        restoreMessage = nil
        switch await store.restore() {
        case .restored: restoreMessage = "Theseus Pro is restored. Thank you!"
        case .nothingToRestore: restoreMessage = "There's no Theseus Pro purchase on this Apple Account yet."
        case .failed(let reason): restoreMessage = "Couldn't restore. \(reason)"
        }
    }

    private func requestRefund() async {
        guard let id = await store.transactionID() else {
            restoreMessage = "There's no purchase on this Apple Account to refund."
            return
        }
        refundTransactionID = id
        isRequestingRefund = true
    }
}

#if DEBUG
/// Debug builds only: simulate Pro or the free tier on a device install, before the product
/// exists in App Store Connect (ADR 0173). Release builds never compile this.
private struct DebugProSection: View {
    let store: ProStore

    private enum Choice: String, CaseIterable, Identifiable {
        case appStore = "App Store"
        case pro = "Pro"
        case free = "Free"
        var id: String { rawValue }
    }

    var body: some View {
        Section {
            Picker("Simulate", selection: Binding(
                get: {
                    switch store.debugOverride {
                    case true?: Choice.pro
                    case false?: Choice.free
                    case nil: Choice.appStore
                    }
                },
                set: { choice in
                    switch choice {
                    case .appStore: store.debugOverride = nil
                    case .pro: store.debugOverride = true
                    case .free: store.debugOverride = false
                    }
                }
            )) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .settingsRowBackground()
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Overrides what the App Store says on this device.")
        }
    }
}
#endif
