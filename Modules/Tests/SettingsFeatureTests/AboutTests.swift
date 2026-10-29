import DesignSystem
import Foundation
@testable import SettingsFeature
import Testing

@Suite("About, legal & help (SET-11)")
struct AboutTests {
    @Test func versionComesFromTheAppBundle() {
        let info = AppInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"])
        #expect(info.version == "0.1.0 (7)")
        #expect(info.title == "Theseus 0.1.0 (7)")
        #expect(AppInfo(infoDictionary: nil).title == "Theseus")
    }

    @Test func linksOpenTheirWebPages() {
        #expect(AboutLink.allCases.map(\.url.scheme) == AboutLink.allCases.map { _ in "https" })
        #expect(AboutLink.help.url.host() == "docs.openwebui.com")
    }

    /// App Review 1.5 and 5.1.1(i): support and the privacy policy are reachable in the app.
    @Test func supportAndThePrivacyPolicyAreOnTheProjectWebsite() {
        let site = PublicLinks.website.absoluteString
        #expect(AboutLink.support.url.absoluteString == site + "support/")
        #expect(AboutLink.privacyPolicy.url.absoluteString == site + "privacy/")
        #expect(AboutLink.sourceCode.url == PublicLinks.repository)
        #expect(PublicLinks.supportMail.scheme == "mailto")
    }

    @Test func everyBundledLibraryIsAcknowledgedWithItsLicense() {
        let grdb = Acknowledgement.all.first { $0.name == "GRDB.swift" }
        #expect(grdb?.license.contains("Gwendal Roué") == true)
        #expect(grdb?.license.contains("Permission is hereby granted") == true)
        let names = Set(Acknowledgement.all.map(\.name))
        for expected in ["Swift Markdown", "cmark-gfm (swift-cmark)", "SwiftMath", "Math fonts (bundled with SwiftMath)",
                         "Mermaid and the libraries it bundles", "Departure Mono"] {
            #expect(names.contains(expected), "\(expected) is acknowledged")
        }
        #expect(Acknowledgement.all.allSatisfy { !$0.license.isEmpty && !$0.licenseName.isEmpty })
        let mermaid = Acknowledgement.all.first { $0.name.hasPrefix("Mermaid") }
        #expect(mermaid?.license.contains("dompurify") == true, "Mermaid's bundled packages are listed")
    }
}
