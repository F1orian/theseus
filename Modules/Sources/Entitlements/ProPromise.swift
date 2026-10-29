public import Foundation

/// What Theseus promises with Pro, shown on the paywall and on Settings › Theseus Pro
/// (ADR 0173). Every line has to stay true: Theseus has no backend, no analytics and no ads.
public enum ProPromise {
    public struct Item: Identifiable, Sendable, Hashable {
        public let title: String
        public let detail: String
        public let systemImage: String
        public var id: String { title }
    }

    public static let items: [Item] = [
        Item(title: "No ads", detail: "Not now, not later.", systemImage: "rectangle.slash"),
        Item(
            title: "No tracking",
            detail: "No analytics and no third-party SDKs. Theseus collects nothing; your chats go only to your Server.",
            systemImage: "eye.slash"
        ),
        Item(
            title: "No subscription",
            detail: "One purchase, with every future update included.",
            systemImage: "infinity"
        ),
        Item(
            title: "No account",
            detail: "Pro belongs to your Apple Account, on all your devices, and Family Sharing shares it.",
            systemImage: "person.crop.circle.badge.checkmark"
        ),
    ]

    /// The public source code (GPL-3.0, #181). Set it to `nil` to hide the "The code is public" line.
    public static let sourceCodeURL: URL? = URL(string: "https://github.com/F1orian/theseus")

    /// The line that links `sourceCodeURL`.
    public static let sourceCodeItem = Item(
        title: "Open source",
        detail: "The code is public, so you can check every word of this.",
        systemImage: "chevron.left.forwardslash.chevron.right"
    )

    /// Apple's standard licence agreement, which covers the purchase.
    public static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
}
