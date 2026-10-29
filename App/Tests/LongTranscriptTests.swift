import ArtifactsFeature
import ChatDomain
import ChatFeature
import Foundation
import OpenWebUIKit
import SwiftUI
import Testing
import UIKit

/// A long Chat's transcript on a real screen (#196, #197), with the app's Artifacts hooks: it opens
/// at the bottom without settling, and scrolling through it never moves what's on screen by more
/// or less than the scroll. Finished prose is a `UITextView` (`response.prose`, ADR 0150), so each
/// one marks where a Response is drawn.
@MainActor
@Suite("Long transcript", .serialized)
struct LongTranscriptTests {
    @Test func opensAtTheBottomWithoutSettling() async throws {
        let host = try await TranscriptHost.open()
        defer { host.close() }
        var distances: [CGFloat] = []
        var lastMarker: [CGFloat] = []
        for _ in 0..<45 {
            try await Task.sleep(for: .milliseconds(16))
            host.pump()
            distances.append(host.distanceFromBottom)
            if let bottom = host.visibleMarkers().values.map(\.minY).max() { lastMarker.append(bottom) }
        }
        print("[transcript] open \(host.openTime) distances \(Set(distances.map { Int($0.rounded()) }))")
        #expect(distances.allSatisfy { abs($0) <= 2 }, "opened away from the bottom: \(distances)")
        let spread = (lastMarker.max() ?? 0) - (lastMarker.min() ?? 0)
        #expect(spread <= 1, "the last Response moved \(spread) pt after the Chat opened")
    }

    /// Steps of about half a screen (a fling's frames) and of a slow drag's, all the way up and
    /// down, and a re-read: 15 screens up and back at drag speed.
    @Test(arguments: [(0.45, 0.0), (0.05, 0.0), (0.05, 15.0)])
    func scrollingThroughNeverJumps(screens: Double, excursion: Double) async throws {
        let host = try await TranscriptHost.open()
        defer { host.close() }
        // The opened Chat settles at its end first; a real touch would stop that at once, but these
        // steps scroll without one.
        try await Task.sleep(for: .milliseconds(400))
        host.pump()
        let scroll = host.transcript
        let step = scroll.bounds.height * screens
        var jumps: [String] = []
        var steps = 0
        var downward = false
        var largestDownwardJump: CGFloat = 0
        var travelled: CGFloat = 0

        func move(by delta: CGFloat) async throws -> Bool {
            let top = -scroll.adjustedContentInset.top
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            let from = scroll.contentOffset.y
            let to = min(max(from + delta, top), max(bottom, top))
            guard abs(to - from) > 0.5 else { return false }
            let before = host.visibleMarkers()
            let sizeBefore = scroll.contentSize.height
            scroll.contentOffset.y = to
            host.pump()
            let now = host.visibleMarkers()
            let context = "offset \(Int(from))→\(Int(to)) now \(Int(scroll.contentOffset.y)) size \(Int(sizeBefore))→\(Int(scroll.contentSize.height)) markers \(before.count)/\(now.count)"
            try await Task.sleep(for: .milliseconds(screens < 0.1 ? 4 : 20))
            host.pump()
            let later = host.visibleMarkers()
            steps += 1
            // What's on screen moves by the scroll: down when scrolling up.
            let expected = from - to
            travelled += abs(expected)
            // Less than a screen apart, the views on screen before and after overlap: none in common
            // means the content moved under them.
            let visible = scroll.convert(scroll.bounds, to: host.window).insetBy(dx: 0, dy: 20)
            for (key, frame) in before where !downward && now[key] == nil && frame.offsetBy(dx: 0, dy: expected).intersects(visible) {
                let views = host.window.descendants(UITextView.self).filter { String($0.text.prefix(80)) == key }
                let state = views.map { "window \($0.window != nil) hidden \($0.isHidden) alpha \($0.alpha) frame \($0.convert($0.bounds, to: host.window).integral) super \($0.superview.map { String(describing: type(of: $0)) } ?? "-")" }
                jumps.append("step \(steps): a Response that stays on screen vanished, predicted \(frame.offsetBy(dx: 0, dy: expected).integral), now \(state) (\(context))")
                break
            }
            for (moment, markers) in [("at once", now), ("a frame later", later)] {
                for (id, frame) in markers {
                    guard let was = before[id] else { continue }
                    let moved = frame.minY - was.minY
                    if abs(moved - expected) > 1 {
                        if downward {
                            largestDownwardJump = max(largestDownwardJump, abs(moved - expected))
                            continue
                        }
                        jumps.append("step \(steps) \(moment): moved \(Int(moved)) for a scroll of \(Int(expected)) (\(context))")
                    }
                }
            }
            return true
        }

        // Bounded: estimated content can grow as fast as it's scrolled.
        let stepsUp = excursion > 0 ? Int(excursion / screens) : 4000
        while steps < stepsUp, try await move(by: -step) {}
        if excursion == 0 {
            #expect(scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5, "reached the top")
        }
        let up = steps
        let travelledUp = travelled
        travelled = 0
        // Back down after reading all the way up, the lazy stack corrects its estimates of the
        // rows it dropped above, and what's on screen can shift by a few hundred points a few
        // times (#197: accepted; a re-read and scrolling up never do). Bounded here.
        downward = excursion == 0
        while steps < 8000, try await move(by: step) {}
        // The same content top to bottom as bottom to top: anything else moved unseen.
        #expect(abs(travelled - travelledUp) < scroll.bounds.height, "travelled \(Int(travelledUp)) pt up but \(Int(travelled)) pt down")
        host.pump()
        #expect(abs(host.distanceFromBottom) <= 2, "reached the end: \(host.distanceFromBottom) pt away")
        print("[transcript] excursion \(excursion) steps of \(Int(step)) pt: \(up) up, \(steps - up) down, \(jumps.count) jumps")
        for jump in jumps { print("[jump] \(jump)") }
        print("[transcript] largest shift scrolling back down: \(Int(largestDownwardJump)) pt")
        #expect(largestDownwardJump < scroll.bounds.height * 0.75, "scrolling back down shifted \(Int(largestDownwardJump)) pt")
        #expect(jumps.isEmpty, "\(jumps.prefix(8))")
    }

    /// The cost of a Chat this long, for comparing changes to the transcript (not asserted).
    @Test func costs() async throws {
        let host = try await TranscriptHost.open()
        defer { host.close() }
        let clock = ContinuousClock()
        let frame = host.window.frame
        let resize = clock.measure {
            host.window.frame.size.width = frame.width - 60
            host.pump()
            host.window.frame = frame
            host.pump()
        }
        print("[transcript] open \(host.openTime) resize twice \(resize) markers \(host.allMarkers)")
    }
}

/// The app's Chat screen in its own window, showing `chat.long.json` loaded through the real
/// client from a canned transport.
@MainActor
final class TranscriptHost {
    let window: UIWindow
    let conversation: ConversationModel
    private(set) var openTime = Duration.zero

    private init(window: UIWindow, conversation: ConversationModel) {
        self.window = window
        self.conversation = conversation
    }

    static func open() async throws -> TranscriptHost {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "chat.long", withExtension: "json"))
        let document = try Data(contentsOf: url)
        let chatID = "00000000-0000-4000-8000-00000000c197"
        let client = OpenWebUIClient(
            server: URL(string: "https://example.invalid")!,
            transport: CannedTransport(routes: ["GET /api/v1/chats/\(chatID)": document]),
            authorizer: CannedToken()
        )
        let model = Model(id: "claude-opus-5-5", name: "Claude Opus")
        let services = ChatServices(
            client: client,
            session: CompletionSession(client: client, socket: nil),
            models: [model],
            defaultModelID: model.id
        ) { _ in Capabilities(enabled: Set(Capability.allCases)) }
        let conversation = services.conversation(chatID: chatID)
        let gate = Gate()
        let root = Shell(gate: gate, conversation: conversation)
            .environment(services)
            .environment(\.transcriptExtensions, Artifacts.transcriptExtensions)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        // Above the app's own window, so it's really on screen: lazy stacks only realize what's
        // displayed.
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        let host = TranscriptHost(window: window, conversation: conversation)
        host.pump()
        try await Task.sleep(for: .milliseconds(100))

        // Tap the Chat: from the route change until its transcript is drawn.
        let clock = ContinuousClock()
        let start = clock.now
        gate.isOpen = true
        host.pump()
        while host.allMarkers == 0, clock.now - start < .seconds(10) {
            // Sleep, not yield: SwiftUI updates from run loop observers, which only run when the
            // main queue goes idle.
            try await Task.sleep(for: .milliseconds(2))
            host.pump()
        }
        host.openTime = clock.now - start
        try #require(host.allMarkers > 0, "the transcript never appeared: \(host.diagnostics)")
        return host
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func pump() {
        window.layoutIfNeeded()
        CATransaction.flush()
    }

    var transcript: UIScrollView {
        let scrolls = window.descendants(UIScrollView.self).filter { !($0 is UITextView) }
        return scrolls.first { $0.accessibilityIdentifier == "conversation.transcript" }
            ?? scrolls.max { $0.contentSize.height < $1.contentSize.height }!
    }

    /// Points between the visible bottom (above the composer) and the end of the content.
    var distanceFromBottom: CGFloat {
        let scroll = transcript
        return scroll.contentSize.height + scroll.adjustedContentInset.bottom - (scroll.contentOffset.y + scroll.bounds.height)
    }

    var allMarkers: Int { proseViews().count }

    /// What the transcript shows, for failure messages.
    var diagnostics: String {
        let scroll = transcript
        snapshot("/tmp/transcript-diagnostics.png")
        let texts = window.descendants(UITextView.self).map { "\($0.accessibilityIdentifier ?? "-")@\(Int($0.convert($0.bounds, to: window).minY))" }
        return "offset \(scroll.contentOffset.y) size \(scroll.contentSize) bounds \(scroll.bounds.size) insets \(scroll.adjustedContentInset) thread \(conversation.thread.count) load \(conversation.loadState) texts \(texts.prefix(12))"
    }

    /// The top of each finished-prose view on screen, in window points, by its text (an object's
    /// address can be reused by a new view once a lazy row is dropped).
    func visibleMarkers() -> [String: CGRect] {
        let scroll = transcript
        let visible = scroll.convert(scroll.bounds, to: window)
        var markers: [String: CGRect] = [:]
        for view in proseViews() {
            let frame = view.convert(view.bounds, to: window)
            guard frame.intersects(visible), frame.height > 0 else { continue }
            markers[String(view.text.prefix(80))] = frame
        }
        return markers
    }

    /// Writes what the window shows (for diagnosing a failure).
    func snapshot(_ path: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.jpegData(compressionQuality: 0.6)?.write(to: URL(filePath: path))
    }

    private func proseViews() -> [UITextView] {
        window.descendants(UITextView.self).filter { $0.accessibilityIdentifier == "response.prose" && $0.window != nil && !$0.isHidden }
    }
}

@MainActor @Observable private final class Gate {
    var isOpen = false
}

private struct Shell: View {
    let gate: Gate
    let conversation: ConversationModel

    var body: some View {
        NavigationStack {
            if gate.isOpen { ConversationView(model: conversation) } else { Color.clear }
        }
    }
}

private final class BundleToken {}

private final class CannedTransport: HTTPTransport {
    let routes: [String: Data]

    init(routes: [String: Data]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let body = routes[key]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (body ?? Data(#"{"detail":"Not Found"}"#.utf8), response)
    }
}

private final class CannedToken: RequestAuthorizer {
    func currentToken() async -> String? { "jwt" }
    func renewToken(rejected: String) async throws -> String { "jwt" }
}

extension UIView {
    func descendants<T: UIView>(_ type: T.Type) -> [T] {
        subviews.flatMap { subview in ((subview as? T).map { [$0] } ?? []) + subview.descendants(type) }
    }
}
