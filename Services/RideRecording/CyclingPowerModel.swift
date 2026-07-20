import Foundation

/// Physics-based pedaling power: rolling resistance + aero drag + climbing,
/// from speed, grade, rider weight, and per-bike-type constants. Drives
/// calorie estimation until real power meters arrive (BLE phase).
enum CyclingPowerModel {
    private static let airDensityKgM3 = 1.225
    private static let gravity = 9.81

    /// Bike mass in kg, including typical lock/cargo load.
    static func bikeMassKg(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 9
        case .hybridFitness: return 12
        case .gravel: return 10
        case .cityBike: return 15
        case .eBike: return 23
        }
    }

    /// Drag coefficient × frontal area (CdA, m²) for the typical riding
    /// position on each bike type.
    static func dragAreaM2(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 0.36
        case .hybridFitness: return 0.45
        case .gravel: return 0.40
        case .cityBike: return 0.55
        case .eBike: return 0.50
        }
    }

    /// Rolling resistance coefficient for typical tires on asphalt.
    static func rollingResistance(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 0.004
        case .hybridFitness: return 0.006
        case .gravel: return 0.008
        case .cityBike: return 0.007
        case .eBike: return 0.007
        }
    }

    /// The share of total power the rider provides; the motor covers the
    /// rest on an e-bike.
    private static func riderShare(_ type: BikeType) -> Double {
        type == .eBike ? 0.5 : 1.0
    }

    /// Mechanical watts the rider produces. Zero when coasting — descents
    /// can demand no pedaling.
    static func mechanicalWatts(
        speedMs: Double, gradeDecimal: Double, riderKg: Double, bikeType: BikeType
    ) -> Double {
        guard speedMs > 0 else { return 0 }
        let massKg = riderKg + bikeMassKg(bikeType)
        let rolling = rollingResistance(bikeType) * massKg * gravity * speedMs
        let aero = 0.5 * airDensityKgM3 * dragAreaM2(bikeType) * pow(speedMs, 3)
        let climbing = massKg * gravity * speedMs * gradeDecimal
        return max(0, (rolling + aero + climbing) * riderShare(bikeType))
    }

    /// Mechanical joules → metabolic kilocalories at ~24 % efficiency.
    static func kilocalories(mechanicalJoules: Double) -> Double {
        mechanicalJoules / (4184 * 0.24)
    }
}
