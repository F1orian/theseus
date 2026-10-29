import ChatFeature
import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One command the model ran in the sandbox (OT-02): a compact card, "Ran `ls -la`" with its
/// exit status, that expands to the full command and its output in a terminal-like block.
struct RunCard: View {
    let run: SandboxRun
    /// Open or closed, and all output shown, kept by the transcript: an older Response's row is
    /// rebuilt when it scrolls back into view (#197).
    private var disclosures = TranscriptDisclosureScope()
    @State private var copied = false

    private var expanded: Bool {
        get { disclosures.isOpen("run-\(run.id)") }
        nonmutating set { disclosures.setOpen("run-\(run.id)", newValue) }
    }

    private var showsAllOutput: Bool {
        get { disclosures.isOpen("run-output-\(run.id)") }
        nonmutating set { disclosures.setOpen("run-output-\(run.id)", newValue) }
    }

    /// Long output shows its last lines until "Show all".
    static let visibleLines = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withMotion(Motion.smooth) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(expanded ? "Hides the output" : "Shows the command and its output")
            .accessibilityIdentifier("sandbox.run")

            if expanded {
                Divider().overlay(Palette.separator.color)
                details
                    .motionSafeTransition(.expand)
            }
        }
        .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.separator.color))
        // OT-02: running → done swaps the spinner for the result, and the exit badge eases in.
        .motionSafeAnimation(Motion.smooth, value: run.isRunning)
        .appearsWithFade()
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.s) {
            // While the Response's tail mouse is up it's the live indicator, so no spinner here (#195).
            StepStatusIcon(isRunning: run.isRunning, systemImage: run.failed ? "exclamationmark.triangle" : "apple.terminal")
                .foregroundStyle(run.failed ? Palette.destructive.color : Palette.textSecondary.color)
                .frame(width: 18)
            Text(verb)
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary.color)
            Text(run.headline.isEmpty ? "a command" : run.headline)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Palette.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.s)
            if let badge = statusBadge {
                Text(badge)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(run.failed ? Palette.destructive.color : Palette.textTertiary.color)
                    .contentTransition(.interpolate)
                    .transition(.opacity)
                    .accessibilityIdentifier("sandbox.run.status")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary.color)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s + 2)
        .contentShape(.rect)
    }

    private var verb: String {
        run.isRunning ? "Running" : "Ran"
    }

    /// "Exit 2", "Stopped", "Failed"; nothing for a clean exit.
    private var statusBadge: String? {
        guard !run.isRunning else { return nil }
        switch run.status {
        case .killed: return "Stopped"
        case .failed: return "Failed"
        case .done: return (run.exitCode ?? 0) == 0 ? nil : "Exit \(run.exitCode ?? 0)"
        case .running: return nil
        }
    }

    private var accessibilityTitle: String {
        var title = "\(verb) \(run.headline)"
        if let statusBadge { title += ", \(statusBadge)" }
        return title
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("$ " + run.command)
                        .foregroundStyle(Palette.textPrimary.color)
                        .accessibilityIdentifier("sandbox.run.command")
                    if !run.inputs.isEmpty {
                        ForEach(Array(run.inputs.enumerated()), id: \.offset) { _, input in
                            Text("> " + input.trimmingCharacters(in: .newlines))
                                .foregroundStyle(Palette.textTertiary.color)
                        }
                    }
                    outputText
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            if truncationNote != nil || !run.output.isEmpty || failureText != nil {
                footer
            }
        }
        .padding(Spacing.m)
    }

    @ViewBuilder
    private var outputText: some View {
        if let failureText {
            Text(failureText)
                .foregroundStyle(Palette.destructive.color)
                .accessibilityIdentifier("sandbox.run.error")
        }
        if !run.chunks.isEmpty {
            let visible = visibleOutput
            Text(visible.text.isEmpty ? " " : visible.text)
                .foregroundStyle(run.failed && !run.chunks.contains { !$0.isError } ? Palette.destructive.color : Palette.textSecondary.color)
                .accessibilityIdentifier("sandbox.run.output")
        } else if run.isRunning {
            Text("Waiting for output…")
                .foregroundStyle(Palette.textTertiary.color)
        } else if failureText == nil {
            Text("No output")
                .foregroundStyle(Palette.textTertiary.color)
        }
    }

    private var failureText: String? {
        if case .failed(let message) = run.status { return message }
        return nil
    }

    private var visibleOutput: (text: String, dropped: Int) {
        showsAllOutput ? (run.output, 0) : TerminalText.tail(run.output, lines: Self.visibleLines)
    }

    private var truncationNote: String? {
        if visibleOutput.dropped > 0 { return "\(visibleOutput.dropped) earlier lines hidden" }
        if run.truncated { return "The sandbox shortened this output" }
        return nil
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            if let truncationNote {
                Text(truncationNote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
            }
            if visibleOutput.dropped > 0 {
                Button("Show all") { showsAllOutput = true }
                    .font(Typography.caption.weight(.semibold))
                    .accessibilityIdentifier("sandbox.run.showAll")
            }
            Spacer(minLength: 0)
            if !run.isRunning, run.exitCode != nil {
                Text("Exit code \(run.exitCode ?? 0)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(run.failed ? Palette.destructive.color : Palette.textTertiary.color)
            }
            Button {
                copy("$ \(run.command)\n\(run.output)")
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(Typography.caption)
            .accessibilityLabel(copied ? "Copied" : "Copy command and output")
            .accessibilityIdentifier("sandbox.run.copy")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textSecondary.color)
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        withMotion(Motion.bouncy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withMotion(Motion.snappy) { copied = false }
        }
    }
}

/// A quiet line for a file operation in the sandbox (OT-02): "Created hello.txt · 2 bytes".
struct FileStepLine: View {
    let step: SandboxFileStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            StepStatusIcon(isRunning: step.isRunning, systemImage: step.failed ? "exclamationmark.triangle" : step.systemImage, controlSize: .mini)
                .frame(width: 18)
            Text(step.title)
                .font(Typography.callout)
                .lineLimit(1)
            if let size = step.size, !step.failed, step.action == .create || step.action == .edit {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary.color)
            }
        }
        .foregroundStyle(step.failed ? Palette.destructive.color : Palette.textSecondary.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sandbox.fileStep")
    }
}

#Preview("Runs") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.m) {
            RunCard(run: SandboxRun(
                id: "1", command: "ls -la theseus-test", cwd: "/home/user", processID: "p1", status: .done, exitCode: 0,
                chunks: [.init(text: "total 12\ndrwxr-sr-x 2 user user 4096 .\n-rw-r--r-- 1 user user    2 hello.txt\n", isError: false)],
                truncated: false, isWaiting: false, inputs: []
            ))
            RunCard(run: SandboxRun(
                id: "2", command: "ls theseus-test/missing.txt", cwd: nil, processID: "p2", status: .done, exitCode: 2,
                chunks: [.init(text: "ls: cannot access 'theseus-test/missing.txt': No such file or directory\n", isError: true)],
                truncated: false, isWaiting: false, inputs: []
            ))
            RunCard(run: SandboxRun(
                id: "3", command: "for i in 1 2 3; do echo tick $i; sleep 2; done", cwd: nil, processID: "p3", status: .running,
                exitCode: nil, chunks: [], truncated: false, isWaiting: true, inputs: []
            ))
            FileStepLine(step: SandboxFileStep(id: "4", action: .create, path: "/home/user/theseus-test/hello.txt", size: 2, isRunning: false, failed: false))
            FileStepLine(step: SandboxFileStep(id: "5", action: .edit, path: "/home/user/theseus-test/planets.csv", size: 42, isRunning: false, failed: false))
            FileStepLine(step: SandboxFileStep(id: "6", action: .search("TODO"), path: nil, size: nil, isRunning: true, failed: false))
        }
        .padding()
    }
    .themedBackground()
}
