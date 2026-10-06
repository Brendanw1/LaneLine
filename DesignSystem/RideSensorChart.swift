import SwiftUI
import Charts

/// One sensor stream over a ride, plotted against ride time.
struct RideSensorSeries: Identifiable {
    struct Point: Identifiable {
        let minutes: Double
        let value: Double
        var id: Double { minutes }
    }

    let title: String
    let unit: String
    let color: Color
    let points: [Point]
    var id: String { title }
}

/// Ride-summary trace for heart rate (Apple Watch) and cadence (sensor or
/// Watch): one compact line chart per stream so different units never
/// share an axis. Long rides are downsampled to keep the chart cheap.
struct RideSensorChart: View {
    let series: RideSensorSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(series.title) (\(series.unit))")
                .font(LaneLineDesign.Typography.metricLabel)
                .foregroundStyle(.secondary)
            Chart(series.points) { point in
                LineMark(
                    x: .value("Time", point.minutes),
                    y: .value(series.title, point.value)
                )
                .foregroundStyle(series.color)
                .interpolationMethod(.monotone)
            }
            .chartXAxisLabel("min")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 110)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(series.title) over the ride")
    }
}

extension RideSensorSeries {
    /// Builds a series from recorded samples, skipping samples without a
    /// value and averaging into at most `maxPoints` buckets.
    static func from(
        _ samples: [RideSample], title: String, unit: String, color: Color,
        value: (RideSample) -> Double?, maxPoints: Int = 240
    ) -> RideSensorSeries? {
        let raw = samples.compactMap { sample in value(sample).map { (sample.t, $0) } }
        guard raw.count >= 2 else { return nil }
        let bucket = max(1, Int((Double(raw.count) / Double(maxPoints)).rounded(.up)))
        var points: [Point] = []
        var index = 0
        while index < raw.count {
            let slice = raw[index..<min(index + bucket, raw.count)]
            let t = slice.map { $0.0 }.reduce(0, +) / Double(slice.count)
            let v = slice.map { $0.1 }.reduce(0, +) / Double(slice.count)
            points.append(Point(minutes: t / 60, value: v))
            index += bucket
        }
        return RideSensorSeries(title: title, unit: unit, color: color, points: points)
    }
}
