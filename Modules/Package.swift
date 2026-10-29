// swift-tools-version: 6.2
// Theseus feature modules. The app target in project.yml is a thin shell over `AppFeature`.
// Dependency direction (no cycles): ChatDomain ← OpenWebUIKit ← Auth ← AppFeature;
// ChatDomain ← Persistence ← AppFeature; DesignSystem ← AppFeature.
// DesignSystem ← ArtCollection (the paintings, ADR 0140) ← OnboardingFeature, ComposerFeature, ChatFeature,
// LibraryFeature, ProjectsFeature, PersonalizationFeature, SettingsFeature, AppFeature; never linked by the extensions.
// Feature areas get their own targets below AppFeature (e.g. LibraryFeature, OnboardingFeature ← AppFeature).
// DesignSystem ← Rendering ← ChatFeature (+ ChatDomain, OpenWebUIKit) ← AppFeature.
// ComposerFeature (+ ChatDomain, OpenWebUIKit, DesignSystem) ← ChatFeature: the composer, home greeting,
// model picker and Attachments.
// ChatFeature ← MessageActionsFeature ← AppFeature (plugs in through `\.messageAccessories`).
// ComposerFeature + SettingsFeature ← ConnectorsFeature ← AppFeature: Connectors, the directory and
// Permissions; plugs into Settings (`SettingsExtensions`) and Add to Chat (`AddToChatExtensions`).
// ChatFeature + MessageActionsFeature + SettingsFeature ← VoiceFeature ← AppFeature (Dictation and Voice
// mode plug in through `\.conversationVoice` / `\.composerVoice`, ADR 0081).
// ChatFeature ← ArtifactsFeature ← AppFeature (plugs in through `\.transcriptExtensions`, ADR 0060).
// Persistence ← AppIntentsFeature ← AppFeature, and ← the widget and Share extensions (project.yml).
// ChatFeature + ComposerFeature ← SandboxFeature ← AppFeature: Open Terminal runs, files, the file
// browser and sandbox uploads (epic #139, ADR 0120); plugs in through `\.transcriptExtensions`.
// DesignSystem ← Entitlements (Theseus Pro: the store, the free sandbox allowance, the paywall seam;
// ADR 0173) ← ComposerFeature, SettingsFeature, OnboardingFeature, AppFeature. Extension-safe.
// Entitlements + ArtCollection ← PaywallFeature (the paywall sheet) ← AppFeature.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Modules",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AppFeature", targets: ["AppFeature"]),
        .library(name: "OnboardingFeature", targets: ["OnboardingFeature"]),
        .library(name: "LibraryFeature", targets: ["LibraryFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "PersonalizationFeature", targets: ["PersonalizationFeature"]),
        .library(name: "ProjectsFeature", targets: ["ProjectsFeature"]),
        .library(name: "OpenWebUIKit", targets: ["OpenWebUIKit"]),
        .library(name: "ChatDomain", targets: ["ChatDomain"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Auth", targets: ["Auth"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "ArtCollection", targets: ["ArtCollection"]),
        .library(name: "Rendering", targets: ["Rendering"]),
        .library(name: "ChatFeature", targets: ["ChatFeature"]),
        .library(name: "ComposerFeature", targets: ["ComposerFeature"]),
        .library(name: "MessageActionsFeature", targets: ["MessageActionsFeature"]),
        .library(name: "ConnectorsFeature", targets: ["ConnectorsFeature"]),
        .library(name: "VoiceFeature", targets: ["VoiceFeature"]),
        .library(name: "ArtifactsFeature", targets: ["ArtifactsFeature"]),
        .library(name: "AppIntentsFeature", targets: ["AppIntentsFeature"]),
        .library(name: "SandboxFeature", targets: ["SandboxFeature"]),
        .library(name: "Entitlements", targets: ["Entitlements"]),
        .library(name: "PaywallFeature", targets: ["PaywallFeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        // Rendering (ADR 0010): cmark-gfm parser + native LaTeX.
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        // MARK: Libraries
        .target(name: "ChatDomain", swiftSettings: swiftSettings),
        .target(name: "OpenWebUIKit", dependencies: ["ChatDomain"], swiftSettings: swiftSettings),
        .target(
            name: "Persistence",
            dependencies: ["ChatDomain", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swiftSettings
        ),
        .target(name: "Auth", dependencies: ["OpenWebUIKit"], swiftSettings: swiftSettings),
        // Fonts/: Departure Mono (SIL OFL 1.1) for plaques, registered at runtime (ADR 0140).
        .target(name: "DesignSystem", resources: [.copy("Resources/Fonts")], swiftSettings: swiftSettings),
        // Theseus Pro (ADR 0173): the one-time unlock (StoreKit 2), the free sandbox allowance and
        // the paywall seam (`paywallContent`, `.paywall(_:)`) every gate presents through.
        .target(name: "Entitlements", dependencies: ["DesignSystem"], swiftSettings: swiftSettings),
        // The paywall sheet and its thank-you state (ADR 0173).
        .target(
            name: "PaywallFeature",
            dependencies: ["Entitlements", "DesignSystem", "ArtCollection"],
            swiftSettings: swiftSettings
        ),
        // The Collection (ADR 0140): public-domain paintings, their credits and framed presentation.
        // Its own target so the widget extension, which links DesignSystem, never carries the art.
        .target(
            name: "ArtCollection",
            dependencies: ["DesignSystem"],
            resources: [.copy("Resources/Art")],
            swiftSettings: swiftSettings
        ),
        // The signed-out experience: Server connection, sign-in methods, verification, SSO, Accounts.
        .target(
            name: "OnboardingFeature",
            dependencies: ["OpenWebUIKit", "ChatDomain", "Auth", "DesignSystem", "ArtCollection", "Entitlements"],
            swiftSettings: swiftSettings
        ),
        // Chats library Feature area: drawer, Chats list, search, star/rename/delete (CHATS-*).
        .target(
            name: "LibraryFeature",
            dependencies: ["OpenWebUIKit", "ChatDomain", "Persistence", "DesignSystem", "ArtCollection"],
            swiftSettings: swiftSettings
        ),
        // Settings Feature area: the Settings sheet and its pages (SET-*).
        .target(
            name: "SettingsFeature",
            dependencies: ["OpenWebUIKit", "ChatDomain", "Auth", "DesignSystem", "ArtCollection", "Entitlements"],
            // BRAND-02: the App Icon picker's thumbnails (scripts/brand/gen_app_icons.py).
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        // Memory & personalization Feature area: Profile, Instructions, Memory (PERS-*). Its pages
        // plug into the Settings sheet through `SettingsExtensions`.
        .target(
            name: "PersonalizationFeature",
            // ComposerFeature: Choose style plugs into Add to Chat (PERS-05, `AddToChatExtensions`).
            dependencies: ["OpenWebUIKit", "ChatDomain", "DesignSystem", "SettingsFeature", "ComposerFeature", "ArtCollection"],
            swiftSettings: swiftSettings
        ),
        // Projects Feature area: Projects list, detail, Instructions, Knowledge, Add to project (PROJ-*).
        .target(
            name: "ProjectsFeature",
            dependencies: ["OpenWebUIKit", "ChatDomain", "DesignSystem", "LibraryFeature", "ArtCollection"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Rendering",
            dependencies: [
                "DesignSystem",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            swiftSettings: swiftSettings
        ),
        // Home & composer, Models & effort and Attachments Feature areas (HOME-*, MODEL-*, ATT-*).
        .target(
            name: "ComposerFeature",
            dependencies: ["ChatDomain", "OpenWebUIKit", "DesignSystem", "ArtCollection", "Entitlements"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ChatFeature",
            dependencies: ["ChatDomain", "OpenWebUIKit", "Rendering", "DesignSystem", "ComposerFeature", "ArtCollection"],
            swiftSettings: swiftSettings
        ),
        // Message actions Feature area: action row, copy, retry, Branches, edit, feedback, read aloud, share (MSG-*).
        .target(
            name: "MessageActionsFeature",
            dependencies: ["ChatFeature", "ChatDomain", "OpenWebUIKit", "DesignSystem", "Rendering"],
            swiftSettings: swiftSettings
        ),
        // Connectors & tools Feature area: Connectors, the directory, connect/disconnect and
        // device Permissions (CONN-*).
        .target(
            name: "ConnectorsFeature",
            dependencies: ["OpenWebUIKit", "ChatDomain", "DesignSystem", "ComposerFeature", "SettingsFeature", "Entitlements"],
            swiftSettings: swiftSettings
        ),
        // Platform Feature area (PLAT-*): deep links, App Intents and the shared-container contract
        // the widgets and Share extension use. Extension-safe: no UI feature modules (ADR 0100).
        .target(
            name: "AppIntentsFeature",
            dependencies: ["Persistence"],
            swiftSettings: swiftSettings
        ),
        // Voice Feature area: Dictation, Voice mode, push to talk, mute, Voice settings (VOICE-*).
        .target(
            name: "VoiceFeature",
            dependencies: [
                "ChatFeature", "ComposerFeature", "ChatDomain", "OpenWebUIKit", "DesignSystem", "SettingsFeature",
                "MessageActionsFeature",
            ],
            swiftSettings: swiftSettings
        ),
        // Artifacts Feature area: Artifact cards, the sandboxed viewer, versions, the library (ART-*, ADR 0060).
        .target(
            name: "ArtifactsFeature",
            dependencies: ["ChatFeature", "ChatDomain", "OpenWebUIKit", "Rendering", "DesignSystem", "LibraryFeature"],
            resources: [.copy("Resources/mermaid")],
            swiftSettings: swiftSettings
        ),
        // Open Terminal Feature area (epic #139): sandbox runs, created files, the file browser and
        // sandbox uploads (OT-*, ADR 0120).
        .target(
            name: "SandboxFeature",
            dependencies: ["ChatFeature", "ComposerFeature", "ChatDomain", "OpenWebUIKit", "DesignSystem", "Entitlements"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AppFeature",
            dependencies: [
                "OpenWebUIKit", "ChatDomain", "Persistence", "Auth", "DesignSystem", "LibraryFeature", "SettingsFeature",
                "ChatFeature", "PersonalizationFeature", "OnboardingFeature", "ProjectsFeature", "MessageActionsFeature",
                "ComposerFeature", "ConnectorsFeature", "VoiceFeature", "ArtifactsFeature", "AppIntentsFeature",
                "SandboxFeature", "ArtCollection", "Entitlements", "PaywallFeature",
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Test support (recorded Open WebUI fixtures + stub transport)
        .target(
            name: "Fixtures",
            dependencies: ["OpenWebUIKit"],
            path: "Tests/Fixtures",
            exclude: ["README.md"],
            resources: [.copy("open-webui-0.12.3")],
            swiftSettings: swiftSettings
        ),

        // MARK: Tests
        .testTarget(name: "ChatDomainTests", dependencies: ["ChatDomain"], swiftSettings: swiftSettings),
        .testTarget(
            name: "OpenWebUIKitTests",
            dependencies: ["OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", "ChatDomain"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "AuthTests", dependencies: ["Auth", "Fixtures"], swiftSettings: swiftSettings),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], swiftSettings: swiftSettings),
        .testTarget(name: "EntitlementsTests", dependencies: ["Entitlements"], swiftSettings: swiftSettings),
        .testTarget(name: "PaywallFeatureTests", dependencies: ["PaywallFeature", "Entitlements"], swiftSettings: swiftSettings),
        .testTarget(name: "ArtCollectionTests", dependencies: ["ArtCollection", "DesignSystem"], swiftSettings: swiftSettings),
        .testTarget(
            name: "OnboardingFeatureTests",
            dependencies: ["Entitlements", "OnboardingFeature", "Auth", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "RenderingTests",
            dependencies: ["Rendering"],
            resources: [.copy("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ChatFeatureTests",
            dependencies: ["Entitlements", "ChatFeature", "ChatDomain", "OpenWebUIKit", "DesignSystem", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ComposerFeatureTests",
            dependencies: ["Entitlements", "ComposerFeature", "ChatDomain", "OpenWebUIKit", "ArtCollection", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MessageActionsFeatureTests",
            dependencies: ["MessageActionsFeature", "ChatFeature", "ChatDomain", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ConnectorsFeatureTests",
            dependencies: ["ConnectorsFeature", "ComposerFeature", "SettingsFeature", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppIntentsFeatureTests",
            dependencies: ["AppIntentsFeature", "Persistence"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VoiceFeatureTests",
            dependencies: ["Entitlements", "VoiceFeature", "ChatFeature", "ComposerFeature", "ChatDomain", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ArtifactsFeatureTests",
            dependencies: ["ArtifactsFeature", "ChatFeature", "ChatDomain", "OpenWebUIKit", "Rendering", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SandboxFeatureTests",
            dependencies: ["Entitlements", "SandboxFeature", "ChatFeature", "ComposerFeature", "ChatDomain", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppFeatureTests",
            dependencies: ["Entitlements", "AppFeature", "AppIntentsFeature", "Persistence", "OnboardingFeature", "Auth", "OpenWebUIKit", "SettingsFeature", "ProjectsFeature", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "LibraryFeatureTests",
            dependencies: ["LibraryFeature", "Persistence", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SettingsFeatureTests",
            dependencies: ["Entitlements", "SettingsFeature", "Auth", "OpenWebUIKit", "ArtCollection", "DesignSystem", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PersonalizationFeatureTests",
            dependencies: ["PersonalizationFeature", "OpenWebUIKit", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ProjectsFeatureTests",
            dependencies: ["ProjectsFeature", "OpenWebUIKit", "ChatDomain", "ArtCollection", "Fixtures"],
            swiftSettings: swiftSettings
        ),
        // Opt-in: runs only with THESEUS_INTEGRATION=1 and a filled-in repo-root .env.
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Auth", "OpenWebUIKit", "ChatDomain", "ChatFeature", "ConnectorsFeature", "LibraryFeature", "Persistence"],
            swiftSettings: swiftSettings
        ),
    ]
)
