import SwiftUI

@main
struct LaneLineApp: App {
    @State private var services: ServiceContainer
    @State private var appModel: AppModel

    init() {
        #if DEBUG
        // `simctl launch booted com.laneline.LaneLine -demoRide` drops
        // straight into an active ride over the sample network with mocked
        // location and music — for screenshots and ride-screen iteration.
        if ProcessInfo.processInfo.arguments.contains("-demoRide") {
            // Fix-less location mock: the ride advances via simulation, so
            // the demo moves along the route and voice guidance fires.
            let container = ServiceContainer(
                locationService: MockLocationService(coordinate: nil),
                musicService: MockMusicService()
            )
            let model = AppModel(persistence: container.persistenceService)
            model.riderProfile = PreviewData.riderProfile
            model.onboardingComplete = true
            model.isLoaded = true
            model.activeRoute = PreviewData.sampleCandidates[0]
            _services = State(initialValue: container)
            _appModel = State(initialValue: model)
            return
        }
        #endif
        let container = ServiceContainer.live()
        _services = State(initialValue: container)
        _appModel = State(initialValue: AppModel(persistence: container.persistenceService))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .serviceContainer(services)
                .environment(appModel)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(\.services) private var services
    @Environment(AppModel.self) private var appModel

    /// Rides shown at ride end are complete regardless of checkpoint state.
    private func completed(_ record: RideRecord) -> RideRecord {
        var record = record
        record.summary.isComplete = true
        return record
    }

    var body: some View {
        @Bindable var appModel = appModel

        Group {
            if !appModel.isLoaded {
                ProgressView()
            } else if !appModel.onboardingComplete {
                OnboardingFlowView()
            } else {
                MainTabView()
            }
        }
        .fullScreenCover(item: $appModel.activeRoute) { route in
            ActiveNavigationView(route: route)
        }
        .fullScreenCover(item: $appModel.pendingRideRecord) { record in
            RideSummaryView(
                record: completed(record),
                onSave: {
                    let final = completed(record)
                    appModel.pendingRideRecord = nil
                    Task {
                        do { try await services.rideStore.save(final) }
                        catch { appModel.failedRideSave = final }
                    }
                },
                onDiscard: {
                    Task { await services.rideStore.delete(id: record.id) }
                    appModel.pendingRideRecord = nil
                }
            )
        }
        .alert(
            "Couldn't save your ride",
            isPresented: Binding(
                get: { appModel.failedRideSave != nil },
                set: { if !$0 { appModel.failedRideSave = nil } }
            )
        ) {
            Button("Try again") {
                guard let record = appModel.failedRideSave else { return }
                appModel.failedRideSave = nil
                Task {
                    do { try await services.rideStore.save(record) }
                    catch { appModel.failedRideSave = record }
                }
            }
            Button("Discard", role: .cancel) { appModel.failedRideSave = nil }
        } message: {
            Text("The ride couldn't be written to storage. It is still in memory — try again, or discard it.")
        }
        .task {
            await appModel.load()
            services.musicService.startObservingPlayback()
            await services.musicService.refreshConnectionState()
        }
    }
}

// MARK: - Tabs

struct MainTabView: View {
    var body: some View {
        TabView {
            RoutePlanningView()
                .tabItem { Label("Ride", systemImage: "bicycle") }

            SavedPlacesView()
                .tabItem { Label("Places", systemImage: "bookmark") }

            RideHistoryView()
                .tabItem { Label("Rides", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootView()
        .serviceContainer(.preview())
        .environment(previewAppModel())
}

@MainActor
private func previewAppModel() -> AppModel {
    let model = AppModel(persistence: PersistenceService())
    model.riderProfile = PreviewData.riderProfile
    model.savedPlaces = PreviewData.savedPlaces
    model.onboardingComplete = true
    model.isLoaded = true
    return model
}
