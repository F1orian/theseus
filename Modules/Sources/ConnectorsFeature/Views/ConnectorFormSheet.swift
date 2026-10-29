import DesignSystem
import OpenWebUIKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Add / Edit connector (#186), for a personal connector or a shared connection. Fields, inline
/// validation, **Verify** (what the server found), then Save. Keys go in a secure field and are
/// never shown again: an entry with a key reads "•••• set" until Replace.
struct ConnectorFormSheet: View {
    @State var form: ConnectorForm
    let directory: ConnectorDirectory
    /// Called with the stored connection after a successful save.
    let onSaved: @MainActor (ToolServerConnection) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?
    @State private var copiedCallback = false

    private enum Field: Hashable { case name, url, specPath, key, clientID, clientSecret, scope, description }

    private var title: String {
        switch (form.kind, form.isEditing) {
        case (.personal, false): "Add personal connector"
        case (.personal, true): "Edit personal connector"
        case (.shared, false): "Add connector"
        case (.shared, true): "Edit connector"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    ScopeBadge(scope: form.kind == .personal ? .personal : .shared(directory.host))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    LabeledTextField(title: "Name", text: $form.draft.name, prompt: "Team docs", error: visibleError(form.nameError, for: form.draft.name), identifier: "connectors.form.name")
                        .focused($focused, equals: .name)

                    LabeledTextField(title: "URL", text: $form.draft.url, prompt: "https://tools.example.com/mcp", error: visibleError(form.urlError, for: form.draft.url), identifier: "connectors.form.url")
                        .focused($focused, equals: .url)
                        .urlEntry()
                        .textContentType(.URL)
                }
                Section {
                    if form.types.count > 1 {
                        Picker("Type", selection: $form.draft.type) {
                            ForEach(form.types, id: \.self) { type in Text(type.label).tag(type) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: form.draft.type) { form.typeChanged() }
                        .accessibilityIdentifier("connectors.form.type")
                    }
                    if form.usesPastedSpec {
                        Text("Uses the spec pasted in the Open WebUI web app.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textSecondary.color)
                    } else if form.draft.type == .openAPI {
                        LabeledTextField(title: "Spec path", text: $form.draft.specPath, prompt: "openapi.json", error: visibleError(form.specPathError, for: form.draft.specPath), identifier: "connectors.form.specPath")
                            .focused($focused, equals: .specPath)
                            .urlEntry()
                    }
                } header: {
                    Text("Type")
                } footer: {
                    Text(typeFooter)
                }
                Section {
                    Picker("Sign-in", selection: $form.draft.authType) {
                        ForEach(form.authTypes, id: \.self) { auth in Text(auth.label).tag(auth) }
                    }
                    .onChange(of: form.draft.authType) { form.authChanged() }
                    .accessibilityIdentifier("connectors.form.auth")
                    if form.draft.authType == .bearer {
                        keyField
                    }
                } header: {
                    Text("Sign-in")
                } footer: {
                    if form.kind == .personal, form.draft.authType == .bearer {
                        Text("\(form.draft.authType.caption) It's saved in your Open WebUI settings, like the web app saves it.")
                    } else if form.sharesOneAccount {
                        Text("\(form.draft.authType.caption) With Everyone, all people on \(directory.host) act as this token's account.")
                            .accessibilityIdentifier("connectors.form.sharedTokenWarning")
                    } else {
                        Text(form.draft.authType.caption)
                    }
                }
                if let detail = form.registrationUnsupported {
                    registrationHelp(detail)
                        .id("registrationHelp")
                }
                if form.usesStaticOAuth {
                    oauthAppSection
                }
                verifySection
                Section {
                    TextField("Description (optional)", text: $form.draft.description, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused, equals: .description)
                        .accessibilityIdentifier("connectors.form.description")
                    Toggle("Enabled", isOn: $form.draft.isEnabled)
                        .tint(Palette.accent.color)
                        .accessibilityIdentifier("connectors.form.enabled")
                }
                if form.kind == .shared {
                    AccessSection(draft: $form.draft, groups: directory.shared.groups, host: directory.host)
                }
                if form.registrationUnsupported == nil,
                   let notice = form.kind == .personal ? directory.personal.notice : directory.shared.notice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.destructive.color)
                            .accessibilityIdentifier("connectors.form.notice")
                    }
                }
            }
            .onChange(of: form.registrationUnsupported) { _, detail in
                guard detail != nil else { return }
                withAnimation { proxy.scrollTo("registrationHelp", anchor: .top) }
            }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .themedBackground()
            .navigationTitle(title)
            .connectorsInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("connectors.form.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if form.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("connectors.form.save")
                    }
                }
            }
            .interactiveDismissDisabled(form.isSaving)
        }
        .tint(Palette.textPrimary.color)
        .presentationBackground(Palette.background.color)
        .accessibilityIdentifier("connectors.form")
    }

    private var typeFooter: String {
        if form.kind == .personal {
            return "Personal connectors are OpenAPI servers that your device calls. MCP servers can only be added by your Server admin."
        }
        return form.draft.type == .mcp
            ? "An MCP server over Streamable HTTP. Open WebUI connects to it for everyone."
            : "An OpenAPI server. Open WebUI reads its spec and calls it for everyone."
    }

    @ViewBuilder
    private var keyField: some View {
        if form.isReplacingKey {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                // The title stays visible in screenshots, which leave secure fields out.
                HStack(spacing: Spacing.m) {
                    Text("Key")
                        .accessibilityHidden(true)
                    SecureField("Key", text: $form.key, prompt: Text("Paste the key"))
                        // Not `.password`: a tool key isn't a login, so iOS mustn't offer to save it
                        // in Passwords when the sheet closes.
                        .textContentType(.oneTimeCode)
                        .privacySensitive()
                        .focused($focused, equals: .key)
                        .accessibilityIdentifier("connectors.form.key")
                }
                if let error = visibleError(form.keyError, for: form.key) {
                    FieldError(text: error)
                }
            }
        } else {
            HStack {
                Text("Key")
                Spacer()
                Text("•••• set")
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityLabel("Key set")
                Button("Replace") {
                    form.isReplacingKey = true
                    focused = .key
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("connectors.form.replaceKey")
            }
        }
    }

    // MARK: OAuth 2.1 (static) (#193)

    /// The OAuth app the admin creates at the provider: the callback URL to register there, then
    /// its client ID, secret and (optional) scopes.
    @ViewBuilder
    private var oauthAppSection: some View {
        Section {
            if let callback = form.callbackURL(in: directory.shared) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Callback URL")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary.color)
                        .accessibilityHidden(true)
                    Text(callback)
                        .font(Typography.callout.monospaced())
                        .foregroundStyle(Palette.textPrimary.color)
                        .textSelection(.enabled)
                        .accessibilityLabel("Callback URL, \(callback)")
                        .accessibilityIdentifier("connectors.form.callbackURL")
                }
                Button {
                    copy(callback)
                } label: {
                    Label(copiedCallback ? "Copied" : "Copy callback URL", systemImage: copiedCallback ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("connectors.form.copyCallback")
            } else {
                Text("Give it a name to see the callback URL.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            LabeledTextField(title: "Client ID", text: $form.draft.oauthClientID, prompt: "Paste the client ID", error: visibleError(form.clientIDError, for: form.draft.oauthClientID), identifier: "connectors.form.clientID")
                .focused($focused, equals: .clientID)
                .urlEntry()
            clientSecretField
            LabeledTextField(title: "Scope (optional)", text: $form.draft.oauthScope, prompt: "Uses the server's scopes", error: nil, identifier: "connectors.form.scope")
                .focused($focused, equals: .scope)
                .urlEntry()
        } header: {
            Text("OAuth app")
        } footer: {
            Text("Create an OAuth app at the provider with this callback URL, then paste its client ID and secret. GitHub: Settings › Developer settings › OAuth Apps › New OAuth App.")
        }
    }

    @ViewBuilder
    private var clientSecretField: some View {
        if form.isReplacingSecret {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.m) {
                    Text("Client secret")
                        .accessibilityHidden(true)
                    SecureField("Client secret", text: $form.clientSecret, prompt: Text("Paste the secret"))
                        .textContentType(.oneTimeCode)
                        .privacySensitive()
                        .focused($focused, equals: .clientSecret)
                        .accessibilityIdentifier("connectors.form.clientSecret")
                }
                if let error = visibleError(form.clientSecretError, for: form.clientSecret) {
                    FieldError(text: error)
                }
            }
        } else {
            HStack {
                Text("Client secret")
                Spacer()
                Text("•••• set")
                    .foregroundStyle(Palette.textSecondary.color)
                    .accessibilityLabel("Client secret set")
                Button("Replace") {
                    form.isReplacingSecret = true
                    focused = .clientSecret
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("connectors.form.replaceSecret")
            }
        }
    }

    /// Saving failed because the provider doesn't let the Server register itself: say so plainly
    /// and offer the two ways that work, keeping everything else in the sheet.
    private func registrationHelp(_ detail: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("This server needs its own OAuth app", systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Text("\(directory.host) couldn't register itself with this server's sign-in. GitHub and many other providers don't allow that. Choose another way:")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connectors.form.registrationHelp")
            Button {
                switchAuth { form.useStaticOAuth() }
                focused = .clientID
            } label: {
                ChoiceLabel(
                    title: "Use OAuth 2.1 (static)",
                    detail: "Create an OAuth app at the provider and paste its client ID and secret. Everyone still signs in as themselves.",
                    systemImage: "key.horizontal"
                )
            }
            .accessibilityIdentifier("connectors.form.useStatic")
            Button {
                switchAuth { form.useBearerToken() }
                focused = .key
            } label: {
                ChoiceLabel(
                    title: "Use a personal token",
                    detail: "Paste a token as a Bearer key. With Everyone, all people on \(directory.host) act as that token's account.",
                    systemImage: "person.badge.key"
                )
            }
            .accessibilityIdentifier("connectors.form.useBearer")
        } footer: {
            Text(detail)
        }
    }

    private func switchAuth(_ change: () -> Void) {
        change()
        directory.shared.notice = nil
        directory.shared.saveFailure = nil
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        copiedCallback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedCallback = false
        }
    }

    @ViewBuilder
    private var verifySection: some View {
        Section {
            Button {
                Task { await form.verify(personal: directory.personal, shared: directory.shared) }
            } label: {
                HStack {
                    Label(form.usesOAuth ? "Check sign-in" : "Verify", systemImage: "checkmark.seal")
                    Spacer()
                    if form.verifyState == .checking { ProgressView() }
                }
            }
            .disabled(form.verifyState == .checking)
            .accessibilityIdentifier("connectors.form.verify")
            VerifyResultView(state: form.verifyState)
        } footer: {
            Text(form.kind == .personal
                ? "Verify loads the spec from this device, as chats will."
                : "Verify asks \(directory.host) to connect with these settings. Nothing is saved yet.")
        }
    }

    private func visibleError(_ error: String?, for value: String) -> String? {
        guard let error else { return nil }
        return form.showsAllErrors || !value.isEmpty ? error : nil
    }

    private func save() async {
        if let saved = await form.save(personal: directory.personal, shared: directory.shared) {
            dismiss()
            onSaved(saved)
        }
    }
}

/// What Verify found: tool names, a working sign-in, or why it failed.
private struct VerifyResultView: View {
    let state: ConnectorForm.VerifyState

    var body: some View {
        switch state {
        case .idle, .checking:
            EmptyView()
        case .tools(let names, let title):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(names.isEmpty ? "Connected, but it lists no tools" : "Connected · \(names.count) \(names.count == 1 ? "tool" : "tools")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.accent.color)
                    .font(Typography.callout.weight(.semibold))
                if let title, !title.isEmpty {
                    Text(title).font(Typography.callout).foregroundStyle(Palette.textSecondary.color)
                }
                if !names.isEmpty {
                    Text(names.prefix(12).joined(separator: ", ") + (names.count > 12 ? ", …" : ""))
                        .font(Typography.callout.monospaced())
                        .foregroundStyle(Palette.textPrimary.color)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connectors.form.verifyResult")
        case .signIn(let issuer):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Sign-in found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.accent.color)
                    .font(Typography.callout.weight(.semibold))
                Text("People connect with \(issuer) after you save. Tools show once someone is signed in.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connectors.form.verifyResult")
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(Typography.callout)
                .foregroundStyle(Palette.destructive.color)
                .accessibilityIdentifier("connectors.form.verifyResult")
        }
    }
}

/// "Who can use it": everyone, some groups, or only admins (`config.access_grants`).
private struct AccessSection: View {
    @Binding var draft: ToolServerConnection.Draft
    let groups: [UserGroup]
    let host: String

    private enum Choice: Hashable { case everyone, groups, onlyMe }

    private var choice: Binding<Choice> {
        Binding {
            switch draft.access.audience {
            case .everyone: .everyone
            case .groups: .groups
            case .adminsOnly: .onlyMe
            }
        } set: { newValue in
            switch newValue {
            case .everyone: draft.access = .everyone
            case .onlyMe: draft.access = .adminsOnly
            case .groups: draft.access = ToolServerAccess(.groups(groups.first.map { [$0.id] } ?? []))
            }
        }
    }

    private var selectedGroups: [String] {
        if case .groups(let ids) = draft.access.audience { return ids }
        return []
    }

    var body: some View {
        Section {
            Picker("Who can use it", selection: choice) {
                Text("Everyone").tag(Choice.everyone)
                if !groups.isEmpty || !selectedGroups.isEmpty { Text("Groups").tag(Choice.groups) }
                Text("Only me").tag(Choice.onlyMe)
            }
            .accessibilityIdentifier("connectors.form.access")
            if choice.wrappedValue == .groups {
                ForEach(groups) { group in
                    Toggle(isOn: Binding(
                        get: { selectedGroups.contains(group.id) },
                        set: { isOn in
                            var ids = selectedGroups.filter { $0 != group.id }
                            if isOn { ids.append(group.id) }
                            draft.access = ids.isEmpty ? .adminsOnly : ToolServerAccess(.groups(ids))
                        }
                    )) {
                        Text(group.name)
                    }
                    .tint(Palette.accent.color)
                }
            }
        } header: {
            Text("Who can use it")
        } footer: {
            switch choice.wrappedValue {
            case .everyone: Text("Everyone on \(host) can turn it on in their chats.")
            case .groups: Text("Only members of the chosen groups (and admins) can use it.")
            case .onlyMe: Text("Only you and other admins on \(host) can use it.")
            }
        }
    }
}

/// One way forward in the registration help: a title and a line on what it means.
private struct ChoiceLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary.color)
                Text(detail)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary.color)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.textPrimary.color)
        }
    }
}

/// A text field with its title above and an inline error below.
private struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let error: String?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary.color)
                .accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(prompt))
                .font(Typography.body)
                .accessibilityIdentifier(identifier)
            if let error { FieldError(text: error) }
        }
    }
}

private struct FieldError: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(Typography.caption)
            .foregroundStyle(Palette.destructive.color)
    }
}

private extension View {
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}

// The preview helpers (Previews.swift) exist in Debug builds only.
#if DEBUG
#Preview("Add · OAuth 2.1 (static)") {
    let form = ConnectorForm(kind: .shared)
    form.draft.name = "GitHub"
    form.draft.url = "https://api.githubcopilot.com/mcp/"
    form.draft.authType = .oauth21Static
    return ConnectorFormSheet(form: form, directory: .preview) { _ in }
}
#endif
