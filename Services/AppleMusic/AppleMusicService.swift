import Foundation
import Combine
import CoreGraphics
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
    var isShuffled: Bool { get }
    var repeatMode: MusicRepeatMode { get }
    /// Upcoming tracks, current one first. Sourced live from the player's
    /// queue, not a snapshot — reflects skips/edits immediately.
    var upcomingQueue: [NowPlayingItem] { get }

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
    /// Seeks within the current track — used by the scrubber and by tapping
    /// a lyric line.
    func seek(to time: TimeInterval) async

    func toggleShuffle() async
    /// Cycles off → all → one → off.
    func cycleRepeatMode() async
    /// Jumps playback to an already-queued entry (an "Up Next" tap).
    func playQueueEntry(id: String) async
    func removeFromQueue(id: String) async
    func moveQueueEntries(fromOffsets: IndexSet, toOffset: Int) async
}

/// Mirrors `MusicKit.MusicPlayer.RepeatMode` — kept as our own type so the
/// protocol doesn't leak a MusicKit type into UI code (the mock has no
/// MusicKit dependency at all).
enum MusicRepeatMode: Equatable {
    case off, one, all

    var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }
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
    private(set) var isShuffled = false
    private(set) var repeatMode: MusicRepeatMode = .off
    private(set) var upcomingQueue: [NowPlayingItem] = []

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
            upcomingQueue = []
            isShuffled = false
            repeatMode = .off
            return
        }

        nowPlaying = item(from: entry, isCurrent: true)
        upcomingQueue = player.queue.entries.map { item(from: $0, isCurrent: $0.id == entry.id) }
        isShuffled = player.state.shuffleMode == .songs
        repeatMode = mapped(player.state.repeatMode)
    }

    /// `entry.id` (not the catalog/library item id) is the identity used
    /// throughout — it's unique per queue *position*, which matters once the
    /// same song can appear twice in a queue (a playlist with a repeat, or
    /// repeat-all wrapping around) and the queue view needs to jump to or
    /// remove one specific slot rather than "a" matching song.
    private func item(from entry: MusicKit.MusicPlayer.Queue.Entry, isCurrent: Bool) -> NowPlayingItem {
        var duration: TimeInterval = 0
        var album = ""
        if case .song(let song) = entry.item {
            duration = song.duration ?? 0
            album = song.albumTitle ?? ""
        }
        return NowPlayingItem(
            id: entry.id,
            title: entry.title,
            artist: entry.subtitle ?? "",
            artworkURL: entry.artwork?.url(width: 300, height: 300),
            albumTitle: album,
            durationSeconds: duration,
            isPlaying: isCurrent && player.state.playbackStatus == .playing,
            artworkBackgroundColorHex: Self.hex(from: entry.artwork?.backgroundColor)
        )
    }

    /// `Artwork.backgroundColor` is a real `CGColor` from Apple's catalog
    /// metadata (the same color their own Music app uses for this exact
    /// purpose), not something derived on-device — this just converts it to
    /// a storable hex string.
    private static func hex(from cgColor: CGColor?) -> String? {
        guard let cgColor,
              let converted = cgColor.converted(
                  to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil
              ),
              let components = converted.components,
              components.count >= 3
        else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func mapped(_ mode: MusicKit.MusicPlayer.RepeatMode?) -> MusicRepeatMode {
        // `mode` is `RepeatMode?`, so `case .none` here would match the
        // Optional's nil case, not `RepeatMode.none` — unwrap first so the
        // switch below is over the non-optional enum.
        guard let mode else { return .off }
        switch mode {
        case .none: return .off
        case .one: return .one
        case .all: return .all
        }
    }

    func currentPlaybackTime() -> TimeInterval {
        player.playbackTime
    }

    func seek(to time: TimeInterval) async {
        player.playbackTime = max(0, time)
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

    func toggleShuffle() async {
        player.state.shuffleMode = isShuffled ? .off : .songs
        refreshNowPlaying()
    }

    func cycleRepeatMode() async {
        let next: MusicKit.MusicPlayer.RepeatMode
        switch repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .none
        }
        player.state.repeatMode = next
        refreshNowPlaying()
    }

    // MARK: Queue

    func playQueueEntry(id: String) async {
        guard let entry = player.queue.entries.first(where: { $0.id == id }) else { return }
        player.queue.currentEntry = entry
        do {
            try await player.play()
        } catch {
            lastErrorMessage = "Couldn't play that track."
        }
        refreshNowPlaying()
    }

    func removeFromQueue(id: String) async {
        guard let index = player.queue.entries.firstIndex(where: { $0.id == id }) else { return }
        player.queue.entries.remove(at: index)
        refreshNowPlaying()
    }

    func moveQueueEntries(fromOffsets: IndexSet, toOffset: Int) async {
        var entries = Array(player.queue.entries)
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        player.queue.entries = ApplicationMusicPlayer.Queue.Entries(entries)
        refreshNowPlaying()
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
    private(set) var isShuffled = false
    private(set) var repeatMode: MusicRepeatMode = .off
    private(set) var upcomingQueue: [NowPlayingItem] = []

    /// Mutable "Up Next" order — index 0 is always the current track. Real
    /// enough to preview queue reordering/removal against, unlike a fixed
    /// array cycled through with a modulo index.
    private var orderedQueue: [NowPlayingItem] = [
        NowPlayingItem(
            id: "mock-1", title: "Bicycle Race", artist: "Queen",
            artworkURL: nil, albumTitle: "Jazz", durationSeconds: 181, isPlaying: true,
            artworkBackgroundColorHex: "#C9A23A"
        ),
        NowPlayingItem(
            id: "mock-2", title: "The Passenger", artist: "Iggy Pop",
            artworkURL: nil, albumTitle: "Lust for Life", durationSeconds: 284, isPlaying: true,
            artworkBackgroundColorHex: "#3A6EC9"
        ),
        NowPlayingItem(
            id: "mock-3", title: "Going the Distance", artist: "Cake",
            artworkURL: nil, albumTitle: "Fashion Nugget", durationSeconds: 180, isPlaying: true,
            artworkBackgroundColorHex: "#6A3AC9"
        ),
    ]
    private var trackStartedAt = Date()

    init(connectionState: AppleMusicConnectionState = .authorizedSubscribed) {
        self.connectionState = connectionState
        self.playbackControls = connectionState == .authorizedSubscribed ? .full : .unavailable
        if connectionState == .authorizedSubscribed {
            self.nowPlaying = orderedQueue.first
            self.upcomingQueue = orderedQueue
        }
    }

    func requestAuthorization() async {
        connectionState = .authorizedSubscribed
        playbackControls = .full
        applyCurrent()
    }

    func refreshConnectionState() async {}
    func startObservingPlayback() {}

    func playPause() async {
        guard var item = nowPlaying else { return }
        item.isPlaying.toggle()
        nowPlaying = item
    }

    func skipNext() async {
        guard orderedQueue.count > 1 else { return }
        orderedQueue.append(orderedQueue.removeFirst())
        applyCurrent()
    }

    func skipPrevious() async {
        guard let last = orderedQueue.popLast() else { return }
        orderedQueue.insert(last, at: 0)
        applyCurrent()
    }

    func startPlaylist(id: String) async {
        applyCurrent()
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

    func seek(to time: TimeInterval) async {
        trackStartedAt = Date().addingTimeInterval(-time)
    }

    func toggleShuffle() async {
        isShuffled.toggle()
    }

    func cycleRepeatMode() async {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func playQueueEntry(id: String) async {
        guard let index = orderedQueue.firstIndex(where: { $0.id == id }) else { return }
        orderedQueue.insert(orderedQueue.remove(at: index), at: 0)
        applyCurrent()
    }

    func removeFromQueue(id: String) async {
        let wasCurrent = nowPlaying?.id == id
        orderedQueue.removeAll { $0.id == id }
        if wasCurrent {
            applyCurrent()
        } else {
            upcomingQueue = orderedQueue
        }
    }

    func moveQueueEntries(fromOffsets: IndexSet, toOffset: Int) async {
        orderedQueue.move(fromOffsets: fromOffsets, toOffset: toOffset)
        applyCurrent()
    }

    private func applyCurrent() {
        nowPlaying = orderedQueue.first
        upcomingQueue = orderedQueue
        trackStartedAt = .now
    }
}
