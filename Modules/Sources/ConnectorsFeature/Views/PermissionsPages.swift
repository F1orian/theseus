import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings › Permissions (CONN-07, phase 1): the device data Theseus may share with the model.
/// Only Location for now; Calendar and Reminders need client-side tools (ADR 0091).
struct PermissionsPage: View {
    let location: LocationSharing

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LocationPermissionPage(location: location)
                } label: {
                    HStack {
                        Label {
                            Text("Location").foregroundStyle(Palette.textPrimary.color)
                        } icon: {
                            Image(systemName: "location").foregroundStyle(Palette.textSecondary.color)
                        }
                        Spacer()
                        Text(location.statusLabel)
                            .foregroundStyle(Palette.textSecondary.color)
                    }
                }
                .listRowBackground(Palette.surface.color)
                .accessibilityIdentifier("permissions.location")
            } footer: {
                Text("Choose what this device shares with the model. Nothing is shared unless you allow it.")
            }
        }
        .connectorsList()
        .navigationTitle("Permissions")
        .connectorsInlineTitle()
        .task { await location.refresh() }
        .accessibilityIdentifier("settings.permissions")
    }
}

/// Settings › Permissions › Location: Never or Always, and what iOS allows.
struct LocationPermissionPage: View {
    let location: LocationSharing
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                ForEach(LocationSharing.Access.allCases, id: \.self) { access in
                    Button {
                        Task { await location.setAccess(access) }
                    } label: {
                        HStack {
                            Text(access.title).foregroundStyle(Palette.textPrimary.color)
                            Spacer()
                            if location.access == access {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Palette.accent.color)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.surface.color)
                    .accessibilityAddTraits(location.access == access ? .isSelected : [])
                    .accessibilityIdentifier("permissions.location.\(access.rawValue)")
                }
            } header: {
                Text("Share your location")
            } footer: {
                Text("When allowed, your approximate location (to about a kilometre) goes with each message, so the model can answer questions about places near you. It's sent to this Server and its model provider.")
            }
            if location.access == .always, location.authorization == .denied {
                Section {
                    Button("Open iOS Settings", systemImage: "gear") {
                        #if canImport(UIKit)
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        #endif
                    }
                    .foregroundStyle(Palette.textPrimary.color)
                    .listRowBackground(Palette.surface.color)
                    .accessibilityIdentifier("permissions.location.openSettings")
                } footer: {
                    Text("Location is turned off for Theseus in iOS Settings, so nothing is shared.")
                }
            } else if location.isSharing, let coordinate = location.coordinate {
                Section {
                    LabeledContent("Last shared", value: coordinate.promptValue.replacingOccurrences(of: " (lat, long)", with: ""))
                        .foregroundStyle(Palette.textPrimary.color)
                        .listRowBackground(Palette.surface.color)
                }
            }
        }
        .connectorsList()
        .navigationTitle("Location")
        .connectorsInlineTitle()
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await location.refresh() } }
        }
        .accessibilityIdentifier("settings.permissions.location")
    }
}

extension LocationSharing.Access {
    var title: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        }
    }
}

// The preview helpers (Previews.swift) exist in Debug builds only.
#if DEBUG
#Preview("Permissions") {
    NavigationStack {
        PermissionsPage(location: .preview)
    }
}

#Preview("Location") {
    NavigationStack {
        LocationPermissionPage(location: .preview)
    }
}
#endif
