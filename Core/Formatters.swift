import Foundation

/// Shared display formatting so metrics read identically on every screen.
enum RideFormat {
    static func distance(_ meters: Double) -> String {
        if meters < 950 {
            return "\(Int((meters / 10).rounded() * 10)) m"
        }
        return String(format: "%.1f km", meters / 1000)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder > 0 ? "\(minutes / 60)h \(remainder)m" : "\(minutes / 60)h"
        }
        return "\(max(1, minutes)) min"
    }

    static func eta(arrivingIn seconds: Double, from now: Date = .now) -> String {
        now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }

    static func elevation(_ meters: Double) -> String {
        "\(Int(meters.rounded())) m"
    }

    /// Grade is stored as a decimal (0.08 = 8%).
    static func grade(_ decimal: Double) -> String {
        String(format: "%.0f%%", abs(decimal) * 100)
    }

    static func signedGrade(_ decimal: Double) -> String {
        String(format: "%+.0f%%", decimal * 100)
    }

    /// Percent-of-route values stored as 0...1.
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// 0...1 quality/confidence scores shown as a 10-point scale.
    static func score(_ value: Double) -> String {
        String(format: "%.1f", value * 10)
    }

    /// Speed magnitude without unit — data cells show the unit separately.
    static func speedValue(_ kmh: Double) -> String {
        String(format: "%.1f", max(0, kmh))
    }

    /// Ride-timer style: "12:05" under an hour, "1:02:05" over.
    static func stopwatch(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func wholeNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }
}
