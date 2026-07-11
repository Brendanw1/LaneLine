import SwiftUI
import MapKit
import Observation

// MARK: - Destination Model

/// A resolved place the rider wants to ride to.
struct SelectedDestination: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: SelectedDestination, rhs: SelectedDestination) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Model

/// Live destination search over MapKit's `MKLocalSearchCompleter`, biased to
/// San Francisco. Selecting a completion resolves it to coordinates with
/// `MKLocalSearch`.
@MainActor
@Observable
final class DestinationSearchModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            completerProxy.completer.queryFragment = query
            if query.isEmpty { completions = [] }
        }
    }
    private(set) var completions: [MKLocalSearchCompletion] = []
    private(set) var isResolving = false
    private(set) var errorMessage: String?

    private let completerProxy = CompleterProxy()

    init() {
        completerProxy.completer.resultTypes = [.address, .pointOfInterest]
        completerProxy.completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4340),
            latitudinalMeters: 14_000,
            longitudinalMeters: 14_000
        )
        completerProxy.onUpdate = { [weak self] results in
            self?.completions = results
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> SelectedDestination? {
        isResolving = true
        defer { isResolving = false }
        errorMessage = nil

        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else {
            errorMessage = "Couldn't find that place. Try a different search."
            return nil
        }
        return SelectedDestination(
            name: item.name ?? completion.title,
            address: completion.subtitle.isEmpty ? completion.title : completion.subtitle,
            coordinate: item.placemark.coordinate
        )
    }

    /// `MKLocalSearchCompleterDelegate` requires NSObject; bridge it in.
    private final class CompleterProxy: NSObject, MKLocalSearchCompleterDelegate {
        let completer = MKLocalSearchCompleter()
        var onUpdate: (([MKLocalSearchCompletion]) -> Void)?

        override init() {
            super.init()
            completer.delegate = self
        }

        func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
            let results = completer.results
            Task { @MainActor [weak self] in self?.onUpdate?(results) }
        }

        func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
            Task { @MainActor [weak self] in self?.onUpdate?([]) }
        }
    }
}

// MARK: - Search Screen

/// Destination picker: live completions plus saved places and recents.
struct DestinationSearchView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var model = DestinationSearchModel()
    let onSelect: (SelectedDestination) -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.query.isEmpty {
                    savedPlacesSection
                    recentsSection
                } else {
                    completionsSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search destinations in SF"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if model.isResolving {
                    ProgressView()
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var savedPlacesSection: some View {
        if !appModel.savedPlaces.isEmpty {
            Section("Saved places") {
                ForEach(appModel.savedPlaces) { place in
                    Button {
                        select(SelectedDestination(
                            name: place.name,
                            address: place.address,
                            coordinate: CLLocationCoordinate2D(
                                latitude: place.latitude, longitude: place.longitude
                            )
                        ))
                    } label: {
                        PlaceRow(
                            title: place.name,
                            subtitle: place.address,
                            icon: place.placeType.systemImage
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !appModel.recentDestinations.isEmpty {
            Section("Recent") {
                ForEach(appModel.recentDestinations) { recent in
                    Button {
                        select(SelectedDestination(
                            name: recent.name,
                            address: recent.address,
                            coordinate: CLLocationCoordinate2D(
                                latitude: recent.latitude, longitude: recent.longitude
                            )
                        ))
                    } label: {
                        PlaceRow(
                            title: recent.name,
                            subtitle: recent.address,
                            icon: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        }
    }

    private var completionsSection: some View {
        Section {
            if let message = model.errorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            }
            ForEach(model.completions, id: \.self) { completion in
                Button {
                    Task {
                        if let destination = await model.resolve(completion) {
                            select(destination)
                        }
                    }
                } label: {
                    PlaceRow(
                        title: completion.title,
                        subtitle: completion.subtitle,
                        icon: "mappin.circle"
                    )
                }
            }
        }
    }

    private func select(_ destination: SelectedDestination) {
        appModel.recordRecentDestination(RecentDestination(
            name: destination.name,
            address: destination.address,
            latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude
        ))
        dismiss()
        onSelect(destination)
    }
}

// MARK: - Rows

private struct PlaceRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(LaneLineDesign.Colors.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension SavedPlace.PlaceType {
    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .frequent: return "star.fill"
        case .custom: return "mappin.circle.fill"
        }
    }
}

#Preview {
    DestinationSearchView { _ in }
        .serviceContainer(.preview())
        .environment(AppModel(persistence: PersistenceService()))
}
