import SwiftUI
import CoreLocation

/// Saved places and recent destinations — the commute-preset surface. Saved
/// places also appear as quick chips on the home map.
struct SavedPlacesView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isAddingPlace = false

    var body: some View {
        NavigationStack {
            List {
                if !appModel.savedPlaces.isEmpty {
                    Section("Saved places") {
                        ForEach(appModel.savedPlaces) { place in
                            SavedPlaceRow(place: place)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                appModel.deletePlace(appModel.savedPlaces[offset])
                            }
                        }
                    }
                }

                if !appModel.recentDestinations.isEmpty {
                    Section("Recent destinations") {
                        ForEach(appModel.recentDestinations) { recent in
                            HStack(spacing: LaneLineDesign.Spacing.medium) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recent.name)
                                        .font(.body.weight(.medium))
                                    Text(recent.address)
                                        .font(.caption)
                                        .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    appModel.savePlace(SavedPlace(
                                        id: UUID(),
                                        name: recent.name,
                                        address: recent.address,
                                        latitude: recent.latitude,
                                        longitude: recent.longitude,
                                        placeType: .custom
                                    ))
                                } label: {
                                    Image(systemName: "bookmark")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Save \(recent.name)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingPlace = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add place")
                }
            }
            .overlay {
                if appModel.savedPlaces.isEmpty && appModel.recentDestinations.isEmpty {
                    ContentUnavailableView(
                        "No places yet",
                        systemImage: "bookmark.slash",
                        description: Text("Save home, work, and frequent destinations for one-tap route planning.")
                    )
                }
            }
            .sheet(isPresented: $isAddingPlace) {
                AddPlaceView()
            }
        }
    }
}

private struct SavedPlaceRow: View {
    let place: SavedPlace

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            Image(systemName: place.placeType.systemImage)
                .font(.title3)
                .foregroundStyle(LaneLineDesign.Colors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.body.weight(.medium))
                Text(place.address)
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Add Place

/// Search-backed place creation: find the location with MapKit, label it,
/// pick a type.
private struct AddPlaceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchModel = DestinationSearchModel()
    @State private var pendingDestination: SelectedDestination?
    @State private var label = ""
    @State private var placeType: SavedPlace.PlaceType = .custom

    var body: some View {
        NavigationStack {
            Form {
                if let destination = pendingDestination {
                    Section("Location") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.name).font(.body.weight(.medium))
                            Text(destination.address)
                                .font(.caption)
                                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        }
                        Button("Change location") { pendingDestination = nil }
                    }
                    Section("Details") {
                        TextField("Label (e.g. Home)", text: $label)
                        Picker("Type", selection: $placeType) {
                            Text("Home").tag(SavedPlace.PlaceType.home)
                            Text("Work").tag(SavedPlace.PlaceType.work)
                            Text("Frequent").tag(SavedPlace.PlaceType.frequent)
                            Text("Other").tag(SavedPlace.PlaceType.custom)
                        }
                    }
                } else {
                    Section {
                        ForEach(searchModel.completions, id: \.self) { completion in
                            Button {
                                Task {
                                    if let destination = await searchModel.resolve(completion) {
                                        pendingDestination = destination
                                        if label.isEmpty { label = destination.name }
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(completion.title)
                                        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(
                text: $searchModel.query,
                placement: .navigationBarDrawer(displayMode: pendingDestination == nil ? .always : .automatic),
                prompt: "Search for an address or place"
            )
            .navigationTitle("Add Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(pendingDestination == nil || label.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let destination = pendingDestination else { return }
        appModel.savePlace(SavedPlace(
            id: UUID(),
            name: label,
            address: destination.address,
            latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude,
            placeType: placeType
        ))
        dismiss()
    }
}

#Preview {
    SavedPlacesView()
        .serviceContainer(.preview())
        .environment(PreviewData.appModel())
}
