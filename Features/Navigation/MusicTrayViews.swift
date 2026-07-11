import SwiftUI

// MARK: - Compact Bar

/// The always-available music strip on the ride screen. Touch targets are
/// mounted-phone sized; navigation stays visually dominant above it.
struct MusicCompactBar: View {
    let music: any MusicServicing
    let largerControls: Bool
    let onExpand: () -> Void

    private var controlSize: CGFloat {
        largerControls ? LaneLineDesign.HitTarget.large : LaneLineDesign.HitTarget.comfortable
    }

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            if let item = music.nowPlaying {
                artwork(item)

                Button(action: onExpand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(item.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(item.title) by \(item.artist). Expand player.")

                Button {
                    Task { await music.playPause() }
                } label: {
                    Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: controlSize, height: controlSize)
                }
                .accessibilityLabel(item.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await music.skipNext() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(width: controlSize, height: controlSize)
                }
                .accessibilityLabel("Next track")
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                Button(action: onExpand) {
                    Text(promptText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LaneLineDesign.Spacing.medium)
        .padding(.vertical, LaneLineDesign.Spacing.small)
        // One glass surface for the whole strip — controls sit inside it
        // rather than stacking glass on glass.
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
    }

    private var promptText: String {
        switch music.connectionState {
        case .authorizedSubscribed: return "Choose a ride playlist"
        case .authorizedNoSubscription: return "Apple Music subscription required"
        case .denied, .restricted: return "Apple Music access unavailable"
        case .notDetermined: return "Connect Apple Music in Settings"
        }
    }

    @ViewBuilder
    private func artwork(_ item: NowPlayingItem) -> some View {
        if let url = item.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.small))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.small)
            .fill(.quaternary)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "music.note").foregroundStyle(.secondary)
            )
    }
}

// MARK: - Expanded Sheet

/// Bottom-sheet player: full transport controls, progress, and the rider's
/// playlists. Presented over the ride screen; navigation stays visible in
/// the sheet's upper detent.
struct MusicExpandedSheet: View {
    let music: any MusicServicing
    let defaultPlaylistID: String?

    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.large) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, LaneLineDesign.Spacing.small)

            if let item = music.nowPlaying {
                nowPlayingSection(item)
            } else {
                ContentUnavailableView(
                    "Nothing playing",
                    systemImage: "music.note",
                    description: Text("Start a playlist below.")
                )
                .frame(height: 180)
            }

            playlistSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LaneLineDesign.Spacing.large)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .task {
            await music.loadRidePlaylists()
        }
    }

    private func nowPlayingSection(_ item: NowPlayingItem) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.medium) {
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Progress, polled once per second while visible.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = min(music.currentPlaybackTime(), item.durationSeconds)
                VStack(spacing: 4) {
                    ProgressView(
                        value: item.durationSeconds > 0 ? elapsed / item.durationSeconds : 0
                    )
                    HStack {
                        Text(timeString(elapsed))
                        Spacer()
                        Text(item.durationFormatted)
                    }
                    .font(LaneLineDesign.Typography.mono)
                    .foregroundStyle(.secondary)
                }
            }

            RideGlassContainer(spacing: LaneLineDesign.Spacing.xlarge) {
                HStack(spacing: LaneLineDesign.Spacing.xlarge) {
                    Button {
                        Task { await music.skipPrevious() }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .frame(width: LaneLineDesign.HitTarget.large, height: LaneLineDesign.HitTarget.large)
                    }
                    .buttonStyle(.plain)
                    .rideGlass(in: Circle(), interactive: true)
                    .accessibilityLabel("Previous track")

                    Button {
                        Task { await music.playPause() }
                    } label: {
                        Image(systemName: item.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    .accessibilityLabel(item.isPlaying ? "Pause" : "Play")

                    Button {
                        Task { await music.skipNext() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .frame(width: LaneLineDesign.HitTarget.large, height: LaneLineDesign.HitTarget.large)
                    }
                    .buttonStyle(.plain)
                    .rideGlass(in: Circle(), interactive: true)
                    .accessibilityLabel("Next track")
                }
            }
        }
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
            Text("Ride playlists")
                .font(LaneLineDesign.Typography.sectionHeader)

            if music.ridePlaylists.isEmpty {
                Text("Your Apple Music playlists will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LaneLineDesign.Spacing.small) {
                        ForEach(music.ridePlaylists) { playlist in
                            Button {
                                Task { await music.startPlaylist(id: playlist.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    if playlist.id == defaultPlaylistID {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                    }
                                    Text(playlist.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: LaneLineDesign.HitTarget.minimum)
                                .rideGlass(in: Capsule(), interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview("Compact bar") {
    MusicCompactBar(music: MockMusicService(), largerControls: false) {}
        .padding()
}

#Preview("Expanded sheet") {
    MusicExpandedSheet(music: MockMusicService(), defaultPlaylistID: "pl.mock-commute")
}
