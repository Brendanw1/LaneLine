import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services

    @State private var networkSourceLabel = ""
    @State private var isIngesting = false
    @State private var ingestionError: String?

    var body: some View {
        NavigationStack {
            Form {
                riderProfileSection
                appleMusicSection
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
                MusicConnectionStatusView(state: music.connectionState)
            }

            if music.connectionState == .notDetermined {
                Button("Connect Apple Music") {
                    Task { await music.requestAuthorization() }
                }
            } else if music.connectionState == .denied {
                Text("Enable access in iOS Settings → Privacy → Media & Apple Music.")
                    .font(.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
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
                Text("1.0.0 (Alpha)")
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
