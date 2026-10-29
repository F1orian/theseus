import ChatDomain

/// The drawer's Recents (#172): the newest Chats that aren't starred, then "See all", which opens
/// the full-screen Chats list (CHATS-02) with its search and paging.
///
/// The drawer lists twenty Recents before "See all" (the owner's choice), so the
/// drawer scrolls about two iPhone screens of history before "See all". It still never pages
/// through the Account's history itself.
struct DrawerRecents {
    static let limit = 20

    /// The rows to list, newest first.
    let shown: [ChatSummary]
    /// More Chats exist than `shown`: locally, or on the Server's next pages.
    let showsSeeAll: Bool

    init(_ recents: [ChatSummary], hasMore: Bool = false) {
        shown = Array(recents.prefix(Self.limit))
        showsSeeAll = recents.count > Self.limit || hasMore
    }
}
