@testable import ConnectorsFeature
import Foundation
import Synchronization
import Testing

@MainActor
final class FakeLocation: LocationProviding {
    var authorization: LocationAuthorization = .notDetermined
    var answer: LocationAuthorization = .allowed
    var coordinate: Coordinate? = Coordinate(latitude: 48.13719, longitude: 11.57561)
    var requests = 0
    var lookups = 0

    func requestAuthorization() async -> LocationAuthorization {
        requests += 1
        authorization = answer
        return authorization
    }

    func currentCoordinate() async -> Coordinate? {
        lookups += 1
        return authorization == .allowed ? coordinate : nil
    }
}

/// Device permissions phase 1 (CONN-07): Location as `{{USER_LOCATION}}`.
@Suite("Location sharing (CONN-07)")
@MainActor
struct LocationSharingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "theseus.tests.\(UUID().uuidString)") ?? .standard
    }

    @Test func nothingIsSharedByDefault() async {
        let location = FakeLocation()
        let sharing = LocationSharing(accountKey: "a", provider: location, defaults: defaults())
        #expect(sharing.access == .never)
        #expect(sharing.statusLabel == "Not allowed")
        await sharing.refresh()
        #expect(sharing.requestVariables().isEmpty)
        #expect(location.lookups == 0, "never touches location services")
    }

    @Test func allowingAsksIOSOnceAndSharesTheWebClientFormat() async {
        let location = FakeLocation()
        let store = defaults()
        let sharing = LocationSharing(accountKey: "a", provider: location, defaults: store)
        await sharing.setAccess(.always)
        #expect(location.requests == 1)
        #expect(sharing.isSharing)
        #expect(sharing.statusLabel == "Allowed")
        #expect(sharing.requestVariables() == ["{{USER_LOCATION}}": "48.137, 11.576 (lat, long)"])

        // The choice persists per Account on this device.
        #expect(LocationSharing(accountKey: "a", provider: location, defaults: store).access == .always)
        #expect(LocationSharing(accountKey: "b", provider: location, defaults: store).access == .never)
    }

    @Test func iOSDenialMeansNothingIsShared() async {
        let location = FakeLocation()
        location.answer = .denied
        let sharing = LocationSharing(accountKey: "a", provider: location, defaults: defaults())
        await sharing.setAccess(.always)
        #expect(!sharing.isSharing)
        #expect(sharing.statusLabel == "Off in iOS Settings")
        #expect(sharing.requestVariables().isEmpty)
    }

    @Test func turningItOffForgetsThePosition() async {
        let location = FakeLocation()
        let sharing = LocationSharing(accountKey: "a", provider: location, defaults: defaults())
        await sharing.setAccess(.always)
        await sharing.setAccess(.never)
        #expect(sharing.coordinate == nil)
        #expect(sharing.requestVariables().isEmpty)
        sharing.removeAll()
        #expect(sharing.access == .never)
    }

    @Test func coordinatesUseADotWhateverTheLocale() {
        #expect(Coordinate(latitude: -33.86785, longitude: 151.20732).promptValue == "-33.868, 151.207 (lat, long)")
    }
}
