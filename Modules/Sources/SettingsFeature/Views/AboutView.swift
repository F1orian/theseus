import ArtCollection
import DesignSystem
import SwiftUI

/// The Settings info button (SET-11): a menu headed by the app version with help, project links,
/// privacy and acknowledgements. Links open in the in-app browser.
struct AboutMenu: View {
    let model: SettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Section(AppInfo.current.title) {
                Button("About Theseus", systemImage: "info.circle") { model.open(.about) }
                    .accessibilityIdentifier("about.menu.about")
                ForEach(AboutLink.allCases, id: \.self) { link in
                    Button(link.title, systemImage: link.systemImage) { openURL(link.url) }
                }
                Button("The Collection", systemImage: "photo.artframe") { model.open(.collection) }
                    .accessibilityIdentifier("about.menu.collection")
                Button("Data & privacy", systemImage: "lock.shield") { model.open(.dataPrivacy) }
                Button("Acknowledgements", systemImage: "doc.text") { model.open(.acknowledgements) }
                    .accessibilityIdentifier("about.menu.acknowledgements")
            }
        } label: {
            Label("About", systemImage: "info")
        }
        .tint(Palette.textPrimary.color)
        .accessibilityIdentifier("settings.info")
    }
}

/// About Theseus: the lockup, the app and Server versions, The Collection (BRAND-04) and the
/// project links.
struct AboutView: View {
    let serverName: String
    let serverVersion: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: Spacing.m) {
                    // The brand lockup (brand.md §3): the sitting mouse and the wordmark.
                    BrandLockup(size: 34)
                        .mouseBackdrop()
                        .accessibilityAddTraits(.isHeader)
                    Text("A native client for your Open WebUI Server, named after Claude Shannon's maze-solving mouse.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary.color)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .listRowBackground(Color.clear)
            }
            Section {
                SettingsValueRow(title: "Version", value: AppInfo.current.version ?? "—")
                    .accessibilityIdentifier("about.version")
                SettingsValueRow(title: serverName, value: serverVersion ?? "—")
            }
            Section {
                NavigationLink(value: SettingsPage.collection) {
                    CollectionRowLabel()
                }
                .settingsRowBackground()
                .accessibilityIdentifier("about.collection")
            } footer: {
                Text("The paintings in Theseus and behind its icons, with their museums, and the typeface on its plaques.")
            }
            Section {
                ForEach(AboutLink.allCases, id: \.self) { link in
                    Link(destination: link.url) {
                        SettingsRowLabel(title: link.title, systemImage: link.systemImage)
                    }
                    .settingsRowBackground()
                }
                NavigationLink(value: SettingsPage.acknowledgements) {
                    SettingsRowLabel(title: "Acknowledgements", systemImage: "doc.text")
                }
                .settingsRowBackground()
            } footer: {
                Text("Theseus is independent and not affiliated with the Open WebUI project.")
            }
        }
        .settingsList()
        .navigationTitle("About")
        .settingsInlineTitle()
        .accessibilityIdentifier("settings.about")
    }
}

/// The row into The Collection: Zeshin's *Mouse*, framed small, beside the title.
private struct CollectionRowLabel: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            FramedArtwork(.mascotOrigin, height: 44, aspectRatio: 0.85, mat: 3)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("The Collection")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary.color)
                Text(ui: "\(Artwork.all.count) works · Departure Mono")
                    .plaqueStyle()
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › About › The Collection (BRAND-04): "Lineage, not imitation" (Zeshin's *Mouse* beside
/// the sitting sprite), every artwork with its plaque and a "View at <museum>" link, the app icons'
/// paintings, and the Departure Mono licence.
struct CollectionView: View {
    var body: some View {
        List {
            CollectionCreditsList()
                .settingsRowBackground()
        }
        .settingsList()
        .navigationTitle("The Collection")
        .settingsInlineTitle()
        .accessibilityIdentifier("settings.collection")
    }
}

/// Third-party software and fonts with their licences (`scripts/legal/gen_acknowledgements.py`).
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                ForEach(Acknowledgement.all) { item in
                    NavigationLink {
                        AcknowledgementDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(item.name)
                                .font(Typography.body)
                                .foregroundStyle(Palette.textPrimary.color)
                            Text([item.version, item.licenseName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary.color)
                        }
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier("acknowledgement.\(item.name)")
                }
            } footer: {
                Text("Theseus is built with this open-source software. The paintings and their credits are in The Collection.")
            }
        }
        .settingsList()
        .navigationTitle("Acknowledgements")
        .settingsInlineTitle()
        .accessibilityIdentifier("settings.acknowledgements")
    }
}

/// One acknowledgement's licence text.
private struct AcknowledgementDetailView: View {
    let item: Acknowledgement

    var body: some View {
        List {
            if let url = item.url {
                Section {
                    Link(destination: url) {
                        SettingsRowLabel(title: url.host() ?? url.absoluteString, systemImage: "safari")
                    }
                    .settingsRowBackground()
                }
            }
            Section(item.licenseName) {
                Text(item.license)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Palette.textSecondary.color)
                    .textSelection(.enabled)
                    .settingsRowBackground()
            }
        }
        .settingsList()
        .navigationTitle(item.name)
        .settingsInlineTitle()
    }
}
