@testable import ArtCollection
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@Suite("The Collection (BRAND-01)")
struct ArtCollectionTests {
    @Test func catalogHasEveryWorkOnce() {
        #expect(Artwork.all.count == 23)
        #expect(Set(Artwork.all.map(\.id)).count == Artwork.all.count)
    }

    @Test(arguments: Artwork.Slot.allCases)
    func everySlotIsFilled(slot: Artwork.Slot) {
        #expect(!Artwork.works(in: slot).isEmpty, "slot \(slot) has no artwork")
        #expect(Artwork.works(in: slot).allSatisfy { $0.slots.contains(slot) })
    }

    @Test func typedAccessorsMatchTheBrandSpec() {
        #expect(Artwork.welcome.artist == "Thomas Cole")
        #expect(Artwork.welcomeDark.id == "heade-point-judith")
        #expect(Artwork.incognito.id == "heade-point-judith")
        #expect(Artwork.error.id == "piranesi-drawbridge")
        #expect(Artwork.libraryEmpty.id == "yi-books-scholars")
        #expect(Artwork.projectsEmpty.id == "lorrain-rest-flight")
        #expect(Artwork.memory.id == "durer-jerome-study")
        #expect(Artwork.mascotOrigin.id == "zeshin-mouse")
        for artwork in [Artwork.welcome, .welcomeDark, .incognito, .error, .libraryEmpty, .projectsEmpty, .memory, .mascotOrigin] {
            #expect(Artwork.all.contains(artwork))
        }
    }

    /// brand.md §4: no nudity or violence crops in UI chrome; the bronze and the sarcophagus are
    /// for About only.
    @Test func aboutOnlyWorksStayOutOfChrome() {
        for id in ["barye-theseus-minotaur", "roman-sarcophagus-theseus-ariadne"] {
            let artwork = Artwork.all.first { $0.id == id }
            #expect(artwork?.slots == [.about])
        }
    }

    @Test(arguments: Artwork.all)
    func creditsAreComplete(artwork: Artwork) {
        #expect(!artwork.licence.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(["CC0", "Public domain"].contains(artwork.licence))
        for field in [artwork.title, artwork.artist, artwork.shortArtist, artwork.date, artwork.museum, artwork.objectNumber] {
            #expect(!field.isEmpty)
        }
        #expect(artwork.url.scheme == "https")
        #expect(artwork.url.host() != nil)
        #expect((0...1).contains(artwork.focal.x) && (0...1).contains(artwork.focal.y))
    }

    @Test(arguments: Artwork.all)
    func imageLoadsFromTheBundle(artwork: Artwork) throws {
        let url = try #require(artwork.fileURL)
        #expect(url.pathExtension == "jpg")
        let image = try #require(ArtworkImageCache.decode(url, maxPixelSize: 1600))
        #expect(image.width == Int(artwork.pixelSize.width))
        #expect(image.height == Int(artwork.pixelSize.height))
        let small = try #require(artwork.cgImage(maxPixelSize: 300))
        #expect(max(small.width, small.height) == ArtworkImageCache.bucket(for: 300))
    }

    @Test func todayRotatesDailyAndDeterministically() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let rotation = Artwork.todayRotation
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9)))
        var seen: [Artwork] = []
        for offset in 0..<rotation.count {
            let day = try #require(calendar.date(byAdding: .day, value: offset, to: start))
            let artwork = Artwork.today(for: day, calendar: calendar)
            #expect(artwork == Artwork.today(for: day, calendar: calendar))
            // The same local day, late in the evening, is the same work.
            let evening = try #require(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: day))
            #expect(Artwork.today(for: evening, calendar: calendar) == artwork)
            #expect(artwork.slots.contains(.today))
            seen.append(artwork)
        }
        // A full cycle shows every work in the rotation once.
        #expect(Set(seen) == Set(rotation))
        // Pinned: the rotation is the same on every device and launch.
        #expect(Artwork.dayNumber(of: start, calendar: calendar) == 20_751)
        #expect(Artwork.dayNumber(of: Date(timeIntervalSince1970: 0), calendar: calendar) == 0)
    }

    @Test func todayIgnoresTheCalendarSystem() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = gregorian.timeZone
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Artwork.today(for: date, calendar: gregorian) == Artwork.today(for: date, calendar: japanese))
    }

    @Test func projectCoversAreStable() {
        let ids = ["0b5e1c4a-1111-4000-8000-000000000001", "projects/abc", "", "Ω"]
        for id in ids {
            let cover = Artwork.projectCover(for: id)
            #expect(cover == Artwork.projectCover(for: id))
            #expect(cover.slots.contains(.projectCover))
        }
        // FNV-1a test vectors: the hash never depends on the process's hashing seed.
        #expect(Artwork.stableHash("") == 0xCBF2_9CE4_8422_2325)
        #expect(Artwork.stableHash("a") == 0xAF63_DC4C_8601_EC8C)
        // Different Projects get different covers.
        let covers = Set((0..<40).map { Artwork.projectCover(for: "project-\($0)") })
        #expect(covers.count == Artwork.projectCovers.count)
    }

    @Test func focalCropKeepsTheFocalPointInView() {
        let image = CGSize(width: 1600, height: 900)
        // A tall container: the image is scaled to its height and slid towards the focal point.
        let tall = FocalCrop.frame(imageSize: image, container: CGSize(width: 100, height: 200), focal: UnitPoint(x: 0.8, y: 0.5))
        #expect(tall.height == 200)
        let focalX = tall.minX + 0.8 * tall.width
        #expect(abs(focalX - 50) < 0.001)
        // At the image's edge the crop stops sliding: no empty band.
        let edge = FocalCrop.frame(imageSize: image, container: CGSize(width: 100, height: 200), focal: UnitPoint(x: 1, y: 0.5))
        #expect(abs(edge.maxX - 100) < 0.001)
        #expect(edge.minY == 0)
        // Same proportions: no crop.
        let same = FocalCrop.frame(imageSize: image, container: CGSize(width: 160, height: 90), focal: .topLeading)
        #expect(same == CGRect(x: 0, y: 0, width: 160, height: 90))
    }

    @Test func plaqueText() {
        let cole = Artwork.welcome
        #expect(Plaque.text(for: cole, style: .full) == ", Thomas Cole, 1837 · Cleveland Museum of Art · CC0")
        #expect(Plaque.text(for: cole, style: .compact) == "Cole · 1837")
        #expect(Plaque.text(for: cole, style: .overArt) == "View of Florence · Thomas Cole · 1837")
        #expect(Plaque.accessibilityLabel(for: cole, style: .full).contains("Cleveland Museum of Art"))
    }
}

/// BRAND-04: About › The Collection credits every work exactly once, the app icons' paintings
/// in their own section.
@Suite("Collection credits (BRAND-04)")
struct CollectionCreditsTests {
    @Test func everyWorkIsCreditedOnce() {
        let inTheApp = CollectionCreditsList.inTheApp.map(\.id)
        let icons = CollectionCreditsList.behindTheIcons.map(\.id)
        #expect(Set(inTheApp).isDisjoint(with: icons))
        #expect(Set(inTheApp + icons) == Set(Artwork.all.map(\.id)))
        #expect(inTheApp.count + icons.count == Artwork.all.count)
    }

    @Test func theIconPaintingsHaveTheirOwnSection() {
        #expect(!CollectionCreditsList.behindTheIcons.isEmpty)
        #expect(CollectionCreditsList.behindTheIcons.allSatisfy { $0.slots.contains(.icon) })
        #expect(CollectionCreditsList.inTheApp.contains(.mascotOrigin))
    }
}
