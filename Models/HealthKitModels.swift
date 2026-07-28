import Foundation

// MARK: - HealthKit Authorization State

/// Share (write-only) authorization for the workout/distance/energy/route
/// types LaneLine writes. LaneLine never reads health data, so this only
/// reflects write permission.
enum HealthKitAuthorizationState: String, Codable {
    case notDetermined
    case denied
    case authorized
}
