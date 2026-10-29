@testable import ComposerFeature
import CoreGraphics
import Fixtures
import Foundation
import ImageIO
import OpenWebUIKit
import Testing
import UniformTypeIdentifiers

func model(_ id: String, owner: String? = "openai", controls: [ModelControl] = [], capabilities: [String: Bool] = [:]) -> Model {
    Model(id: id, name: id.capitalized, ownedBy: owner, capabilities: ModelCapabilities(raw: capabilities), controls: controls)
}

@Suite("Model catalog (MODEL-01, MODEL-03)")
struct ModelCatalogTests {
    let models = ["a", "b", "c", "d", "e", "f"].map { model($0) }

    @Test func withoutPinsTheFirstFourArePrimary() {
        let catalog = ModelCatalog(models: models, pinnedIDs: [])
        #expect(catalog.primary.map(\.id) == ["a", "b", "c", "d"])
        #expect(catalog.more.map(\.id) == ["e", "f"])
        #expect(catalog.isInMore("f"))
    }

    @Test func pinsArePrimaryInTheAdminsOrder() {
        let catalog = ModelCatalog(models: models, pinnedIDs: ["e", "b", "gone"])
        #expect(catalog.primary.map(\.id) == ["b", "e"])
        #expect(catalog.more.map(\.id) == ["a", "c", "d", "f"])
    }

    @Test func smallListsHaveNoMoreModels() {
        let catalog = ModelCatalog(models: Array(models.prefix(3)), pinnedIDs: ["unknown"])
        #expect(catalog.more.isEmpty)
        #expect(catalog.primary.count == 3)
    }

    @Test func subtitleFallsBackToWhatTheModelCanDo() {
        #expect(Model(id: "x", name: "X", description: "  For complex tasks ").pickerSubtitle == "For complex tasks")
        #expect(model("y", capabilities: ["vision": true, "web_search": true, "file_upload": false]).pickerSubtitle == "Sees images · Searches the web")
        #expect(model("z").pickerSubtitle == nil)
    }
}

@Suite("Effort mapping (MODEL-02, ADR 0040)")
struct EffortTests {
    let all = Capabilities(enabled: Set(Capability.allCases))
    let paramsOnly = Capabilities(enabled: [.modelParams])

    var controls: [ModelControl] {
        [
            ModelControl(id: "thinking", label: "Thinking", options: [.init(id: "off", label: "Off"), .init(id: "on", label: "On")]),
            ModelControl(id: "effort", label: "Effort", defaultOptionID: "low", options: ["low", "medium", "high", "max"].map { .init(id: $0, label: $0.capitalized) }),
            ModelControl(id: "verbosity", label: "Verbosity", options: [.init(id: "terse", label: "Terse"), .init(id: "chatty", label: "Chatty")]),
        ]
    }

    @Test func adminControlsWinAndSplitIntoEffortThinkingAndExtras() throws {
        let config = try #require(EffortConfiguration.resolve(for: model("r", controls: controls), capabilities: all))
        #expect(config.source == .modelControls)
        #expect(config.effortKey == "effort")
        #expect(config.levels.map(\.label) == ["Low", "Medium", "High", "Max"])
        #expect(config.thinking?.id == "thinking")
        #expect(config.extras.map(\.id) == ["verbosity"])
        // The default option names the chip until the user picks.
        #expect(config.chipLabel(for: EffortSelection()) == "Low")
        let picked = EffortSelection(picks: ["effort": "high", "thinking": "on", "stale": "x"])
        #expect(config.chipLabel(for: picked) == "High")
        #expect(config.isThinkingOn(in: picked))
        #expect(!config.isThinkingOn(in: EffortSelection()))
        #expect(config.params(for: picked, modelID: "r") == [
            "model_controls": .object(["r": .object(["effort": .string("high"), "thinking": .string("on")])]),
        ])
        #expect(config.params(for: EffortSelection(), modelID: "r").isEmpty)
    }

    @Test func controlsNeedTheControlsCapabilityElseReasoningEffortApplies() throws {
        let config = try #require(EffortConfiguration.resolve(for: model("r", controls: controls), capabilities: paramsOnly))
        #expect(config.source == .reasoningEffort)
    }

    @Test func reasoningEffortFallbackDefaultSendsNothing() throws {
        let config = try #require(EffortConfiguration.resolve(for: model("claude"), capabilities: paramsOnly))
        #expect(config.levels.map(\.id) == ["default", "low", "medium", "high"])
        #expect(config.chipLabel(for: EffortSelection()) == nil)
        #expect(config.params(for: EffortSelection(), modelID: "claude").isEmpty)
        let medium = EffortSelection(picks: ["reasoning_effort": "medium"])
        #expect(config.chipLabel(for: medium) == "Medium")
        #expect(config.params(for: medium, modelID: "claude") == ["reasoning_effort": .string("medium")])
        #expect(config.thinking == nil)
    }

    @Test func hiddenWithoutPermissionOrForNonOpenAIConnections() {
        #expect(EffortConfiguration.resolve(for: model("claude"), capabilities: Capabilities(enabled: [])) == nil)
        #expect(EffortConfiguration.resolve(for: model("llama", owner: "ollama"), capabilities: paramsOnly) == nil)
    }

    @Test func aThinkingMenuWithLevelsIsTheEffortList() throws {
        let thinking = ModelControl(id: "budget", label: "Thinking", options: ["off", "low", "high"].map { .init(id: $0, label: $0.capitalized) })
        let config = try #require(EffortConfiguration.resolve(for: model("t", controls: [thinking]), capabilities: all))
        #expect(config.effortKey == "budget")
        #expect(config.thinking == nil)
        #expect(config.chipLabel(for: EffortSelection()) == nil)
    }

    @Test func aLoneSwitchIsJustTheThinkingToggle() throws {
        let extended = ModelControl(id: "extended", label: "Extended thinking", options: [.init(id: "no", label: "No"), .init(id: "yes", label: "Yes")])
        let config = try #require(EffortConfiguration.resolve(for: model("t", controls: [extended]), capabilities: all))
        #expect(!config.hasEffortLevels)
        #expect(config.thinking?.id == "extended")
        #expect(config.params(for: EffortSelection(picks: ["extended": "yes"]), modelID: "t") == [
            "model_controls": .object(["t": .object(["extended": .string("yes")])]),
        ])
    }
}

@Suite("Greeting (HOME-01)")
struct GreetingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    func date(_ hour: Int, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? Date()
    }

    @Test func followsTheTimeOfDay() {
        let morning = Greeting.text(name: "Lex", now: date(9), lastVisit: date(8), calendar: calendar)
        #expect(morning.contains("orning, Lex"))
        #expect(Greeting.text(name: "Lex", now: date(14), lastVisit: nil, calendar: calendar).contains("fternoon, Lex"))
        #expect(Greeting.text(name: "Lex", now: date(19), lastVisit: nil, calendar: calendar).contains("vening, Lex"))
        #expect(Greeting.text(name: nil, now: date(14), lastVisit: nil, calendar: calendar) == "Good afternoon")
        let late = Greeting.text(name: "Lex", now: date(2), lastVisit: nil, calendar: calendar)
        #expect(late == "Up late, Lex?" || late == "Hello, night owl")
    }

    @Test func staysTheSameWithinADayAndVariesAcrossDays() {
        let first = Greeting.text(name: "Lex", now: date(14, day: 10), lastVisit: nil, calendar: calendar)
        #expect(first == Greeting.text(name: "Lex", now: date(15, day: 10), lastVisit: nil, calendar: calendar))
        #expect(first != Greeting.text(name: "Lex", now: date(14, day: 11), lastVisit: nil, calendar: calendar))
    }

    @Test func welcomesBackAfterAFewDays() {
        let text = Greeting.text(name: "Lex", now: date(14, day: 10), lastVisit: date(14, day: 5), calendar: calendar)
        #expect(text == "Welcome back, Lex" || text == "Lex is back!")
        #expect(!Greeting.text(name: nil, now: date(14, day: 10), lastVisit: date(14, day: 5), calendar: calendar).contains("back"))
    }

    @Test func prefersTheNickname() {
        #expect(Greeting.name(nickname: " Lex ", fullName: "Alexandra Stone") == "Lex")
        #expect(Greeting.name(nickname: "", fullName: "Alexandra Stone") == "Alexandra")
        #expect(Greeting.name(nickname: nil, fullName: nil) == nil)
    }
}

@Suite("Image preparation (ATT-02, ADR 0042)")
struct ImageProcessingTests {
    static func image(width: Int, height: Int, type: UTType, orientation: Int = 1, alpha: Bool = false) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        context?.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: alpha ? 0.5 : 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context?.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func smallJPEGsAndPNGsPassThrough() throws {
        let jpeg = Self.image(width: 400, height: 300, type: .jpeg)
        let prepared = try #require(ImageProcessing.prepare(jpeg, filename: "a.jpg", limits: FileLimits()))
        #expect(!prepared.wasReencoded)
        #expect(prepared.upload.data == jpeg)
        #expect(prepared.upload.contentType == "image/jpeg")
        let png = Self.image(width: 20, height: 20, type: .png)
        #expect(ImageProcessing.prepare(png, filename: "b.png", limits: FileLimits())?.upload.contentType == "image/png")
    }

    @Test func heicBecomesJPEG() throws {
        let heic = Self.image(width: 300, height: 200, type: .heic)
        try #require(!heic.isEmpty, "HEIC encoding unavailable on this machine")
        let prepared = try #require(ImageProcessing.prepare(heic, filename: "IMG_0001.HEIC", limits: FileLimits()))
        #expect(prepared.wasReencoded)
        #expect(prepared.upload.contentType == "image/jpeg")
        #expect(prepared.upload.filename == "IMG_0001.jpg")
        #expect(prepared.pixelWidth == 300)
    }

    @Test func largeImagesShrinkToTheDefaultBound() throws {
        let big = Self.image(width: 4000, height: 1000, type: .jpeg)
        let prepared = try #require(ImageProcessing.prepare(big, filename: "wide.jpg", limits: FileLimits()))
        #expect(prepared.wasReencoded)
        #expect(prepared.pixelWidth == 2048)
        #expect(prepared.pixelHeight == 512)
    }

    @Test func theServersBoundWins() throws {
        let photo = Self.image(width: 1600, height: 1200, type: .jpeg)
        let prepared = try #require(ImageProcessing.prepare(photo, filename: "p.jpg", limits: FileLimits(imageMaxWidth: 800, imageMaxHeight: 800)))
        #expect(prepared.pixelWidth == 800)
        #expect(prepared.pixelHeight == 600)
        #expect(ImageProcessing.targetLongestEdge(width: 1000, height: 2000, limits: FileLimits(imageMaxHeight: 500)) == 500)
        #expect(ImageProcessing.targetLongestEdge(width: 100, height: 100, limits: FileLimits(imageMaxWidth: 500)) == 100)
    }

    @Test func rotatedPhotosAreReencodedUpright() throws {
        let rotated = Self.image(width: 400, height: 300, type: .jpeg, orientation: 6)
        let prepared = try #require(ImageProcessing.prepare(rotated, filename: "r.jpg", limits: FileLimits()))
        #expect(prepared.wasReencoded)
        #expect(prepared.pixelWidth == 300)
        #expect(prepared.pixelHeight == 400)
    }

    @Test func transparentPNGsStayPNG() throws {
        let png = Self.image(width: 3000, height: 3000, type: .png, alpha: true)
        let prepared = try #require(ImageProcessing.prepare(png, filename: "logo.png", limits: FileLimits()))
        #expect(prepared.upload.contentType == "image/png")
        #expect(prepared.pixelWidth == 2048)
    }

    @Test func garbageIsRejected() {
        #expect(ImageProcessing.prepare(Data("nope".utf8), filename: "x.jpg", limits: FileLimits()) == nil)
        #expect(ImageProcessing.thumbnail(Data()) == nil)
    }
}
