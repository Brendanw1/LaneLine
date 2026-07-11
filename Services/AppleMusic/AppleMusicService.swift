import Foundation
import Combine
import MusicKit
import Observation

// MARK: - Music Service Protocol

/// Apple Music integration surface. UI code depends only on this protocol so
/// previews and the simulator (which has no Apple Music account) can run on
/// `MockMusicService` while devices use the real MusicKit-backed service.
@MainActor
protocol MusicServicing: AnyObject, Observable {
    var connectionState: AppleMusicConnectionState { get }
    var nowPlaying: NowPlayingItem? { get }
    var playbackControls: PlaybackControlsState { get }
    var ridePlaylists: [RidePlaylist] { get }
    var lastErrorMessage: String? { get }

    /// Prompt for MusicKit authorization, then resolve subscription state.
    func requestAuthorization() async
    /// Re-check subscription without prompting.
    func refreshConnectionState() async
    /// Begin mirroring player state into `nowPlaying`. Idempotent.
    func startObservingPlayback()

    func playPause() async
    func skipNext() async
    func skipPrevious() async
    func startPlaylist(id: String) async
    /// Load the rider's library playlists for the ride-playlist shortcut.
    func loadRidePlaylists() async
    /// Current position in the playing track; polled by the expanded player.
    func currentPlaybackTime() -> TimeInterval
}

// MARK: - Live MusicKit Implementation

@MainActor
@Observable
final class AppleMusicService: MusicServicing {
    private(set) var connectionState: AppleMusicConnectionState = .notDetermined
    private(set) var nowPlaying: NowPlayingItem?
    private(set) var playbackControls: PlaybackControlsState = .unavailable
    private(set) var ridePlaylists: [RidePlaylist] = []
    private(set) var lastErrorMessage: String?

    private let player = ApplicationMusicPlayer.shared
    private var cancellables: Set<AnyCancellable> = []
    private var subscriptionTask: Task<Void, Never>?

    // MARK: Authorization & subscription

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            await refreshConnectionState()
        case .denied:
            connectionState = .denied
        case .restricted:
            connectionState = .restricted
        case .notDetermined:
            connectionState = .notDetermined
        @unknown default:
            connectionState = .notDetermined
        }
    }

    func refreshConnectionState() async {
        guard MusicAuthorization.currentStatus == .authorized else {
            connectionState = mapped(MusicAuthorization.currentStatus)
            playbackControls = .unavailable
            return
        }
        do {
            let subscription = try await MusicSubscription.current
            apply(subscription)
        } catch {
            lastErrorMessage = "Couldn't check your Apple Music subscription."
            connectionState = .authorizedNoSubscription
            playbackControls = .unavailable
        }
    }

    private func apply(_ subscription: MusicSubscription) {
        connectionState = subscription.canPlayCatalogContent
            ? .authorizedSubscribed
            : .authorizedNoSubscription
        playbackControls = subscription.canPlayCatalogContent ? .full : .unavailable
    }

    private func mapped(_ status: MusicAuthorization.Status) -> AppleMusicConnectionState {
        switch status {
        case .authorized: return .authorizedSubscribed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: Playback observation

    /// Mirrors `ApplicationMusicPlayer` state and queue changes into
    /// observable properties, and tracks subscription changes for the life
    /// of the app (family plan lapses, new sign-ins, etc.).
    func startObservingPlayback() {
        guard cancellables.isEmpty else { return }

        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNowPlaying() }
            .store(in: &cancellables)

        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNowPlaying() }
            .store(in: &cancellables)

        subscriptionTask = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                self?.apply(subscription)
            }
        }

        refreshNowPlaying()
    }

    private func refreshNowPlaying() {
        guard let entry = player.queue.currentEntry else {
            nowPlaying = nil
            return
        }

        var duration: TimeInterval = 0
        var itemID = entry.id
        if case .song(let song) = entry.item {
            duration = song.duration ?? 0
            itemID = song.id.rawValue
        }

        nowPlaying = NowPlayingItem(
            id: itemID,
            title: entry.title,
            artist: entry.subtitle ?? "",
            artworkURL: entry.artwork?.url(width: 300, height: 300),
            albumTitle: "",
            durationSeconds: duration,
            isPlaying: player.state.playbackStatus == .playing
        )
    }

    func currentPlaybackTime() -> TimeInterval {
        player.playbackTime
    }

    // MARK: Playback control

    func playPause() async {
        do {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                try await player.play()
            }
        } catch {
            lastErrorMessage = "Playback isn't available right now."
        }
        refreshNowPlaying()
    }

    func skipNext() async {
        do {
            try await player.skipToNextEntry()
        } catch {
            lastErrorMessage = "Couldn't skip to the next track."
        }
    }

    func skipPrevious() async {
        do {
            try await player.skipToPreviousEntry()
        } catch {
            lastErrorMessage = "Couldn't go back a track."
        }
    }

    // MARK: Playlists

    func startPlaylist(id: String) async {
        do {
            let playlist = try await resolvePlaylist(id: id)
            player.queue = [playlist]
            try await player.play()
            refreshNowPlaying()
        } catch {
            lastErrorMessage = "Couldn't start that playlist."
        }
    }

    private func resolvePlaylist(id: String) async throws -> Playlist {
        // Library first (ride playlists are usually the rider's own), then
        // the catalog for shared/curated playlist IDs.
        var libraryRequest = MusicLibraryRequest<Playlist>()
        libraryRequest.filter(matching: \.id, equalTo: MusicItemID(id))
        if let match = try await libraryRequest.response().items.first {
            return match
        }

        let catalogRequest = MusicCatalogResourceRequest<Playlist>(
            matching: \.id, equalTo: MusicItemID(id)
        )
        guard let playlist = try await catalogRequest.response().items.first else {
            throw MusicError.unknown
        }
        return playlist
    }

    func loadRidePlaylists() async {
        guard connectionState == .authorizedSubscribed
            || connectionState == .authorizedNoSubscription else { return }
        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 25
            let response = try await request.response()
            ridePlaylists = response.items.map { playlist in
                RidePlaylist(
                    id: playlist.id.rawValue,
                    name: playlist.name,
                    curatorName: playlist.curatorName,
                    artworkURL: playlist.artwork?.url(width: 120, height: 120)
                )
            }
        } catch {
            lastErrorMessage = "Couldn't load your playlists."
        }
    }

    private enum MusicError: Error { case unknown }
}

// MARK: - Preview / Simulator Mock

/// Deterministic stand-in used by previews, the simulator, and UI tests.
/// Exercises the exact same protocol surface as the live service.
@MainActor
@Observable
final class MockMusicService: MusicServicing {
    private(set) var connectionState: AppleMusicConnectionState
    private(set) var nowPlaying: NowPlayingItem?
    private(set) var playbackControls: PlaybackControlsState
    private(set) var ridePlaylists: [RidePlaylist] = []
    private(set) var lastErrorMessage: String?

    private let queue: [NowPlayingItem] = [
        NowPlayingItem(
            id: "mock-1", title: "Bicycle Race", artist: "Queen",
            artworkURL: nil, albumTitle: "Jazz", durationSeconds: 181, isPlaying: true
        ),
        NowPlayingItem(
            id: "mock-2", title: "The Passenger", artist: "Iggy Pop",
            artworkURL: nil, albumTitle: "Lust for Life", durationSeconds: 284, isPlaying: true
        ),
        NowPlayingItem(
            id: "mock-3", title: "Going the Distance", artist: "Cake",
            artworkURL: nil, albumTitle: "Fashion Nugget", durationSeconds: 180, isPlaying: true
        ),
    ]
    private var queueIndex = 0
    private var trackStartedAt = Date()

    init(connectionState: AppleMusicConnectionState = .authorizedSubscribed) {
        self.connectionState = connectionState
        self.playbackControls = connectionState == .authorizedSubscribed ? .full : .unavailable
        if connectionState == .authorizedSubscribed {
            self.nowPlaying = queue[0]
        }
    }

    func requestAuthorization() async {
        connectionState = .authorizedSubscribed
        playbackControls = .full
        nowPlaying = queue[queueIndex]
    }

    func refreshConnectionState() async {}
    func startObservingPlayback() {}

    func playPause() async {
        guard var item = nowPlaying else { return }
        item.isPlaying.toggle()
        nowPlaying = item
    }

    func skipNext() async {
        queueIndex = (queueIndex + 1) % queue.count
        nowPlaying = queue[queueIndex]
        trackStartedAt = .now
    }

    func skipPrevious() async {
        queueIndex = (queueIndex + queue.count - 1) % queue.count
        nowPlaying = queue[queueIndex]
        trackStartedAt = .now
    }

    func startPlaylist(id: String) async {
        queueIndex = 0
        nowPlaying = queue[0]
        trackStartedAt = .now
    }

    func loadRidePlaylists() async {
        ridePlaylists = [
            RidePlaylist(id: "pl.mock-commute", name: "Morning Commute", curatorName: nil, artworkURL: nil),
            RidePlaylist(id: "pl.mock-climb", name: "Climb Songs", curatorName: nil, artworkURL: nil),
        ]
    }

    func currentPlaybackTime() -> TimeInterval {
        guard let item = nowPlaying, item.isPlaying else { return 0 }
        return Date().timeIntervalSince(trackStartedAt)
            .truncatingRemainder(dividingBy: max(1, item.durationSeconds))
    }
}
