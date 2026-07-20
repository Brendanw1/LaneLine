import Foundation
import CoreLocation

/// Pure ride-statistics math. Fed one positional input at a time (~1 Hz), it
/// maintains running totals using bike-computer conventions: auto-pause
/// below walking speed, hysteresis on climbing, gap-tolerant distance.
/// No timers, no services — fully deterministic for tests.
struct RideAggregator {
    struct Config {
        var speedSmoothingSeconds: Double = 3
        var autoPauseBelowMs: Double = 1.0
        var autoPauseAfterSeconds: Double = 3
        var ascentHysteresisMeters: Double = 2
        var gradeWindowMeters: Double = 20
        var maxPlausibleJumpMeters: Double = 100
        var maxGradeDecimal: Double = 0.25
    }

    struct Input {
        var timestamp: Double        // seconds since ride start
        var latitude: Double
        var longitude: Double
        var altitudeMeters: Double?
        var speedMs: Double?         // nil → derived from position deltas
    }

    struct Totals: Equatable {
        var distanceMeters: Double = 0
        var elapsedSeconds: Double = 0
        var movingSeconds: Double = 0
        var speedMs: Double = 0
        var maxSpeedMs: Double = 0
        var ascentMeters: Double = 0
        var descentMeters: Double = 0
        var kilocalories: Double = 0
        var gradeDecimal: Double?
        var altitudeMeters: Double?
        var isAutoPaused = false

        var averageSpeedMs: Double {
            movingSeconds > 0 ? distanceMeters / movingSeconds : 0
        }
    }

    private(set) var totals = Totals()

    private let profile: RiderProfile
    private let config: Config
    private var last: Input?
    private var slowSeconds: Double = 0
    /// Hysteresis reference: ascent/descent commit only when altitude moves
    /// more than the band away from this anchor.
    private var referenceAltitude: Double?
    /// Trailing (cumulative distance, altitude) points for grade.
    private var gradeTrail: [(distance: Double, altitude: Double)] = []

    init(profile: RiderProfile, config: Config = Config()) {
        self.profile = profile
        self.config = config
    }

    mutating func ingest(_ input: Input) -> RideSample {
        defer { last = input }

        guard let previous = last else {
            // First fix establishes baselines only.
            totals.speedMs = max(0, input.speedMs ?? 0)
            if let altitude = input.altitudeMeters {
                referenceAltitude = altitude
                totals.altitudeMeters = altitude
                gradeTrail = [(0, altitude)]
            }
            return sample(for: input)
        }

        let dt = input.timestamp - previous.timestamp
        guard dt > 0 else { return sample(for: input) }
        totals.elapsedSeconds += dt

        // Distance, with a teleport guard: implausible hops accrue nothing.
        let hop = GeoMath.distanceMeters(
            from: CLLocationCoordinate2D(latitude: previous.latitude, longitude: previous.longitude),
            to: CLLocationCoordinate2D(latitude: input.latitude, longitude: input.longitude)
        )
        let accepted = hop > config.maxPlausibleJumpMeters ? 0 : hop

        // Speed: reported when available, else positional; EMA-smoothed.
        let instantaneous = max(0, input.speedMs ?? (accepted / dt))
        let alpha = dt / (config.speedSmoothingSeconds + dt)
        totals.speedMs += alpha * (instantaneous - totals.speedMs)

        // Auto-pause state updates before time accrual.
        if totals.speedMs < config.autoPauseBelowMs {
            slowSeconds += dt
            if slowSeconds >= config.autoPauseAfterSeconds { totals.isAutoPaused = true }
        } else {
            slowSeconds = 0
            totals.isAutoPaused = false
        }

        totals.distanceMeters += accepted
        if !totals.isAutoPaused {
            totals.movingSeconds += dt
            totals.maxSpeedMs = max(totals.maxSpeedMs, totals.speedMs)
        }

        updateElevation(input.altitudeMeters)
        updateCalories(dt: dt)
        return sample(for: input)
    }

    // MARK: Internals

    private mutating func updateElevation(_ altitude: Double?) {
        guard let altitude else { return }
        totals.altitudeMeters = altitude

        guard let reference = referenceAltitude else {
            referenceAltitude = altitude
            gradeTrail = [(totals.distanceMeters, altitude)]
            return
        }
        // Strictly outside the band: a swing exactly equal to the band is
        // still "noise" (±1 m oscillation peaks 2 m apart must not count).
        let delta = altitude - reference
        if delta > config.ascentHysteresisMeters {
            totals.ascentMeters += delta
            referenceAltitude = altitude
        } else if delta < -config.ascentHysteresisMeters {
            totals.descentMeters += -delta
            referenceAltitude = altitude
        }

        // Grade over the trailing window: keep the most recent point that is
        // still a full window behind as the slope base.
        gradeTrail.append((totals.distanceMeters, altitude))
        while gradeTrail.count >= 2,
              totals.distanceMeters - gradeTrail[1].distance >= config.gradeWindowMeters {
            gradeTrail.removeFirst()
        }
        let base = gradeTrail[0]
        let run = totals.distanceMeters - base.distance
        if run >= config.gradeWindowMeters {
            let raw = (altitude - base.altitude) / run
            totals.gradeDecimal = min(config.maxGradeDecimal, max(-config.maxGradeDecimal, raw))
        }
    }

    private mutating func updateCalories(dt: Double) {
        guard !totals.isAutoPaused else { return }
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: totals.speedMs,
            gradeDecimal: totals.gradeDecimal ?? 0,
            riderKg: profile.weightKg,
            bikeType: profile.bikeType
        )
        totals.kilocalories += CyclingPowerModel.kilocalories(mechanicalJoules: watts * dt)
    }

    private func sample(for input: Input) -> RideSample {
        RideSample(
            t: input.timestamp,
            latitude: input.latitude,
            longitude: input.longitude,
            altitudeMeters: totals.altitudeMeters,
            speedKmh: totals.speedMs * 3.6,
            distanceMeters: totals.distanceMeters,
            gradeDecimal: totals.gradeDecimal
        )
    }
}
