@testable import DesignSystem
import Foundation
import Testing

/// A seeded generator, so picks are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("Petting the mouse (#174)")
struct PettableMouseTests {
    @Test func faceFramesMatchTheirPoseSoSwappingNeverMovesTheLayout() {
        let pairs: [(PixelMouse.Frame, PixelMouse.Pose)] = [
            (.headBlink, .head), (.headEar, .head), (.headSniff, .head),
            (.sitBlink, .sit), (.sitEar, .sit), (.sitSniff, .sit),
        ]
        for (frame, pose) in pairs {
            #expect(frame.sprite.width == pose.sprite.width, "\(frame)")
            #expect(frame.sprite.height == pose.sprite.height, "\(frame)")
            // A variation, not a new drawing: a few pixels differ.
            let changed = zip(frame.sprite.rows.joined(), pose.sprite.rows.joined()).filter { $0 != $1 }.count
            #expect((1...6).contains(changed), "\(frame) changes \(changed) pixels")
        }
        #expect(PixelMouse.Frame.heart.sprite.width <= 8)
        #expect(PixelMouse.Frame.crumb.sprite.width <= 5)
    }

    @Test(arguments: PixelMouse.Frame.allCases)
    func framesUseOnlyThePalette(frame: PixelMouse.Frame) {
        for row in frame.sprite.rows {
            for glyph in row where glyph != "." {
                #expect(PixelMouse.palette[glyph] != nil, "\(frame) uses \(glyph)")
            }
        }
        #expect(frame.sprite.rows.allSatisfy { $0.count == frame.sprite.width })
    }

    @Test func aTapNeverRepeatsTheLastReaction() {
        var tracker = PettingTracker()
        var random = SeededGenerator(state: 7)
        var previous: MouseReaction?
        var seen = Set<MouseReaction>()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<200 {
            // Slow taps: never a surprise.
            let reaction = tracker.tap(at: start.addingTimeInterval(Double(index)), using: &random)
            #expect(reaction != previous)
            #expect(MouseReaction.everyday.contains(reaction))
            previous = reaction
            seen.insert(reaction)
        }
        #expect(seen == Set(MouseReaction.everyday), "every reaction comes up")
    }

    @Test func heartsAndCrumbsAreOccasional() {
        var tracker = PettingTracker()
        var random = SeededGenerator(state: 42)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let picks = (0..<600).map { tracker.tap(at: start.addingTimeInterval(Double($0)), using: &random) }
        let props = picks.filter { $0 == .heart || $0 == .crumb }.count
        #expect(props > 20 && props < 200, "\(props) of 600")
    }

    @Test func sevenQuickTapsMakeASurprise() {
        var tracker = PettingTracker()
        var random = SeededGenerator(state: 3)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let picks = (0..<7).map { tracker.tap(at: start.addingTimeInterval(Double($0) * 0.3), using: &random) }
        #expect(picks.prefix(6).allSatisfy { MouseReaction.everyday.contains($0) })
        #expect(MouseReaction.surprises.contains(picks[6]))
        // The run starts over.
        let next = tracker.tap(at: start.addingTimeInterval(2.1), using: &random)
        #expect(MouseReaction.everyday.contains(next))
        #expect(tracker.quickTaps == 1)
    }

    @Test func aPauseBreaksTheRun() {
        var tracker = PettingTracker()
        var random = SeededGenerator(state: 9)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<6 { _ = tracker.tap(at: start.addingTimeInterval(Double(index) * 0.3), using: &random) }
        let late = tracker.tap(at: start.addingTimeInterval(1.5 + PettingTracker.quickTapGap + 0.1), using: &random)
        #expect(MouseReaction.everyday.contains(late))
        #expect(tracker.quickTaps == 1)
    }

    @Test func reactionsAreSteppedWholePixelsAndEndAtRest() {
        let kinds: [PettableMouse.Kind] = [
            .pose(.head), .pose(.sit), .running(label: "Thinking"), .pose(.stand),
            .working(.webSearch, label: "Searching the web"), .working(.runningCommand, size: .large, label: "Running command"),
        ]
        for kind in kinds {
            for reaction in MouseReaction.allCases {
                let frames = reaction.frames(for: kind)
                #expect(!frames.isEmpty)
                #expect(frames.count <= 12, "\(reaction) is short")
                let last = frames[frames.count - 1]
                #expect(last.dx == 0 && last.dy == 0 && !last.mirrored && last.opacity == 1, "\(reaction) on \(kind) ends at rest")
                for frame in frames {
                    #expect(abs(frame.dy) <= 4, "a hop stays small")
                    if let prop = frame.prop {
                        #expect(prop.rise <= 12)
                        #expect([0, 0.33, 0.66, 1].contains(prop.opacity), "props fade in steps")
                    }
                }
            }
        }
        // A heart or crumb floats 8 to 12 pt.
        let rise = MouseReaction.heart.frames(for: .pose(.head)).compactMap(\.prop?.rise).max() ?? 0
        #expect((8...12).contains(rise))
        // The hop goes up for 2 to 3 frames.
        #expect(MouseReaction.hop.frames(for: .pose(.head)).filter { $0.dy < 0 }.count >= 2)
    }

    @Test func onlyMiceWithFaceFramesBlinkTwitchAndSniff() {
        #expect(MouseReaction.available(for: .pose(.head)) == MouseReaction.everyday)
        #expect(MouseReaction.available(for: .pose(.sit)) == MouseReaction.everyday)
        #expect(!MouseReaction.available(for: .running(label: "x")).contains(.blink))
        #expect(MouseReaction.blink.frames(for: .pose(.head)).first?.drawing == .frame(.headBlink))
    }

    /// #185: the working mouse at the tail stays pettable. It keeps working through a hop, and
    /// runs off and back as a whole scene, in the scene's size.
    @Test func theWorkingMouseReactsAsAScene() {
        let kind = PettableMouse.Kind.working(.webSearch, label: "Searching the web")
        #expect(kind.baseSprite.width == 34 && kind.baseSprite.height == 14)
        #expect(MouseReaction.available(for: kind) == [.hop, .squeak, .heart, .crumb])
        let hop = MouseReaction.hop.frames(for: kind).map(\.drawing)
        #expect(hop == (0..<4).map { .scene(.webSearch, .compact, index: $0) })
        #expect(MouseReaction.runOff.frames(for: kind).allSatisfy { frame in
            if case .scene = frame.drawing { return true }
            return false
        })
        #expect(kind.restingDrawing == .scene(.webSearch, .compact, index: WorkingMouse.stillIndex(of: .webSearch, size: .compact)))
        // Scene drawings draw in the accent-aware palette.
        #expect(MouseFrame.Drawing.scene(.webSearch, .compact, index: 0).palette(for: .oxblood)["v"] == AccentChoice.oxblood.tokens.accent.light)
        #expect(MouseFrame.Drawing.pose(.head).palette(for: .oxblood) == PixelMouse.palette)
        // Indexes past the loop wrap.
        #expect(MouseFrame.Drawing.scene(.tool, .compact, index: 8).sprite == MouseFrame.Drawing.scene(.tool, .compact, index: 0).sprite)
    }
}
