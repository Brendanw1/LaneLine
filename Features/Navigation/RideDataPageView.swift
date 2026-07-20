import SwiftUI

/// One full-screen bike-computer data page: a two-column grid of metric
/// cells driven entirely by metric IDs from `RideScreenCustomization`.
struct RideDataPageView: View {
    let page: RideDataPage
    let recorder: RideRecorder
    let ride: ActiveRideModel

    private let columns = [
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
    ]

    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            LazyVGrid(columns: columns, spacing: LaneLineDesign.Spacing.small) {
                ForEach(page.metrics) { metric in
                    RideMetricCell(
                        display: RideMetricCatalog.display(metric, recorder: recorder, ride: ride)
                    )
                }
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaneLineDesign.Colors.background)
    }
}

struct RideMetricCell: View {
    let display: RideMetricDisplay

    var body: some View {
        VStack(spacing: 4) {
            Text(display.value)
                .font(LaneLineDesign.Typography.metricValueLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 4) {
                Text(display.title)
                if !display.unit.isEmpty {
                    Text(display.unit)
                }
            }
            .font(LaneLineDesign.Typography.metricLabel)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityElement(children: .combine)
    }
}
