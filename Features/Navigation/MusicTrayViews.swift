import SwiftUI

// MARK: - Compact Bar

/// The always-available music strip on the ride screen. Touch targets are
/// mounted-phone sized; navigation stays visually dominant above it.
struct MusicCompactBar: View {
    let music: any MusicServicing
    let largerControls: Bool
    let onExpand: () -> Void

    /// Smaller than before (was 56/68) and each control now sits in its own
    /// rounded glass circle rather than a bare icon — makes room for the
    /// added shuffle button without the strip growing, and reads as more
    /// deliberately "rounded" per the redesign everywhere music appears.
    private var controlSize: CGFloat {
        largerControls ? LaneLineDesign.HitTarget.comfortable : 44
    }
    private var shuffleSize: CGFloat {
        largerControls ? 40 : 34
    }

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
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
                    Task { await music.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: shuffleSize * 0.42, weight: .semibold))
                        .frame(width: shuffleSize, height: shuffleSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(music.isShuffled ? LaneLineDesign.Colors.primary : LaneLineDesign.Colors.textSecondary)
                .rideGlass(in: Circle(), interactive: true)
                .accessibilityLabel(music.isShuffled ? "Shuffle on" : "Shuffle off")

                Button {
                    Task { await music.playPause() }
                } label: {
                    Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: controlSize * 0.42, weight: .bold))
                        .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LaneLineDesign.Colors.primary)
                .rideGlass(in: Circle(), interactive: true)
                .accessibilityLabel(item.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await music.skipNext() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: controlSize * 0.38, weight: .semibold))
                        .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.plain)
                .rideGlass(in: Circle(), interactive: true)
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
        // rather than stacking glass on glass. The album-color gradient
        // sits behind the glass (same source as the Now Playing screen's
        // background) so the frosted material picks up a tint of it,
        // rather than the bar staying neutral while the sheet above it
        // goes colorful.
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .background {
            NowPlayingBackground(colorHex: music.nowPlaying?.artworkBackgroundColorHex, compact: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
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
            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium)
            .fill(.quaternary)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "music.note").foregroundStyle(.secondary)
            )
    }
}

#Preview("Compact bar") {
    MusicCompactBar(music: MockMusicService(), largerControls: false) {}
        .padding()
}
