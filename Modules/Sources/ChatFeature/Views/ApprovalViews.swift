import ChatDomain
import DesignSystem
import SwiftUI

/// A tool call waiting for the user (OT-06): what the model wants to do, with Deny and Allow.
/// It takes the composer's place, like a clarifying question (CHAT-09).
struct ToolApprovalCard: View {
    let call: ToolCall
    let onResolve: (Bool) -> Void

    private var activity: ToolActivity {
        ToolActivity(id: call.resolvedCallID ?? "call", name: call.name, arguments: call.arguments, isRunning: true)
    }

    /// The command for sandbox runs, else the arguments as sent.
    private var preview: String? {
        if let detail = activity.detail { return call.name == "run_command" ? "$ " + detail : detail }
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "{}" ? nil : String(trimmed.prefix(400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(Palette.textSecondary.color)
                Text("Allow this step?")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary.color)
            }
            Text(activity.title)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            if let preview {
                ScrollView {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary.color)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.m)
                .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
                .accessibilityIdentifier("approval.preview")
            }
            HStack(spacing: Spacing.m) {
                Button { onResolve(false) } label: {
                    Text("Deny").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("approval.deny")
                Button { onResolve(true) } label: {
                    Text("Allow").frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.textPrimary.color)
                .accessibilityIdentifier("approval.allow")
            }
            .font(Typography.callout.weight(.semibold))
        }
        .padding(Spacing.l)
        .background(Palette.surface.color, in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.separator.color.opacity(0.6)))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.card")
    }
}

#Preview("Tool approval") {
    ToolApprovalCard(
        call: ToolCall(id: "1", callID: "c1", name: "run_command", arguments: #"{"command":"python3 make_report.py --out report.pdf"}"#, status: .pending)
    ) { _ in }
    .padding()
    .themedBackground()
}
