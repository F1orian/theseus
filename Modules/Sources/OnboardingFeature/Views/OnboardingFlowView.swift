public import SwiftUI

/// Renders the current `OnboardingFlow` step.
public struct OnboardingFlowView: View {
    private let flow: OnboardingFlow

    public init(flow: OnboardingFlow) {
        self.flow = flow
    }

    public var body: some View {
        content
            .overlay(alignment: .topLeading) {
                if flow.onCancel != nil {
                    Button("Cancel", systemImage: "xmark") { flow.cancel() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: .circle)
                        .padding(.leading, 16)
                        .accessibilityIdentifier("onboarding.cancel")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .serverEntry(let model):
            ServerEntryView(model: model)
        case .signIn(let model):
            SignInView(model: model)
        case .pendingApproval(let model):
            PendingApprovalView(model: model)
        case .verification(let model):
            VerificationView(model: model)
        }
    }
}
