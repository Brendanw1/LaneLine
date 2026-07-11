import Foundation

// MARK: - Apple Music Models

enum AppleMusicConnectionState: String, Codable {
    case notDetermined
    case denied
    case authorizedNoSubscription
    case authorizedSubscribed
    case restricted
}

struct NowPlayingItem: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var albumTitle: String
    var durationSeconds: Double
    var isPlaying: Bool

    var durationFormatted: String {
        let totalSeconds = Int(durationSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// A playlist the rider can start from the ride screen — either from their
/// library or the catalog.
struct RidePlaylist: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var curatorName: String?
    var artworkURL: URL?
}

struct PlaybackControlsState: Codable, Equatable {
    var canPlayPause: Bool
    var canSkipNext: Bool
    var canSkipPrevious: Bool
    var queueAvailable: Bool
    var volumeAvailable: Bool

    static let unavailable = PlaybackControlsState(
        canPlayPause: false,
        canSkipNext: false,
        canSkipPrevious: false,
        queueAvailable: false,
        volumeAvailable: false
    )

    static let full = PlaybackControlsState(
        canPlayPause: true,
        canSkipNext: true,
        canSkipPrevious: true,
        queueAvailable: true,
        volumeAvailable: true
    )
}
