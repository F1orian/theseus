import ChatDomain
import DesignSystem
import Entitlements
import OpenWebUIKit
import SwiftUI

// Skills (#140): the Server's workspace Skills, picked per Chat from Add to Chat or with `/` in
// the composer. Picked Skills show as chips on the composer and go out as `skill_ids`.

extension ComposerModel {
    /// The `/skill` query being typed (the whole draft is `/` plus a word), or `nil`.
    var slashQuery: String? {
        guard text.hasPrefix("/"), !services.skills.isEmpty else { return nil }
        let query = text.dropFirst()
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    /// Skills matching the `/` query by name or id, not yet picked.
    var slashMatches: [Skill] {
        guard let query = slashQuery?.lowercased() else { return [] }
        return services.skills.filter { skill in
            !isSkillSelected(skill.id)
                && (query.isEmpty || skill.name.lowercased().contains(query) || skill.id.lowercased().contains(query))
        }
    }

    /// Picks a Skill from the `/` menu and clears the query.
    func pickFromSlashMenu(_ skill: Skill) {
        setSkill(skill.id, selected: true)
        text = ""
    }
}

/// A readable Skill name: "deep-research" → "Deep research".
enum SkillName {
    static func display(_ skill: Skill) -> String {
        let base = skill.name == skill.id ? skill.id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") : skill.name
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}

/// The `/` menu above the composer field: matching Skills, tap to pick.
struct SlashSkillMenu: View {
    let model: ComposerModel

    var body: some View {
        let matches = model.slashMatches
        if model.slashQuery != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.xs) {
                    Text("Skills")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary.color)
                    // ADR 0173: picking one opens the paywall in the free tier.
                    if !model.services.pro.isPro { ProBadge() }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                if matches.isEmpty {
                    Text("No skills match.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary.color)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { skill in
                            Button {
                                model.pickFromSlashMenu(skill)
                            } label: {
                                SkillRowLabel(skill: skill, isSelected: false)
                                    .padding(.horizontal, Spacing.m)
                                    .padding(.vertical, Spacing.s)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("composer.slash.\(skill.id)")
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Spacing.xs)
            .background(Palette.recessedSurface.color, in: .rect(cornerRadius: Radius.medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer.slashMenu")
        }
    }
}

/// Picked Skills as removable chips on the composer.
struct SelectedSkillChips: View {
    let model: ComposerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(model.selectedSkills) { skill in
                    Button {
                        model.setSkill(skill.id, selected: false)
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "sparkles")
                            Text(SkillName.display(skill)).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .font(Typography.caption.weight(.medium))
                        .foregroundStyle(Palette.textPrimary.color)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs + 2)
                        .background(Palette.recessedSurface.color, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(SkillName.display(skill)) skill")
                    .accessibilityHint("Removes the skill from this chat")
                    .accessibilityIdentifier("composer.skill.\(skill.id)")
                }
            }
        }
    }
}

/// A Skill's name and description, with a checkmark when picked.
struct SkillRowLabel: View {
    let skill: Skill
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "sparkles")
                .foregroundStyle(Palette.textSecondary.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(SkillName.display(skill))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                if let description = skill.description {
                    Text(description)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Add to Chat › Skills: pick the Skills this Chat's Messages use, the Account's own first,
/// then those shared from the Server (#187).
struct SkillsPickerPage: View {
    let model: ComposerModel
    @State private var query = ""

    private func matching(_ skills: [Skill]) -> [Skill] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(query) || ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private var host: String {
        ServerDisplay.host(model.services.client.server, fallback: "this Server")
    }

    var body: some View {
        let yours = matching(model.services.yourSkills)
        let shared = matching(model.services.sharedSkills)
        List {
            if !yours.isEmpty {
                Section {
                    rows(yours)
                } header: {
                    Text("Yours")
                } footer: {
                    if shared.isEmpty { footer }
                }
                .listRowBackground(Palette.recessedSurface.color)
            }
            if !shared.isEmpty || yours.isEmpty {
                Section {
                    rows(shared)
                } header: {
                    Text("From \(host)")
                } footer: {
                    footer
                }
                .listRowBackground(Palette.recessedSurface.color)
            }
        }
        .modifier(SheetListStyle())
        .searchable(text: $query, prompt: "Search skills")
        .navigationTitle("Skills")
        .inlineTitle()
        .accessibilityIdentifier("addToChat.skills")
    }

    private func rows(_ skills: [Skill]) -> some View {
        ForEach(skills) { skill in
            Button {
                model.setSkill(skill.id, selected: !model.isSkillSelected(skill.id))
            } label: {
                SkillRowLabel(skill: skill, isSelected: model.isSkillSelected(skill.id))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addToChat.skill.\(skill.id)")
        }
    }

    private var footer: some View {
        Text("The model follows the skills you pick in every message of this chat. Type / in the message field to pick one quickly. Add your own in Settings › Skills.")
    }
}
