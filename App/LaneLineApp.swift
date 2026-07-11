import SwiftUI

@main
struct LaneLineApp: App {
    @State private var services: ServiceContainer
    @State private var appModel: AppModel

    init() {
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
