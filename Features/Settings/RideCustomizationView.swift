import SwiftUI

/// Ride-screen layout preferences: layout mode, control sizing, contrast,
/// metric ordering, music tray default, and which secondary metrics show.
struct RideCustomizationView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section {
                Picker("Layout", selection: binding(\.layoutMode)) {
                    Text("Standard").tag(LayoutMode.standard)
                    Text("Larger controls").tag(LayoutMode.largerControls)
                }
                Toggle("Larger touch targets", isOn: binding(\.largerControlsEnabled))
                Toggle("High contrast", isOn: binding(\.highContrastEnabled))
            } header: {
                Text("Layout")
            } footer: {
                Text("High contrast locks the ride screen to dark styling for sunlight legibility.")
            }

            Section {
                Picker("Lead metric", selection: binding(\.metricsPriority)) {
                    ForEach(MetricsPriority.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            } header: {
                Text("Metrics")
            } footer: {
                Text("The lead metric takes the leftmost, most glanceable slot.")
            }

            Section {
                ForEach(RideScreenCustomization.SecondaryMetric.allCases, id: \.self) { metric in
                    Toggle(metric.displayName, isOn: secondaryMetricBinding(metric))
                }
            } header: {
                Text("Secondary metrics")
            }

            Section {
                Toggle("Music tray expanded by default", isOn: binding(\.musicTrayDefaultExpanded))
            } header: {
                Text("Music")
            } footer: {
                Text("When on, the ride starts with the full player sheet open at half height.")
            }
        }
        .navigationTitle("Ride screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<RideScreenCustomization, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appModel.rideCustomization[keyPath: keyPath] },
            set: { newValue in
                var customization = appModel.rideCustomization
                customization[keyPath: keyPath] = newValue
                appModel.updateCustomization(customization)
            }
        )
    }

    private func secondaryMetricBinding(
        _ metric: RideScreenCustomization.SecondaryMetric
    ) -> Binding<Bool> {
        Binding(
            get: { appModel.rideCustomization.visibleSecondaryMetrics.contains(metric) },
            set: { include in
                var customization = appModel.rideCustomization
                if include {
                    customization.visibleSecondaryMetrics.insert(metric)
                } else {
                    customization.visibleSecondaryMetrics.remove(metric)
                }
                appModel.updateCustomization(customization)
            }
        )
    }
}

extension RideScreenCustomization.SecondaryMetric {
    var displayName: String {
        switch self {
        case .currentGrade: return "Live grade"
        case .climbRemaining: return "Climb remaining"
        case .routeQuality: return "Route quality"
        case .currentSpeed: return "Current speed"
        case .averageSpeed: return "Average speed"
        }
    }
}

#Preview {
    NavigationStack {
        RideCustomizationView()
    }
    .serviceContainer(.preview())
    .environment(PreviewData.appModel())
}
