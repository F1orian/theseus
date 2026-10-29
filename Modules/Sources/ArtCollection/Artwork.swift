public import CoreGraphics
public import DesignSystem
public import Foundation
public import SwiftUI

/// One work in The Collection (docs/design/brand.md §4, ADR 0140): a public-domain painting,
/// engraving or sculpture with its credit, where the app uses it (`slots`), and the point a crop
/// keeps in view. The catalog is generated from `scripts/brand/collection.json`
/// (`scripts/brand/gen_collection.py`); the JPEGs ship in this module's bundle, never in
/// DesignSystem, so the extensions don't carry them.
///
/// Art appears at thresholds (welcome, empty states, errors, incognito, Project covers), framed
/// (`FramedArtwork`) or full-bleed (`ArtworkHero`), and always credited (`Plaque`, or About ›
/// The Collection via `CollectionCreditsList`). Never filter, recolour, pixelate or composite it.
public struct Artwork: Identifiable, Sendable, Hashable {
    /// Where a work is used. Single-work slots have typed accessors (`Artwork.welcome`); the others
    /// are rotations or lists (`Artwork.works(in:)`).
    public enum Slot: String, CaseIterable, Sendable {
        case welcome, welcomeDark, incognito, error, offline, libraryEmpty, projectsEmpty, memory
        case mascotOrigin, onboarding, voice
        /// The Theseus Pro paywall (ADR 0173).
        case pro
        /// "Today in the collection": the daily rotation (`Artwork.today(for:)`).
        case today
        /// Project covers (`Artwork.projectCover(for:)`).
        case projectCover
        /// Shown only on About › The Collection (the Barye bronze, the sarcophagus).
        case about
        /// Paintings behind the app icons (BRAND-02), credited on About.
        case icon
    }

    /// A stable slug, e.g. `cole-view-of-florence`.
    public let id: String
    public let title: String
    public let artist: String
    /// The name a compact plaque uses ("Corot").
    public let shortArtist: String
    /// As the museum gives it: "1837", "c. 1830–31", "late 1800s".
    public let date: String
    public let museum: String
    public let objectNumber: String
    /// "CC0" or "Public domain".
    public let licence: String
    /// The work's page at its museum.
    public let url: URL
    /// The JPEG's file name in the bundle.
    public let fileName: String
    /// The image's size in pixels (1600 on the long edge, except smaller originals).
    public let pixelSize: CGSize
    public let slots: Set<Slot>
    /// Where the eye should land; crops keep it as central as the image allows.
    public let focal: UnitPoint
    /// The work's average colour, shown while the image decodes.
    public let placeholder: RGBA

    init(
        id: String, title: String, artist: String, shortArtist: String, date: String, museum: String,
        objectNumber: String, licence: String, museumURL: String, fileName: String, pixelSize: CGSize,
        slots: Set<Slot>, focal: UnitPoint, placeholder: RGBA
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.shortArtist = shortArtist
        self.date = date
        self.museum = museum
        self.objectNumber = objectNumber
        self.licence = licence
        // The generator only emits https URLs; the fallback is unreachable but keeps this total.
        url = URL(string: museumURL) ?? URL(filePath: "/")
        self.fileName = fileName
        self.pixelSize = pixelSize
        self.slots = slots
        self.focal = focal
        self.placeholder = placeholder
    }

    /// Width over height.
    public var aspectRatio: CGFloat {
        pixelSize.height > 0 ? pixelSize.width / pixelSize.height : 1
    }

    /// "View of Florence, Thomas Cole, 1837", for accessibility and plain-text credits.
    public var credit: String {
        "\(title), \(artist), \(date)"
    }

    public static func == (lhs: Artwork, rhs: Artwork) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: Slots, the daily rotation and Project covers

extension Artwork {
    /// The works carrying `slot`, in catalog order.
    public static func works(in slot: Slot) -> [Artwork] {
        generatedWorks(in: slot)
    }

    /// The works "Today in the collection" rotates through.
    public static var todayRotation: [Artwork] { works(in: .today) }

    /// The works a Project cover is chosen from.
    public static var projectCovers: [Artwork] { works(in: .projectCover) }

    /// "Today in the collection" for `date`: one work per calendar day in `calendar`'s time zone,
    /// cycling through `todayRotation` in order. Deterministic: every device shows the same work
    /// on the same local date.
    public static func today(for date: Date, calendar: Calendar = .current) -> Artwork {
        let rotation = todayRotation
        guard !rotation.isEmpty else { return memory }
        let count = rotation.count
        return rotation[(dayNumber(of: date, calendar: calendar) % count + count) % count]
    }

    /// The cover for the Project with server id `id`: a stable hash (FNV-1a, the same on every
    /// launch and device, unlike `Hasher`) over `projectCovers`.
    public static func projectCover(for id: String) -> Artwork {
        let covers = projectCovers
        guard !covers.isEmpty else { return projectsEmpty }
        return covers[Int(stableHash(id) % UInt64(covers.count))]
    }

    /// Days from 1 January 1970 to the calendar date of `date` in `calendar` (negative before it).
    static func dayNumber(of date: Date, calendar: Calendar) -> Int {
        // The local date in `calendar`'s time zone, counted on the Gregorian calendar so a
        // Buddhist or Japanese calendar setting doesn't change the rotation.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        let (year, month, day) = (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 64-bit FNV-1a over UTF-8.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: Images

extension Artwork {
    /// The JPEG in this module's bundle.
    public var fileURL: URL? {
        Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Art")
    }

    /// The decoded image, downsampled so its long edge is at most `maxPixelSize` (the full
    /// 1600 px when `nil`). Synchronous and cached; prefer `loadImage(maxPixelSize:)` off the main
    /// thread, as the views do.
    public func cgImage(maxPixelSize: Int? = nil) -> CGImage? {
        ArtworkImageCache.shared.image(for: self, maxPixelSize: maxPixelSize)
    }

    /// `cgImage(maxPixelSize:)` on a background task.
    public func loadImage(maxPixelSize: Int? = nil) async -> CGImage? {
        let artwork = self
        return await Task.detached(priority: .userInitiated) {
            artwork.cgImage(maxPixelSize: maxPixelSize)
        }.value
    }

    /// Decodes the images the next screen needs before it appears (e.g. the welcome art at launch).
    public static func preload(_ artworks: [Artwork], maxPixelSize: Int? = nil) async {
        for artwork in artworks {
            _ = await artwork.loadImage(maxPixelSize: maxPixelSize)
        }
    }
}
