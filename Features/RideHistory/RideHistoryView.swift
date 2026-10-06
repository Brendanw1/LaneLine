import SwiftUI

/// Recorded rides, newest first. Rows open the stored ride's summary
/// read-only; swipe to delete.
struct RideHistoryView: View {
    @Environment(\.services) private var services

    @State private var summaries: [RideSummary] = []
    @State private var selectedRecord: RideRecord?
    @State private var recordLoadFailed = false

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
                                    if let record = await services.rideStore.loadRecord(id: summary.id) {
                                        selectedRecord = record
                                    } else {
                                        recordLoadFailed = true
                                    }
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
                                // Reconcile with disk truth: a delete that
                                // silently failed must reappear, not vanish.
                                summaries = await services.rideStore.loadSummaries()
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
            .alert("Couldn't open that ride", isPresented: $recordLoadFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Its file is missing or damaged.")
            }
        }
    }

    private func reload() async {
        summaries = await services.rideStore.loadSummaries()
    }

    /// "♥ 148 bpm  ·  86 rpm" — only the streams that fed this ride.
    private func sensorLine(_ summary: RideSummary) -> String? {
        var parts: [String] = []
        if let hr = summary.averageHeartRateBPM {
            parts.append("♥ \(RideFormat.wholeNumber(hr)) bpm")
        }
        if let cadence = summary.averageCadenceRPM {
            parts.append("\(RideFormat.wholeNumber(cadence)) rpm")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
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
            if let sensorLine = sensorLine(summary) {
                Text(sensorLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    RideHistoryView()
        .serviceContainer(.preview())
}
