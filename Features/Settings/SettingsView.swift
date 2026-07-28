import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services
    @Environment(\.openURL) private var openURL

    @State private var networkSourceLabel = ""
    @State private var isIngesting = false
    @State private var ingestionError: String?

    var body: some View {
        NavigationStack {
            Form {
                riderProfileSection
                appleMusicSection
                healthKitSection
                rideScreenSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task { await refreshNetworkSource() }
        }
    }

    // MARK: Rider profile

    private var riderProfileSection: some View {
        Section {
            Picker("Bike type", selection: profileBinding(\.bikeType)) {
                ForEach(BikeType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Hill tolerance", selection: profileBinding(\.hillTolerance)) {
                ForEach(HillTolerance.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Safety priority", selection: profileBinding(\.safetyPreference)) {
                ForEach(SafetyPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Directness", selection: profileBinding(\.directnessPreference)) {
                ForEach(DirectnessPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Surface pickiness", selection: profileBinding(\.surfaceSensitivity)) {
                ForEach(SurfaceSensitivity.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Stepper(value: weightLbsBinding, in: 88...330, step: 1) {
                HStack {
                    Text("Weight")
                    Spacer()
                    Text("\(Int(weightLbsBinding.wrappedValue)) lb")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Rider profile")
        } footer: {
            Text("Changing these reshapes route scoring immediately — the next plan reflects them.")
        }
    }

    // MARK: Apple Music

    private var appleMusicSection: some View {
        let music = services.musicService

        return Section {
            Toggle("Music controls on ride screen", isOn: profileBinding(\.appleMusicEnabled))

            HStack {
                Text("Status")
                Spacer()
                MusicConnectionStatusView(state: music.connectionState, errorMessage: music.lastErrorMessage)
            }

            if music.connectionState == .notDetermined {
                Button("Connect Apple Music") {
                    Task { await music.requestAuthorization() }
                }
            } else if music.connectionState == .denied {
                Text("Enable access in iOS Settings → Privacy → Media & Apple Music.")
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            } else if music.connectionState == .authorizedNoSubscription {
                Button("Check Apple Music status again") {
                    Task { await music.refreshConnectionState() }
                }
            }

            if !music.ridePlaylists.isEmpty || appModel.riderProfile.defaultRidePlaylistID != nil {
                Picker("Default ride playlist", selection: playlistBinding) {
                    Text("None").tag(String?.none)
                    ForEach(music.ridePlaylists) { playlist in
                        Text(playlist.name).tag(String?.some(playlist.id))
                    }
                }
            }

            Button("Refresh playlists") {
                Task { await music.loadRidePlaylists() }
            }
        } header: {
            Text("Apple Music")
        }
    }

    // MARK: Apple Health

    private var healthKitSection: some View {
        let health = services.healthKitService

        return Section {
            Toggle("Log rides to Apple Health", isOn: healthKitToggleBinding)

            HStack {
                Text("Status")
                Spacer()
                Text(healthStatusLabel(health.authorizationState))
                    .foregroundStyle(.secondary)
            }

            if let error = health.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.danger)
            }

            if health.authorizationState == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("Saves distance, duration, calories, and route as a cycling workout each time you save a ride. Write-only — LaneLine never reads your Health data.")
        }
    }

    private func healthStatusLabel(_ state: HealthKitAuthorizationState) -> String {
        switch state {
        case .authorized: return "Connected"
        case .denied: return "Access denied"
        case .notDetermined: return "Not connected"
        }
    }

    /// Requests HealthKit authorization the first time this is turned on;
    /// the toggle otherwise just reflects the rider's preference.
    private var healthKitToggleBinding: Binding<Bool> {
        Binding(
            get: { appModel.riderProfile.healthKitEnabled },
            set: { newValue in
                var profile = appModel.riderProfile
                profile.healthKitEnabled = newValue
                appModel.updateProfile(profile)
                if newValue, services.healthKitService.authorizationState == .notDetermined {
                    Task { await services.healthKitService.requestAuthorization() }
                }
            }
        )
    }

    // MARK: Ride screen

    private var rideScreenSection: some View {
        Section {
            NavigationLink("Ride screen layout") {
                RideCustomizationView()
            }
        } header: {
            Text("Ride screen")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            HStack {
                Text("Network source")
                Spacer()
                Text(networkSourceLabel)
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    .multilineTextAlignment(.trailing)
            }

            Button {
                Task { await ingestLiveData() }
            } label: {
                if isIngesting {
                    HStack {
                        ProgressView()
                        Text("Fetching SF bike network…")
                    }
                } else {
                    Text("Fetch live SF bike network")
                }
            }
            .disabled(isIngesting)

            if let ingestionError {
                Text(ingestionError)
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.danger)
            }
        } header: {
            Text("Routing data")
        } footer: {
            Text("Live ingestion pulls the SFMTA bikeway network (DataSF), street attributes (OpenStreetMap), and elevation (USGS), then rebuilds the routing graph on-device.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersionLabel)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            }
            HStack {
                Text("Coverage")
                Spacer()
                Text("San Francisco")
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            }
        }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: Helpers

    /// Two-way binding into the profile that persists on every change.
    private func profileBinding<Value>(
        _ keyPath: WritableKeyPath<RiderProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appModel.riderProfile[keyPath: keyPath] },
            set: { newValue in
                var profile = appModel.riderProfile
                profile[keyPath: keyPath] = newValue
                appModel.updateProfile(profile)
            }
        )
    }

    private var playlistBinding: Binding<String?> {
        profileBinding(\.defaultRidePlaylistID)
    }

    /// `RiderProfile.weightKg` stays in kilograms — the power/calorie model
    /// is SI-based — this only converts at the display boundary.
    private var weightLbsBinding: Binding<Double> {
        Binding(
            get: { (appModel.riderProfile.weightKg * 2.20462).rounded() },
            set: { newValue in
                var profile = appModel.riderProfile
                profile.weightKg = newValue / 2.20462
                appModel.updateProfile(profile)
            }
        )
    }

    private func refreshNetworkSource() async {
        networkSourceLabel = await services.geospatialService.currentSource.displayName
    }

    private func ingestLiveData() async {
        isIngesting = true
        ingestionError = nil
        do {
            _ = try await services.geospatialService.ingestLiveNetwork(in: .sanFrancisco)
        } catch {
            ingestionError = error.localizedDescription
        }
        await refreshNetworkSource()
        isIngesting = false
    }
}

#Preview {
    SettingsView()
        .serviceContainer(.preview())
        .environment(PreviewData.appModel())
}
