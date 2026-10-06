import Foundation

// MARK: - CSC Measurement (Bluetooth SIG 0x2A5B)

/// One notification from a Bluetooth Cycling Speed and Cadence sensor
/// (service 0x1816, characteristic 0x2A5B) — the profile the Magene S3+
/// and every other BLE speed/cadence pod speaks. The sensor never sends a
/// speed or an RPM: it sends cumulative revolution counters plus the time
/// of the last revolution event (1/1024 s ticks), and the receiver derives
/// rates from consecutive notifications. Either half may be absent — a
/// Magene S3+ reports wheel data in speed mode and crank data in cadence
/// mode, never both.
struct CSCMeasurement: Equatable {
    var cumulativeWheelRevolutions: UInt32?
    /// 1/1024 s, rolls over every 64 s.
    var lastWheelEventTime: UInt16?
    var cumulativeCrankRevolutions: UInt16?
    /// 1/1024 s, rolls over every 64 s.
    var lastCrankEventTime: UInt16?

    var hasWheelData: Bool { cumulativeWheelRevolutions != nil }
    var hasCrankData: Bool { cumulativeCrankRevolutions != nil }

    init(
        cumulativeWheelRevolutions: UInt32? = nil,
        lastWheelEventTime: UInt16? = nil,
        cumulativeCrankRevolutions: UInt16? = nil,
        lastCrankEventTime: UInt16? = nil
    ) {
        self.cumulativeWheelRevolutions = cumulativeWheelRevolutions
        self.lastWheelEventTime = lastWheelEventTime
        self.cumulativeCrankRevolutions = cumulativeCrankRevolutions
        self.lastCrankEventTime = lastCrankEventTime
    }

    /// Parses the little-endian characteristic value. Returns nil for a
    /// payload shorter than its flags promise — a truncated packet must not
    /// be read as zeroed counters (that would look like a huge rollover).
    init?(data: Data) {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let wheelPresent = flags & 0x01 != 0
        let crankPresent = flags & 0x02 != 0
        let expected = 1 + (wheelPresent ? 6 : 0) + (crankPresent ? 4 : 0)
        guard bytes.count >= expected else { return nil }

        var offset = 1
        func u16() -> UInt16 {
            defer { offset += 2 }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        if wheelPresent {
            cumulativeWheelRevolutions = u32()
            lastWheelEventTime = u16()
        }
        if crankPresent {
            cumulativeCrankRevolutions = u16()
            lastCrankEventTime = u16()
        }
    }
}

// MARK: - Rate Calculator

/// Pure CSC math: turns a stream of measurements into live cadence (RPM),
/// wheel speed, and wheel distance. Bike-computer conventions:
/// - Counters and event times wrap (UInt16/UInt32); deltas use wrapping
///   subtraction so a rollover mid-ride is just another delta.
/// - A repeated event time means "no new revolution"; after
///   `staleAfterSeconds` without one the rate drops to zero (the rider
///   stopped pedaling / the wheel stopped), instead of freezing the last
///   value on screen.
/// - Implausible deltas (a sensor reboot, a reconnect after a long gap)
///   re-baseline instead of producing a 400 RPM spike.
/// No timers, no Bluetooth — `now` is injected, so tests are exact.
struct CSCRateCalculator {
    struct Config {
        var wheelCircumferenceMeters: Double = 2.105
        var staleAfterSeconds: Double = 3
        var maxCadenceRPM: Double = 220
        var maxSpeedMs: Double = 120 / 3.6
        /// Revolutions in one notification beyond this are a reset, not riding.
        var maxCrankRevsPerEvent: Int = 20
        var maxWheelRevsPerEvent: Int = 60
    }

    var config: Config

    /// Nil until the sensor has produced one real rate (or gone stale,
    /// which proves it's connected and the cranks aren't turning).
    private(set) var cadenceRPM: Double?
    private(set) var wheelSpeedMs: Double?
    /// Distance accrued from wheel revolutions since the first measurement.
    private(set) var wheelDistanceMeters: Double = 0
    /// Total crank revolutions counted since the first measurement.
    private(set) var crankRevolutions: Int = 0

    private var lastCrank: (revs: UInt16, time: UInt16)?
    private var lastCrankEventAt: Double?
    private var lastWheel: (revs: UInt32, time: UInt16)?
    private var lastWheelEventAt: Double?

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func ingest(_ measurement: CSCMeasurement, at now: Double) {
        if let revs = measurement.cumulativeCrankRevolutions,
           let time = measurement.lastCrankEventTime {
            ingestCrank(revs: revs, time: time, now: now)
        }
        if let revs = measurement.cumulativeWheelRevolutions,
           let time = measurement.lastWheelEventTime {
            ingestWheel(revs: revs, time: time, now: now)
        }
        expire(now: now)
    }

    /// Drops rates to zero once no revolution event has arrived for the
    /// stale window. Call periodically: a Magene S3+ stops notifying
    /// entirely when it stops moving, so measurements alone can't do this.
    mutating func expire(now: Double) {
        if let at = lastCrankEventAt, now - at > config.staleAfterSeconds {
            cadenceRPM = 0
        }
        if let at = lastWheelEventAt, now - at > config.staleAfterSeconds {
            wheelSpeedMs = 0
        }
    }

    /// Forget baselines (on disconnect) but keep accrued totals.
    mutating func resetBaselines() {
        lastCrank = nil
        lastWheel = nil
        lastCrankEventAt = nil
        lastWheelEventAt = nil
        cadenceRPM = nil
        wheelSpeedMs = nil
    }

    // MARK: Internals

    private mutating func ingestCrank(revs: UInt16, time: UInt16, now: Double) {
        defer { lastCrank = (revs, time) }
        guard let previous = lastCrank else {
            // Baseline only; the stale clock starts so a stationary crank
            // reads 0 after the window rather than "—" forever.
            lastCrankEventAt = now
            return
        }
        let deltaRevs = Int(revs &- previous.revs)
        let deltaTicks = Int(time &- previous.time)
        guard deltaTicks > 0, deltaRevs > 0 else { return }   // no new event
        guard deltaRevs <= config.maxCrankRevsPerEvent else {
            lastCrankEventAt = now
            return
        }
        let rpm = Double(deltaRevs) * 60 * 1024 / Double(deltaTicks)
        lastCrankEventAt = now
        crankRevolutions += deltaRevs
        guard rpm <= config.maxCadenceRPM else { return }
        cadenceRPM = rpm
    }

    private mutating func ingestWheel(revs: UInt32, time: UInt16, now: Double) {
        defer { lastWheel = (revs, time) }
        guard let previous = lastWheel else {
            lastWheelEventAt = now
            return
        }
        let deltaRevs = Int(revs &- previous.revs)
        let deltaTicks = Int(time &- previous.time)
        guard deltaTicks > 0, deltaRevs > 0 else { return }
        guard deltaRevs <= config.maxWheelRevsPerEvent else {
            lastWheelEventAt = now
            return
        }
        let meters = Double(deltaRevs) * config.wheelCircumferenceMeters
        let speed = meters / (Double(deltaTicks) / 1024)
        lastWheelEventAt = now
        guard speed <= config.maxSpeedMs else { return }
        wheelDistanceMeters += meters
        wheelSpeedMs = speed
    }
}

// MARK: - Wheel Sizes

/// Common tire circumferences (mm) for the wheel-size picker — the CSC
/// profile counts revolutions, so speed is only as good as this number.
enum WheelSize: CaseIterable, Identifiable {
    case road700x23, road700x25, road700x28, road700x32, road700x35, road700x38
    case road650bx47, mtb26x2_0, mtb27_5x2_1, mtb29x2_2

    var id: Self { self }

    var circumferenceMm: Double {
        switch self {
        case .road700x23: 2096
        case .road700x25: 2105
        case .road700x28: 2136
        case .road700x32: 2155
        case .road700x35: 2168
        case .road700x38: 2180
        case .road650bx47: 2079
        case .mtb26x2_0: 2055
        case .mtb27_5x2_1: 2148
        case .mtb29x2_2: 2298
        }
    }

    var label: String {
        switch self {
        case .road700x23: "700×23c"
        case .road700x25: "700×25c"
        case .road700x28: "700×28c"
        case .road700x32: "700×32c"
        case .road700x35: "700×35c"
        case .road700x38: "700×38c"
        case .road650bx47: "650b×47"
        case .mtb26x2_0: "26×2.0"
        case .mtb27_5x2_1: "27.5×2.1"
        case .mtb29x2_2: "29×2.2"
        }
    }

    static func matching(mm: Double) -> WheelSize? {
        allCases.first { abs($0.circumferenceMm - mm) < 0.5 }
    }
}
