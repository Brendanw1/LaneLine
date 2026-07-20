import SwiftUI

/// Recorded rides, newest first. Rows open the stored ride's summary
/// read-only; swipe to delete.
struct RideHistoryView: View {
    @Environment(\.services) private var services

    @State private var summaries: [RideSummary] = []
    @State private var selectedRecord: RideRecord?

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "bicycle",
                        description: Text("Finish a ride and save it to see it here.")
                    )
                } else {
                    List {
                        ForEach(summaries) { summary in
                            Button {
                                Task {
                                    selectedRecord = await services.rideStore.loadRecord(id: summary.id)
                                }
                            } label: {
                                row(summary)
                            }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { summaries[$0] }
                            summaries.remove(atOffsets: offsets)
                            Task {
                                for summary in doomed {
                                    await services.rideStore.delete(id: summary.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rides")
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(item: $selectedRecord) { record in
                RideSummaryView(record: record)
            }
        }
    }

    private func reload() async {
        summaries = await services.rideStore.loadSummaries()
    }

    private func row(_ summary: RideSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.routeName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !summary.isComplete {
                    Text("Interrupted")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            LaneLineDesign.Colors.warning.opacity(0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(LaneLineDesign.Colors.warning)
                }
                Spacer()
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "\(RideFormat.distance(summary.distanceMeters))  ·  "
                + "\(RideFormat.stopwatch(summary.movingSeconds))  ·  "
                + "↑ \(RideFormat.elevation(summary.ascentMeters))"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    RideHistoryView()
        .serviceContainer(.preview())
}
