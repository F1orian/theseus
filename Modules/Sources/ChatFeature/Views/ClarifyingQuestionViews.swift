import ChatDomain
import DesignSystem
import OpenWebUIKit
public import SwiftUI

/// The model's clarifying questions, docked where the composer sits: a "1 of 2" pager, numbered
/// options, a free-text row and a close button (CHAT-09).
struct ClarifyingQuestionCard: View {
    let questions: ClarifyingQuestions
    let onSubmit: ([String: ClarifyingQuestions.Answer]) -> Void
    let onDismiss: () -> Void

    @State private var index = 0
    @State private var answers: [String: ClarifyingQuestions.Answer] = [:]
    @State private var otherText = ""
    @FocusState private var typing: Bool

    private var question: ClarifyingQuestions.Question? {
        questions.questions.indices.contains(index) ? questions.questions[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                if questions.questions.count > 1 {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                        .accessibilityLabel("Previous question")
                    Text("\(index + 1) of \(questions.questions.count)")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .monospacedDigit()
                    Button { move(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= questions.questions.count - 1)
                        .accessibilityLabel("Next question")
                } else if let header = question?.header {
                    Text(header)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                }
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .accessibilityLabel("Skip questions")
                    .accessibilityIdentifier("question.close")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary.color)

            if let question {
                Text(question.text)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("question.text")

                VStack(spacing: 0) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                        Button { choose(.option(index: offset, option), for: question) } label: {
                            HStack(alignment: .center, spacing: Spacing.m) {
                                Text("\(offset + 1)")
                                    .font(Typography.callout)
                                    .frame(width: 32, height: 32)
                                    .background(isSelected(offset, question) ? Palette.accent.color.opacity(0.18) : Palette.recessedSurface.color, in: .circle)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(option.label).font(Typography.body)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(Typography.caption)
                                            .foregroundStyle(Palette.textSecondary.color)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 0)
                                if offset == 0 {
                                    Text("Recommended")
                                        .font(Typography.caption)
                                        .foregroundStyle(Palette.textTertiary.color)
                                }
                            }
                            .foregroundStyle(Palette.textPrimary.color)
                            .padding(.vertical, Spacing.s)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("question.option.\(offset)")
                        Divider()
                    }
                    if question.allowsOther {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: "pencil")
                                .frame(width: 32, height: 32)
                                .background(Palette.recessedSurface.color, in: .circle)
                            TextField("Type your answer…", text: $otherText)
                                .font(Typography.body)
                                .focused($typing)
                                .submitLabel(.send)
                                .onSubmit { submitOther(for: question) }
                                .accessibilityIdentifier("question.other")
                            if !otherText.trimmingCharacters(in: .whitespaces).isEmpty {
                                Button { submitOther(for: question) } label: {
                                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Palette.accent.color)
                                .accessibilityLabel("Submit answer")
                            }
                        }
                        .padding(.vertical, Spacing.s)
                    }
                }
            }
        }
        .padding(Spacing.l)
        .background(Palette.surface.color, in: .rect(cornerRadius: Radius.large))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 2)
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Palette.separator.color.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("question.card")
    }

    private func isSelected(_ offset: Int, _ question: ClarifyingQuestions.Question) -> Bool {
        if case .option(let chosen, _)? = answers[question.id] { return chosen == offset }
        return false
    }

    private func move(_ delta: Int) {
        index = min(max(index + delta, 0), questions.questions.count - 1)
        otherText = ""
    }

    private func submitOther(for question: ClarifyingQuestions.Question) {
        let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        choose(.other(text), for: question)
    }

    /// Records the answer and moves on; after the last question the answers are sent.
    private func choose(_ answer: ClarifyingQuestions.Answer, for question: ClarifyingQuestions.Question) {
        answers[question.id] = answer
        otherText = ""
        if questions.isComplete(answers) {
            onSubmit(answers)
        } else if let next = questions.questions.firstIndex(where: { answers[$0.id] == nil }) {
            withAnimation(.snappy) { index = next }
        }
    }
}
