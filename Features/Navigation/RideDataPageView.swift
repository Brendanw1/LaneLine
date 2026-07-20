import SwiftUI

/// One full-screen bike-computer data page: a two-column grid of metric
/// cells driven entirely by metric IDs from `RideScreenCustomization`.
/// Edit mode lets the rider retarget any cell, add/remove cells, and
/// add/remove whole pages; changes persist through `onUpdate`.
struct RideDataPageView: View {
    let page: RideDataPage
    let recorder: RideRecorder
    let ride: ActiveRideModel
    var onUpdate: (RideDataPage) -> Void = { _ in }
    var onDeletePage: (() -> Void)?
    var onAddPage: (() -> Void)?

    @State private var isEditing = false
    @State private var editingSlot: EditingSlot?

    private struct EditingSlot: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private let columns = [
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
    ]

    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            header
            LazyVGrid(columns: columns, spacing: LaneLineDesign.Spacing.small) {
                ForEach(Array(page.metrics.enumerated()), id: \.offset) { index, metric in
                    cell(for: metric, at: index)
                }
                if isEditing && page.metrics.count < RideDataPage.maxMetrics {
                    addMetricCell
                }
            }
            if isEditing {
                editActions
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaneLineDesign.Colors.background)
        .sheet(item: $editingSlot) { slot in
            MetricPickerSheet(current: page.metrics[slot.index]) { picked in
                var updated = page
                updated.metrics[slot.index] = picked
                onUpdate(updated)
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                isEditing.toggle()
            } label: {
                Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "Done editing" : "Edit page")
        }
    }

    private func cell(for metric: RideMetricID, at index: Int) -> some View {
        RideMetricCell(
            display: RideMetricCatalog.display(metric, recorder: recorder, ride: ride)
        )
        .overlay(alignment: .topTrailing) {
            if isEditing && page.metrics.count > 1 {
                Button {
                    var updated = page
                    updated.metrics.remove(at: index)
                    onUpdate(updated)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(LaneLineDesign.Colors.danger)
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("Remove \(metric.title)")
            }
        }
        .onTapGesture {
            if isEditing { editingSlot = EditingSlot(index: index) }
        }
    }

    private var addMetricCell: some View {
        Button {
            var updated = page
            updated.metrics.append(firstUnusedMetric)
            onUpdate(updated)
        } label: {
            Image(systemName: "plus")
                .font(.title)
                .frame(maxWidth: .infinity, minHeight: 96)
        }
        .buttonStyle(.plain)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityLabel("Add metric")
    }

    private var firstUnusedMetric: RideMetricID {
        RideMetricID.allCases.first { !page.metrics.contains($0) } ?? .currentSpeed
    }

    private var editActions: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            if let onAddPage {
                Button("Add page", systemImage: "plus.rectangle.on.rectangle", action: onAddPage)
            }
            if let onDeletePage {
                Button("Remove page", systemImage: "trash", role: .destructive, action: onDeletePage)
                    .foregroundStyle(LaneLineDesign.Colors.danger)
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
    }
}

// MARK: - Metric Cell

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

// MARK: - Metric Picker

struct MetricPickerSheet: View {
    let current: RideMetricID
    let onPick: (RideMetricID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(RideMetricID.allCases) { metric in
                Button {
                    onPick(metric)
                    dismiss()
                } label: {
                    HStack {
                        Text(metric.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if metric == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LaneLineDesign.Colors.primary)
                        }
                    }
                }
            }
            .navigationTitle("Choose metric")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
