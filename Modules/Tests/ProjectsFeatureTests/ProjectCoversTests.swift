import ArtCollection
import Foundation
@testable import ProjectsFeature
import Testing

/// BRAND-04: Project covers chosen on this device, with the deterministic default.
@MainActor
@Suite("ProjectCovers")
struct ProjectCoversTests {
    private func ephemeralDefaults() -> UserDefaults {
        let name = "theseus.tests.covers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theDefaultFollowsTheProjectID() {
        let covers = ProjectCovers()
        for id in ["a", "b", "3f2c-uuid", ""] {
            #expect(covers.cover(for: id) == Artwork.projectCover(for: id))
            #expect(covers.isChosen(for: id) == false)
        }
    }

    @Test func choicesAreTheProjectCoverWorks() {
        let covers = ProjectCovers()
        #expect(covers.choices == Artwork.projectCovers)
        #expect(covers.choices.count > 1)
        #expect(covers.choices.allSatisfy { $0.slots.contains(.projectCover) })
    }

    @Test func aChoiceIsKeptPerProjectAndPersists() throws {
        let defaults = ephemeralDefaults()
        let covers = ProjectCovers(accountKey: "acct", defaults: defaults)
        let other = try #require(covers.choices.first { $0 != Artwork.projectCover(for: "p1") })
        covers.setCover(other, for: "p1")
        #expect(covers.cover(for: "p1") == other)
        #expect(covers.isChosen(for: "p1"))
        #expect(covers.cover(for: "p2") == Artwork.projectCover(for: "p2"))

        let reloaded = ProjectCovers(accountKey: "acct", defaults: defaults)
        #expect(reloaded.cover(for: "p1") == other)
        // Another Account on the device doesn't see it.
        #expect(ProjectCovers(accountKey: "other", defaults: defaults).isChosen(for: "p1") == false)
    }

    @Test func choosingTheDefaultClearsTheChoice() throws {
        let defaults = ephemeralDefaults()
        let covers = ProjectCovers(accountKey: "acct", defaults: defaults)
        let fallback = Artwork.projectCover(for: "p1")
        let other = try #require(covers.choices.first { $0 != fallback })
        covers.setCover(other, for: "p1")
        covers.setCover(fallback, for: "p1")
        #expect(covers.isChosen(for: "p1") == false)
        #expect(covers.cover(for: "p1") == fallback)
        #expect(defaults.dictionary(forKey: "theseus.projectCovers.acct") == nil)
    }

    @Test func worksOutsideTheCoverSlotAreIgnored() {
        let covers = ProjectCovers()
        covers.setCover(.mascotOrigin, for: "p1")
        #expect(covers.isChosen(for: "p1") == false)
        #expect(covers.cover(for: "p1") == Artwork.projectCover(for: "p1"))
    }

    @Test func forgettingDropsTheChoice() throws {
        let covers = ProjectCovers()
        let other = try #require(covers.choices.first { $0 != Artwork.projectCover(for: "p1") })
        covers.setCover(other, for: "p1")
        covers.forget("p1")
        #expect(covers.isChosen(for: "p1") == false)
    }
}
