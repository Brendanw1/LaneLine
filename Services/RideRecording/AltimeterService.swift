import Foundation
import CoreMotion
import Observation

// MARK: - Altitude Provider Protocol

/// Barometric altitude change since `start()`. Nil when the device has no
/// barometer (or Motion access is denied) — callers fall back to GPS.
@MainActor
protocol AltitudeProviding: AnyObject {
    var relativeAltitudeMeters: Double? { get }
    func start()
    func stop()
}

// MARK: - CMAltimeter implementation

@MainActor
@Observable
final class AltimeterService: AltitudeProviding {
    private(set) var relativeAltitudeMeters: Double?
    private let altimeter = CMAltimeter()

    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.relativeAltitudeMeters = data.relativeAltitude.doubleValue
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        relativeAltitudeMeters = nil
    }
}

// MARK: - Mock

@MainActor
@Observable
final class MockAltimeter: AltitudeProviding {
    var relativeAltitudeMeters: Double?
    func start() {}
    func stop() {}
}
