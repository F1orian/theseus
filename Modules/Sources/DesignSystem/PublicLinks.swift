public import Foundation

/// Where Theseus itself can be reached: the public repository, its website (landing page, privacy
/// policy and support: the static pages in `site/`, deployed to unru.sh/theseus) and the support
/// email (App Review 1.5, 5.1.1(i)).
///
/// **Release:** these are the only copies in the app. The pages in `site/` repeat the email and the
/// repository; `scripts/release/preflight` refuses a Release build while a placeholder is left or
/// they disagree.
public enum PublicLinks {
    /// The public GitHub repository: source code and issues.
    public static let repository = url("https://github.com/F1orian/theseus")
    /// The project website (`site/`, static hosting).
    public static let website = url("https://unru.sh/theseus/")
    /// The address on the support page and in the privacy policy.
    public static let supportEmail = "theseus@unru.sh"

    /// The privacy policy (`site/privacy/index.html`).
    public static var privacyPolicy: URL { website.appending(path: "privacy/") }
    /// Support: contact and where to report a problem (`site/support/index.html`).
    public static var support: URL { website.appending(path: "support/") }
    /// A new email to support.
    public static var supportMail: URL { url("mailto:\(supportEmail)") }

    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}
