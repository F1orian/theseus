import DesignSystem
import Entitlements
import SwiftUI

/// Under the latest Response that ran in the sandbox, in the free tier (ADR 0173): it worked, it
/// was one of today's free runs, and Pro makes them unlimited. A plaque, not a banner, so it
/// stays out of the way of the Response.
struct FreeSandboxRunFooter: View {
    let allowance: SandboxAllowance
    @State private var paywall: PaywallRequest?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(allowance.isExhausted ? "Last free run today" : "Free run · \(allowance.remaining) of \(allowance.limit) left today")
                .plaqueStyle()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button("Unlimited with Pro") { paywall = PaywallRequest(.sandbox) }
                .font(Typography.caption.weight(.medium))
                .tint(Palette.accent.color)
                .accessibilityIdentifier("sandbox.freeRun.unlock")
        }
        .padding(.top, Spacing.xxs)
        .paywall($paywall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandbox.freeRun")
    }
}
