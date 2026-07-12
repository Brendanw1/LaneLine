import Foundation
import CoreLocation
import Observation

// MARK: - Location Service Protocol

@MainActor
protocol LocationServicing: AnyObject, Observable {
    var currentLocation: CLLocation? { get }
    /// Heading in degrees, when available.
    var currentHeading: Double? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var isAuthorized: Bool { get }

    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
    func reverseGeocodeStreetName(at coordinate: CLLocationCoordinate2D) async -> String?
}

// MARK: - Live CoreLocation Implementation

@MainActor
@Observable
final class LocationService: LocationServicing {
    private(set) var currentLocation: CLLocation?
    private(set) var currentHeading: Double?
    private(set) var authorizationStatus: CLAuthorizationStatus

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var delegateProxy: DelegateProxy?

    init() {
        authorizationStatus = manager.authorizationStatus

        let proxy = DelegateProxy()
        proxy.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in self?.authorizationStatus = status }
        }
        proxy.onLocationUpdate = { [weak self] location in
            Task { @MainActor in self?.currentLocation = location }
        }
        proxy.onHeadingUpdate = { [weak self] heading in
            Task { @MainActor in self?.currentHeading = heading }
        }
        delegateProxy = proxy

        manager.delegate = proxy
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .otherNavigation
        manager.distanceFilter = 5
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        // Ride guidance keeps running with the phone mounted and locked.
        manager.allowsBackgroundLocationUpdates = isAuthorized
        manager.pausesLocationUpdatesAutomatically = false
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    func reverseGeocodeStreetName(at coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        return placemarks?.first?.thoroughfare
    }

    /// CLLocationManagerDelegate must be an NSObject; this proxy bridges the
    /// delegate callbacks into the observable service.
    private final class DelegateProxy: NSObject, CLLocationManagerDelegate {
        var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
        var onLocationUpdate: ((CLLocation) -> Void)?
        var onHeadingUpdate: ((Double) -> Void)?

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            onAuthorizationChange?(manager.authorizationStatus)
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let latest = locations.last else { return }
            onLocationUpdate?(latest)
        }

        func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard newHeading.headingAccuracy >= 0 else { return }
            onHeadingUpdate?(newHeading.trueHeading)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            // Transient failures (kCLErrorLocationUnknown) resolve on their
            // own; the ride screen degrades to route-position estimates.
        }
    }
}

// MARK: - Preview / Simulator Mock

@MainActor
@Observable
final class MockLocationService: LocationServicing {
    private(set) var currentLocation: CLLocation?
    private(set) var currentHeading: Double?
    private(set) var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse

    var isAuthorized: Bool { authorizationStatus == .authorizedWhenInUse }

    /// Pass `nil` for a fix-less mock: ride progress then falls back to the
    /// simulation engine, which is what demo mode wants.
    init(coordinate: CLLocationCoordinate2D? = .init(latitude: 37.76490, longitude: -122.42190)) {
        if let coordinate {
            currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    func requestAuthorization() {}
    func startUpdating() {}
    func stopUpdating() {}

    func reverseGeocodeStreetName(at coordinate: CLLocationCoordinate2D) async -> String? {
        "Valencia St"
    }

    func setLocation(_ coordinate: CLLocationCoordinate2D, heading: Double? = nil) {
        currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let heading { currentHeading = heading }
    }
}
