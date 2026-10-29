public import Foundation
public import Observation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// What iOS lets Theseus do with the device's location.
public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined
    case allowed
    /// Denied or restricted in iOS Settings.
    case denied
}

public struct Coordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The `{{USER_LOCATION}}` value, in the web client's format ("48.137, 11.575 (lat, long)").
    public var promptValue: String {
        String(format: "%.3f, %.3f (lat, long)", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }
}

/// The device's location services, behind a seam for tests and previews.
@MainActor
public protocol LocationProviding: AnyObject {
    var authorization: LocationAuthorization { get }
    /// Asks iOS for "While Using the App" access (once; later calls just report the state).
    func requestAuthorization() async -> LocationAuthorization
    /// One current position, or `nil` when unavailable.
    func currentCoordinate() async -> Coordinate?
}

/// Device permissions, phase 1 (CONN-07, ADR 0091): sharing the device's location with the
/// model as the `{{USER_LOCATION}}` prompt variable. The choice is per device and per Account
/// (Never / Always); iOS's own permission still applies. Calendar and Reminders need client-side
/// tools and are deferred.
@MainActor
@Observable
public final class LocationSharing {
    public enum Access: String, Sendable, CaseIterable {
        case never
        case always
    }

    public private(set) var access: Access
    public private(set) var authorization: LocationAuthorization
    public private(set) var coordinate: Coordinate?
    public private(set) var isLocating = false

    @ObservationIgnored private let provider: any LocationProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var locatedAt: Date?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// A position older than this is refreshed (in the background) before the next send.
    @ObservationIgnored var maximumAge: TimeInterval = 300

    /// - Parameters:
    ///   - accountKey: Scopes the choice to one Account on this device.
    ///   - defaults: `nil` uses a throwaway suite (tests, previews).
    public init(
        accountKey: String,
        provider: any LocationProviding,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.defaults = defaults ?? UserDefaults(suiteName: "theseus.connectors.ephemeral.\(UUID().uuidString)") ?? .standard
        key = "theseus.connectors.\(accountKey).location"
        self.now = now
        access = self.defaults.string(forKey: key).flatMap(Access.init(rawValue:)) ?? .never
        authorization = provider.authorization
    }

    /// Whether the location is actually shared: the user chose Always and iOS allows it.
    public var isSharing: Bool { access == .always && authorization == .allowed }

    /// The Permissions row's value.
    public var statusLabel: String {
        switch (access, authorization) {
        case (.never, _): "Not allowed"
        case (.always, .denied): "Off in iOS Settings"
        case (.always, _): "Allowed"
        }
    }

    /// Stores the choice; choosing Always asks iOS for permission if it hasn't been asked yet.
    public func setAccess(_ access: Access) async {
        self.access = access
        defaults.set(access.rawValue, forKey: key)
        guard access == .always else {
            coordinate = nil
            locatedAt = nil
            return
        }
        authorization = provider.authorization == .notDetermined
            ? await provider.requestAuthorization()
            : provider.authorization
        await refresh()
    }

    /// Re-reads iOS's permission (e.g. after returning from iOS Settings) and the position.
    public func refresh() async {
        authorization = provider.authorization
        guard isSharing, !isLocating else { return }
        isLocating = true
        defer { isLocating = false }
        if let located = await provider.currentCoordinate() {
            coordinate = located
            locatedAt = now()
        }
    }

    /// The prompt variables for the next request (`{{USER_LOCATION}}` when shared). A stale
    /// position is refreshed in the background for the following one.
    public func requestVariables() -> [String: String] {
        guard isSharing else { return [:] }
        if locatedAt.map({ now().timeIntervalSince($0) > maximumAge }) ?? true {
            Task { await refresh() }
        }
        guard let coordinate else { return [:] }
        return ["{{USER_LOCATION}}": coordinate.promptValue]
    }

    /// Forgets the choice (the Account was removed from the device).
    public func removeAll() {
        defaults.removeObject(forKey: key)
        access = .never
        coordinate = nil
    }
}

#if canImport(CoreLocation)
/// `LocationProviding` over `CLLocationManager`: "While Using the App" access and one-shot
/// positions at roughly kilometre accuracy (enough for local answers, kinder to privacy).
@MainActor
public final class SystemLocationProvider: LocationProviding {
    private let manager = CLLocationManager()
    private let delegate = Delegate()

    public init() {
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = delegate
    }

    public var authorization: LocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    public func requestAuthorization() async -> LocationAuthorization {
        guard manager.authorizationStatus == .notDetermined else { return authorization }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onAuthorization?()
            delegate.onAuthorization = { continuation.resume() }
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        }
        return authorization
    }

    public func currentCoordinate() async -> Coordinate? {
        guard authorization == .allowed else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Coordinate?, Never>) in
            delegate.onLocation?(nil)
            delegate.onLocation = { location in continuation.resume(returning: location) }
            manager.requestLocation()
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .allowed
        }
    }

    /// Bridges the delegate callbacks to one waiting continuation each.
    private final class Delegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        @MainActor var onAuthorization: (() -> Void)?
        @MainActor var onLocation: ((Coordinate?) -> Void)?

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let undetermined = manager.authorizationStatus == .notDetermined
            Task { @MainActor in
                // The first callback reports the current (undetermined) state; wait for the answer.
                guard !undetermined else { return }
                self.onAuthorization?()
                self.onAuthorization = nil
            }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            let coordinate = locations.last.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            Task { @MainActor in
                self.onLocation?(coordinate)
                self.onLocation = nil
            }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
            Task { @MainActor in
                self.onLocation?(nil)
                self.onLocation = nil
            }
        }
    }
}
#endif
