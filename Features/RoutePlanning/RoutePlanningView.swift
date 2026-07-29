import SwiftUI
import MapKit
import Observation

// MARK: - Planning Model

/// Drives the plan-a-ride flow: pick a destination, run the routing engine,
/// hand candidates to the comparison screen.
@MainActor
@Observable
final class RoutePlanningModel {
    enum Phase: Equatable {
        case idle
        case planning
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var destination: SelectedDestination?
    private(set) var candidates: [RouteCandidate] = []
    var showComparison = false
    /// Rider-set before searching; biases every strategy toward SF's real
    /// "Wiggle" corridor when it's a reasonable way to get there. See
    /// `WiggleCorridor` and `RoutingCostModel`.
    var preferWiggle = false

    /// Fallback origin for simulators/devices without a fix: 16th & Valencia,
    /// the heart of the sample network.
    static let fallbackOrigin = CLLocationCoordinate2D(latitude: 37.76490, longitude: -122.42190)
    private(set) var origin: CLLocationCoordinate2D = RoutePlanningModel.fallbackOrigin

    func plan(
        to destination: SelectedDestination,
        profile: RiderProfile,
        location: (any LocationServicing),
        routing: any RoutingServiceProtocol
    ) async {
        self.destination = destination
        origin = location.currentLocation?.coordinate ?? Self.fallbackOrigin
        phase = .planning

        do {
            candidates = try await routing.generateRoutes(
                from: origin,
                to: destination.coordinate,
                profile: profile,
                strategies: [.balanced, .safer, .faster, .easierClimbing],
                preferWiggle: preferWiggle
            )
            phase = .loaded
            showComparison = true
        } catch {
            candidates = []
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        phase = .idle
        destination = nil
        candidates = []
        showComparison = false
    }
}

// MARK: - Home Map / Planning Screen

struct RoutePlanningView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services

    @State private var model = RoutePlanningModel()
    @State private var showSearch = false
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4270),
        latitudinalMeters: 6000,
        longitudinalMeters: 6000
    ))

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack(alignment: .top) {
                homeMap
                overlayContent
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSearch) {
                DestinationSearchView { destination in
                    Task {
                        await model.plan(
                            to: destination,
                            profile: appModel.riderProfile,
                            location: services.locationService,
                            routing: services.routingService
                        )
                    }
                }
            }
            .navigationDestination(isPresented: $model.showComparison) {
                if let destination = model.destination {
                    RouteComparisonView(
                        candidates: model.candidates,
                        origin: model.origin,
                        destination: destination
                    )
                }
            }
            .task {
                services.locationService.requestAuthorization()
                services.locationService.startUpdating()
            }
        }
    }

    // MARK: Map

    private var homeMap: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(appModel.savedPlaces) { place in
                Marker(
                    place.name,
                    systemImage: place.placeType.systemImage,
                    coordinate: CLLocationCoordinate2D(
                        latitude: place.latitude, longitude: place.longitude
                    )
                )
                .tint(LaneLineDesign.Colors.primary)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Overlay

    private var overlayContent: some View {
        VStack(spacing: LaneLineDesign.Spacing.medium) {
            searchBar
            wiggleToggle

            if case .planning = model.phase {
                planningBanner
            } else if case .failed(let message) = model.phase {
                errorBanner(message)
            }

            Spacer()

            if !appModel.savedPlaces.isEmpty {
                quickPlacesRow
            }
        }
        .padding(LaneLineDesign.Spacing.medium)
    }

    private var searchBar: some View {
        Button {
            showSearch = true
        } label: {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                Text("Where to?")
                    .font(.body)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                Spacer()
                Image(systemName: "bicycle")
                    .foregroundStyle(LaneLineDesign.Colors.primary)
            }
            .padding(LaneLineDesign.Spacing.medium)
            .background(LaneLineDesign.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search for a destination")
    }

    /// Crossing the city east-west usually means climbing somewhere — this
    /// biases every strategy toward the real Wiggle corridor when it's a
    /// reasonable way to do that climbing at its easiest. Self-limiting: it
    /// only changes the winning path when the Wiggle is actually near the
    /// way there, so it's safe to leave on for any trip.
    private var wiggleToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.preferWiggle.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                Text("Prefer the Wiggle")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(
                model.preferWiggle ? LaneLineDesign.Colors.primary : LaneLineDesign.Colors.textSecondary
            )
            .padding(.horizontal, LaneLineDesign.Spacing.medium)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(LaneLineDesign.Colors.surface, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .wiggleGlow(cornerRadius: 100, active: model.preferWiggle)
        .accessibilityLabel("Prefer the Wiggle route")
        .accessibilityValue(model.preferWiggle ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    private var planningBanner: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            ProgressView()
            Text("Scoring routes for your \(appModel.riderProfile.bikeType.displayName)…")
                .font(.subheadline)
                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
        }
        .padding(LaneLineDesign.Spacing.medium)
        .background(LaneLineDesign.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LaneLineDesign.Colors.warning)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LaneLineDesign.Colors.textPrimary)
        }
        .padding(LaneLineDesign.Spacing.medium)
        .background(LaneLineDesign.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private var quickPlacesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LaneLineDesign.Spacing.small) {
                ForEach(appModel.savedPlaces) { place in
                    Button {
                        Task {
                            await model.plan(
                                to: SelectedDestination(
                                    name: place.name,
                                    address: place.address,
                                    coordinate: CLLocationCoordinate2D(
                                        latitude: place.latitude, longitude: place.longitude
                                    )
                                ),
                                profile: appModel.riderProfile,
                                location: services.locationService,
                                routing: services.routingService
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: place.placeType.systemImage)
                                .font(.caption)
                            Text(place.name)
                                .font(LaneLineDesign.Typography.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(LaneLineDesign.Colors.surface)
                        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    }
                }
            }
        }
    }
}

#Preview {
    RoutePlanningView()
        .serviceContainer(.preview())
        .environment(PreviewData.appModel())
}
