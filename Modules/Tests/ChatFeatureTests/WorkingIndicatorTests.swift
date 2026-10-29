#if canImport(AppKit)
import AppKit
@testable import ChatFeature
import ChatDomain
@testable import DesignSystem
import Observation
import SwiftUI
import Testing

/// #194: the tail showed its plaque (THINKING…) with no mouse. The scene swap was sequenced
/// with a `phaseAnimator` (blank, then fade in); a new trigger while its blank phase was still
/// up left the mouse at opacity 0 until the next change. The tail now cross-fades two
/// fixed-position layers whose opacities follow from state alone, so the mouse can't end hidden
/// while there's work, whatever the order or timing of the changes.
@Suite("The working mouse never vanishes (#194)", .serialized)
@MainActor
struct WorkingIndicatorTests {
    // MARK: The layers

    @Test func theFrontLayerAlwaysHoldsTheLatestSceneAtFullOpacity() {
        var layers = SceneLayers(.thinking)
        var random = SystemRandomNumberGenerator()
        let scenes = WorkingMouse.Scene.allCases
        for _ in 0..<500 {
            let scene = scenes.randomElement(using: &random)!
            let before = layers
            layers.show(scene)
            #expect(layers[layers.front] == scene)
            #expect(layers.opacity(of: layers.front) == 1)
            #expect(layers.opacity(of: layers.front.other) == 0, "one mouse: the other layer is hidden")
            if before[before.front] == scene {
                #expect(layers == before, "the same scene again changes nothing")
            } else {
                #expect(layers.front != before.front, "a new scene comes in on the other layer")
                #expect(layers[layers.front.other] == before[before.front], "the old scene fades out where it was")
            }
        }
    }

    @Test func backToTheSceneThatIsFadingOutFlipsBack() {
        var layers = SceneLayers(.thinking)
        layers.show(.webSearch)
        layers.show(.thinking)
        #expect(layers.front == .a)
        #expect(layers[.a] == .thinking)
        #expect(layers[.b] == .webSearch)
    }

    // MARK: Hosted, frame by frame

    /// The plaque's text, drawn right of the mouse; and the mouse itself.
    private static let size = CGSize(width: 320, height: 60)
    private static let mouseRect = CGRect(x: 10, y: 14, width: 68, height: 32)
    private static let plaqueRect = CGRect(x: 88, y: 10, width: 230, height: 40)

    /// The faintest scene's ink (its still frame), the floor for "the mouse is drawn".
    private static func faintestScene() throws -> Double {
        var faintest = Double.infinity
        for scene in WorkingMouse.Scene.allCases {
            let view = PettableMouse(.working(scene, label: ""), scale: 2, isAnimating: false)
                .frame(width: 68, height: 28)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let ink = Pixels(image, points: CGSize(width: 68, height: 28)).ink(in: CGRect(x: 0, y: 0, width: 68, height: 28))
            faintest = min(faintest, ink)
        }
        return faintest
    }

    /// The faintest frame of `scene`'s loop.
    private static func faintestFrame(of scene: WorkingMouse.Scene) throws -> Double {
        var faintest = Double.infinity
        let palette = WorkingMouse.palette(for: AccentSelection.shared.choice)
        for sprite in WorkingMouse.sprites(scene, size: .compact) {
            let view = SpriteCanvas(sprite: sprite, scale: 2, palette: palette)
                .frame(width: 68, height: 28)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            faintest = min(faintest, Pixels(image, points: CGSize(width: 68, height: 28)).ink(in: CGRect(x: 0, y: 0, width: 68, height: 28)))
        }
        return faintest
    }

    private struct Step {
        let work: ResponseActivity.Work
        /// How long to sample before the next change; 0 changes again in the same run-loop turn.
        let wait: Int
    }

    /// Drives the hosted tail through `steps`, sampling every frame: whenever the plaque is
    /// drawn, the mouse is too (at least 30% of the faintest scene, so a cross-fade passes and
    /// an invisible mouse doesn't). Settled at the end, it's fully there.
    private func drive(_ steps: [Step], name: String) async throws {
        let faintest = try Self.faintestScene()
        let driver = IndicatorDriver(steps.first?.work)
        let probe = HostingProbe(IndicatorHost(driver: driver), size: Self.size)
        var evidence = ProbeEvidence("indicator-\(name)")
        var failures: [String] = []
        var frame = 0
        func check(_ pixels: Pixels, _ label: String) {
            let plaque = pixels.ink(in: Self.plaqueRect)
            let mouse = pixels.ink(in: Self.mouseRect)
            let visible = mouse >= 0.3 * faintest
            if plaque > 2, !visible { failures.append("\(label) frame \(frame): plaque \(Int(plaque)) but mouse \(Int(mouse)) (< \(Int(0.3 * faintest)))") }
            evidence.save(pixels, note: visible ? "" : "HIDDEN")
            frame += 1
        }
        await probe.run(for: .milliseconds(400)) { check($0, "start") }
        for step in steps.dropFirst() {
            driver.work = step.work
            if step.wait > 0 {
                await probe.run(for: .milliseconds(step.wait)) { check($0, "\(step.work)") }
            }
        }
        await probe.run(for: .milliseconds(700)) { check($0, "settle") }
        let last = probe.frame()
        #expect(last.ink(in: Self.mouseRect) >= 0.6 * faintest, "\(name): settled, the mouse is fully drawn")
        #expect(failures.isEmpty, "\(name): \(failures.prefix(6).joined(separator: "; "))")
    }

    @Test func aSwapNeverBlanksTheMouse() async throws {
        try await drive([Step(work: .thinking, wait: 0), Step(work: .webSearch, wait: 600)], name: "swap")
    }

    /// Quick tool → thinking → tool changes, inside the fade and inside one frame.
    @Test func rapidChangesNeverLeaveTheMouseHidden() async throws {
        try await drive([
            Step(work: .thinking, wait: 0),
            Step(work: .webSearch, wait: 40),
            Step(work: .thinking, wait: 5),
            Step(work: .runningCommand, wait: 1),
            Step(work: .readingPage(host: "github.com"), wait: 0),
            Step(work: .thinking, wait: 120),
            Step(work: .runningCommand, wait: 30),
        ], name: "rapid")
    }

    /// Back to the scene that's still fading out, and the same scene again with a new plaque.
    @Test func backToTheSameSceneMidFade() async throws {
        try await drive([
            Step(work: .thinking, wait: 0),
            Step(work: .webSearch, wait: 60),
            Step(work: .thinking, wait: 60),
            Step(work: .webSearch, wait: 0),
            Step(work: .thinking, wait: 200),
            Step(work: .readingPage(host: "a.example"), wait: 50),
            Step(work: .readingPage(host: "b.example"), wait: 50),
        ], name: "back")
    }

    /// Hidden while text streams, then back: settled, the mouse is there with its plaque.
    @Test func hiddenAndBackComesBackWithTheMouse() async throws {
        let faintest = try Self.faintestScene()
        let driver = IndicatorDriver(.webSearch)
        let probe = HostingProbe(IndicatorHost(driver: driver), size: Self.size)
        await probe.run(for: .milliseconds(300))
        driver.work = nil
        await probe.run(for: .milliseconds(60))
        driver.work = .thinking
        await probe.run(for: .milliseconds(30))
        driver.work = nil
        await probe.run(for: .milliseconds(30))
        driver.work = .runningCommand
        await probe.run(for: .milliseconds(700))
        let last = probe.frame()
        #expect(last.ink(in: Self.plaqueRect) > 2)
        #expect(last.ink(in: Self.mouseRect) >= 0.6 * faintest)
    }

    /// Reduce Motion: a plain swap, the new scene's still frame at once (no fade, no gap).
    @Test func reduceMotionSwapsAtOnce() async throws {
        let faintest = try Self.faintestScene()
        let driver = IndicatorDriver(.thinking)
        let probe = HostingProbe(IndicatorHost(driver: driver, reduceMotion: true), size: Self.size)
        await probe.run(for: .milliseconds(200))
        let before = probe.frame().ink(in: Self.mouseRect)
        for work: ResponseActivity.Work in [.webSearch, .thinking, .runningCommand, .webSearch] {
            driver.work = work
            var frames: [Double] = []
            await probe.run(for: .milliseconds(80)) { frames.append($0.ink(in: Self.mouseRect)) }
            #expect(frames.allSatisfy { $0 >= 0.6 * faintest }, "\(work): drawn in full from the first frame: \(frames.map { Int($0) })")
            // Still frames: the scene holds, so consecutive frames are identical.
            #expect(Set(frames.map { Int($0) }).count == 1, "\(work): a still frame under Reduce Motion")
        }
        #expect(before >= 0.6 * faintest)
    }

    // MARK: Cold frame cache

    /// Nothing prewarmed: a scene's first show decodes its frames on the spot, so the first
    /// frame already has the mouse (every kind of work).
    @Test func aColdCacheStillDrawsTheMouseOnFirstShow() throws {
        for work in ResponseActivity.Work.kinds {
            // Some scenes have a near-empty frame by design (the sub-agent's runner leaves the
            // scene), so each is held to its own faintest frame.
            let faintest = try Self.faintestFrame(of: work.scene)
            WorkingMouse.resetCache()
            let view = WorkingIndicator(work: work)
                .padding(10)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let pixels = Pixels(try #require(renderer.cgImage), points: Self.size)
            #expect(pixels.ink(in: Self.mouseRect) >= 0.6 * faintest, "\(work): the mouse is drawn on a cold cache")
            #expect(pixels.ink(in: Self.plaqueRect) > 2, "\(work): with its plaque")
        }
    }

    @Test func aColdCacheHostedFirstFrameHasTheMouse() async throws {
        let faintest = try Self.faintestScene()
        WorkingMouse.resetCache()
        let probe = HostingProbe(IndicatorHost(driver: IndicatorDriver(.searchingFiles)), size: Self.size)
        let first = probe.frame()
        #expect(first.ink(in: Self.mouseRect) >= 0.6 * faintest)
        await probe.run(for: .milliseconds(200))
    }
}

@Observable @MainActor
final class IndicatorDriver {
    var work: ResponseActivity.Work?
    init(_ work: ResponseActivity.Work?) { self.work = work }
}

struct IndicatorHost: View {
    let driver: IndicatorDriver
    var reduceMotion = false

    var body: some View {
        WorkingIndicator(work: driver.work)
            .padding(10)
            .frame(width: 320, height: 60, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}
#endif
