import ChatDomain
import Auth
import DesignSystem
import Entitlements
public import SwiftUI

/// AUTH-07: switch between the Accounts on this device, add one, or remove one from the device.
/// An inset-grouped list, one section per Server.
public struct AccountSwitcherView: View {
    @Bindable private var model: AccountSwitcherModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: AccountSwitcherModel.Row?

    public init(model: AccountSwitcherModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            Button {
                                Task {
                                    if await model.select(row) { dismiss() }
                                }
                            } label: {
                                AccountRowView(row: row)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Palette.surface.color)
                            .swipeActions {
                                Button("Remove", role: .destructive) { pendingRemoval = row }
                            }
                            .accessibilityIdentifier("accounts.row.\(row.account.email)")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(ServerDisplay.name(group.server.name))
                            Text(ServerDisplay.host(group.server.url))
                                .font(Typography.caption)
                                .textCase(nil)
                        }
                    }
                }
                Section {
                    Button {
                        if model.addAccount() { dismiss() }
                    } label: {
                        HStack {
                            Label("Add account", systemImage: "plus.circle")
                                .foregroundStyle(Palette.textPrimary.color)
                            Spacer()
                            // ADR 0173: more than one Account is Pro.
                            if model.addingNeedsPro { ProBadge() }
                        }
                    }
                    .listRowBackground(Palette.surface.color)
                    .accessibilityIdentifier("accounts.add")
                } footer: {
                    Text(model.addingNeedsPro
                        ? "Each account keeps its own chats and settings on this device. Adding and switching accounts is part of Theseus Pro."
                        : "Each account keeps its own chats and settings on this device.")
                }
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .paywall($model.paywallRequest)
            .navigationTitle("Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Palette.textPrimary.color)
                        .accessibilityIdentifier("accounts.close")
                }
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.account.email ?? "this account") from this device?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { row in
                Button("Remove", role: .destructive) {
                    Task { await model.remove(row) }
                }
            } message: { _ in
                Text("Theseus signs out and deletes its cached chats here. The account stays on its server.")
            }
            .onAppear { model.reload() }
        }
        .accessibilityIdentifier("accounts.sheet")
    }
}

private struct AccountRowView: View {
    let row: AccountSwitcherModel.Row

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(initials)
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.background.color)
                .frame(width: 36, height: 36)
                .background(Palette.textSecondary.color, in: .circle)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(row.account.name.isEmpty ? row.account.email : row.account.name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(row.isSignedIn ? row.account.email : "\(row.account.email) · Signed out")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary.color)
            }
            Spacer(minLength: Spacing.s)
            if row.isActive {
                Image(systemName: "checkmark")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.accent.color)
                    .accessibilityLabel("Current account")
            }
        }
        .contentShape(.rect)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let source = row.account.name.isEmpty ? row.account.email : row.account.name
        let letters = source.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
