import DesignSystem
import Entitlements
import OnboardingFeature
import PaywallFeature
public import SwiftUI

/// The app's root: renders whichever screen `AppModel.route` selects.
public struct RootView: View {
    private let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.route {
            case .launching:
                BrandSplashView()
            case .onboarding(let flow):
                OnboardingFlowView(flow: flow)
            case .aiDataConsent(let shell):
                AIDataConsentView(
                    host: shell.account.server.url.host() ?? shell.account.server.name,
                    onAgree: { await model.agreeToAIDataSharing() },
                    onSignOut: { await model.declineAIDataSharing() }
                )
            case .main(let shell):
                MainShellView(model: shell)
            }
        }
        // #179 (ADR 0145): the chosen accent. Setting the selection invalidates every view that
        // read an accent token (this `.tint` included), so they redraw in place, keeping
        // navigation and sheets. `initial` covers launch, sign-in and Account switches.
        .tint(Palette.accent.color)
        .onChange(of: model.accent, initial: true) { _, accent in
            AccentSelection.shared.choice = accent
        }
        // The UI is English. Typeset it as English, or a German device hyphenates it with German
        // rules ("spreads-heets", "infor-mation", "opti-ons").
        .typesettingLanguage(Locale.Language(identifier: "en"))
        .sheet(item: Binding(get: { model.accountSwitcher }, set: { model.accountSwitcher = $0 })) { switcher in
            AccountSwitcherView(model: switcher)
        }
        // ADR 0173: every gate presents this paywall, with the app's Theseus Pro store.
        .environment(\.paywallContent, PaywallContent { [pro = model.pro] request in
            AnyView(PaywallView(store: pro, request: request))
        })
        .environment(\.proStore, model.pro)
        .task { await model.start() }
        // #185: decode the working-mouse scenes off the main thread, so the first one shown at a
        // Response's tail doesn't.
        .task(priority: .utility) { await WorkingMouse.prewarm() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.sceneDidBecomeActive() } }
        }
    }
}
