import SwiftUI

/// The full player: reached by tapping the compact bar on the ride screen.
/// Presented as a large (not full-screen) sheet — the ride screen stays
/// visible in the margin above, and tapping that margin dismisses back to
/// it, same as tapping-off any other sheet.
///
/// Header content (artwork, scrubber, transport, volume/route) stays fixed;
/// only the selected tab below it scrolls, so switching between lyrics,
/// queue, and playlists doesn't require re-finding the transport controls.
struct MusicNowPlayingView: View {
    let music: any MusicServicing
    let lyrics: any LyricsProviding
    let defaultPlaylistID: String?

    @State private var selectedTab: Tab = .lyrics
    @State private var lyricsState: LyricsLoadState = .idle
    /// Non-nil only while the rider is actively dragging the scrubber —
    /// overrides the live playback time so the thumb doesn't fight their
    /// finger.
    @State private var scrubTime: TimeInterval?

    private enum Tab: String, CaseIterable, Hashable {
        case lyrics = "Lyrics"
        case queue = "Up Next"
        case playlists = "Playlists"
    }

    private enum LyricsLoadState: Equatable {
        case idle, loading, unavailable
        case loaded(SongLyrics)
    }

    /// Derived from the track's own artwork color (real MusicKit metadata),
    /// floored in brightness so it stays legible against the dark backdrop
    /// — see `Color.legibleAccent`.
    private var accentColor: Color {
        .legibleAccent(fromHex: music.nowPlaying?.artworkBackgroundColorHex, fallback: LaneLineDesign.Colors.primary)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = music.nowPlaying {
                header(item)

                Picker("View", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, LaneLineDesign.Spacing.large)
                .padding(.top, LaneLineDesign.Spacing.medium)

                tabContent(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .padding(.top, LaneLineDesign.Spacing.small)
        .background(NowPlayingBackground(colorHex: music.nowPlaying?.artworkBackgroundColorHex))
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await music.loadRidePlaylists()
        }
        .task(id: music.nowPlaying?.id) {
            await loadLyrics()
        }
    }

    // MARK: Header (fixed, non-scrolling)

    private func header(_ item: NowPlayingItem) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.medium) {
            artwork(item, size: 200)
                .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.extraLarge))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(item.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            scrubber(item)
            transportControls(item)
            systemControlsRow
        }
        .padding(.horizontal, LaneLineDesign.Spacing.large)
    }

    private func scrubber(_ item: NowPlayingItem) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let liveElapsed = min(music.currentPlaybackTime(), item.durationSeconds)
            let displayed = scrubTime ?? liveElapsed

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubTime ?? liveElapsed },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(item.durationSeconds, 1),
                    onEditingChanged: { isEditing in
                        guard !isEditing, let scrubTime else { return }
                        Task { await music.seek(to: scrubTime) }
                        self.scrubTime = nil
                    }
                )
                .tint(accentColor)

                HStack {
                    Text(timeString(displayed))
                    Spacer()
                    Text(item.durationFormatted)
                }
                .font(LaneLineDesign.Typography.mono)
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// Smaller and more rounded than the old expanded sheet's controls —
    /// there's now a lot more sharing this header (scrubber, volume,
    /// AirPlay), so transport gives up some size to make room.
    private func transportControls(_ item: NowPlayingItem) -> some View {
        RideGlassContainer(spacing: LaneLineDesign.Spacing.medium) {
            HStack(spacing: LaneLineDesign.Spacing.medium) {
                iconButton("shuffle", size: 38, active: music.isShuffled) {
                    Task { await music.toggleShuffle() }
                }
                .accessibilityLabel(music.isShuffled ? "Shuffle on" : "Shuffle off")

                iconButton("backward.fill", size: 44) {
                    Task { await music.skipPrevious() }
                }
                .accessibilityLabel("Previous track")

                Button {
                    Task { await music.playPause() }
                } label: {
                    Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accentColor)
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .rideGlass(in: Circle(), interactive: true)
                .accessibilityLabel(item.isPlaying ? "Pause" : "Play")

                iconButton("forward.fill", size: 44) {
                    Task { await music.skipNext() }
                }
                .accessibilityLabel("Next track")

                iconButton(music.repeatMode.systemImage, size: 38, active: music.repeatMode != .off) {
                    Task { await music.cycleRepeatMode() }
                }
                .accessibilityLabel(repeatAccessibilityLabel)
            }
        }
    }

    private func iconButton(
        _ systemImage: String, size: CGFloat, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? accentColor : .white.opacity(0.85))
        .rideGlass(in: Circle(), interactive: true)
    }

    private var repeatAccessibilityLabel: String {
        switch music.repeatMode {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one track"
        }
    }

    /// Volume and AirPlay wrap system-rendered controls — there's no public
    /// API to build custom equivalents, so this is as compact and rounded
    /// as Apple allows.
    private var systemControlsRow: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            SystemVolumeSlider(tint: UIColor(accentColor))
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            SystemRoutePickerButton(tint: UIColor(accentColor))
                .frame(width: 28, height: 28)
        }
    }

    // MARK: Tabs (scrolling)

    @ViewBuilder
    private func tabContent(_ item: NowPlayingItem) -> some View {
        switch selectedTab {
        case .lyrics:
            // No outer ScrollView here on purpose: the synced-lyrics branch
            // below owns its own ScrollView so auto-scroll-to-current-line
            // never fights a parent one. The other branches fill the space
            // and don't need scrolling at all.
            lyricsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .queue:
            queueList
        case .playlists:
            ScrollView {
                playlistSection
                    .padding(.horizontal, LaneLineDesign.Spacing.large)
                    .padding(.vertical, LaneLineDesign.Spacing.medium)
            }
        }
    }

    @ViewBuilder
    private var lyricsPanel: some View {
        switch lyricsState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            unavailableLyricsMessage("No lyrics found for this track.")
        case .loaded(let songLyrics):
            if songLyrics.isEmpty {
                unavailableLyricsMessage("Instrumental — no lyrics.")
            } else if songLyrics.isSynced {
                // Ticks every 0.5s so the highlighted line and auto-scroll
                // actually advance during playback — without this, `time`
                // below is only ever recomputed when something else causes
                // a re-render (opening the tab, seeking), so the highlight
                // would appear to freeze the moment playback starts.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    SyncedLyricsView(
                        lines: songLyrics.lines,
                        currentTime: scrubTime ?? music.currentPlaybackTime(),
                        accentColor: accentColor
                    ) { time in
                        Task { await music.seek(to: time) }
                    }
                }
            } else {
                ScrollView {
                    Text(songLyrics.plainText ?? "")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, LaneLineDesign.Spacing.large)
                        .padding(.vertical, LaneLineDesign.Spacing.medium)
                }
            }
        }
    }

    private func unavailableLyricsMessage(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadLyrics() async {
        guard let item = music.nowPlaying else {
            lyricsState = .idle
            return
        }
        lyricsState = .loading
        do {
            if let result = try await lyrics.lyrics(
                title: item.title,
                artist: item.artist,
                album: item.albumTitle.isEmpty ? nil : item.albumTitle,
                durationSeconds: item.durationSeconds > 0 ? item.durationSeconds : nil
            ), !result.isEmpty {
                lyricsState = .loaded(result)
            } else {
                lyricsState = .unavailable
            }
        } catch {
            lyricsState = .unavailable
        }
    }

    // MARK: Queue

    /// Drag handles and swipe-to-delete are always visible (forced edit
    /// mode) rather than hidden behind an "Edit" tap — this list exists
    /// specifically to be edited.
    private var queueList: some View {
        List {
            ForEach(music.upcomingQueue) { entry in
                queueCard(entry)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 5,
                        leading: LaneLineDesign.Spacing.large,
                        bottom: 5,
                        trailing: LaneLineDesign.Spacing.large
                    ))
            }
            .onDelete { offsets in
                let entries = music.upcomingQueue
                Task {
                    for index in offsets {
                        await music.removeFromQueue(id: entries[index].id)
                    }
                }
            }
            .onMove { offsets, destination in
                Task { await music.moveQueueEntries(fromOffsets: offsets, toOffset: destination) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .overlay {
            if music.upcomingQueue.isEmpty {
                Text("Nothing queued.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// Each row is its own rounded glass card (not a plain list row) with
    /// visible spacing between — the queue reads as a stack of cards, not a
    /// table.
    private func queueCard(_ entry: NowPlayingItem) -> some View {
        Button {
            guard entry.id != music.nowPlaying?.id else { return }
            Task { await music.playQueueEntry(id: entry.id) }
        } label: {
            HStack(spacing: LaneLineDesign.Spacing.medium) {
                artwork(entry, size: 44)
                    .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(entry.id == music.nowPlaying?.id ? .bold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                if entry.id == music.nowPlaying?.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, LaneLineDesign.Spacing.medium)
            .padding(.vertical, 10)
            .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large), interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: Playlists

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
            Text("Ride playlists")
                .font(LaneLineDesign.Typography.sectionHeader)

            if music.ridePlaylists.isEmpty {
                Text("Your Apple Music playlists will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(music.ridePlaylists) { playlist in
                    Button {
                        Task { await music.startPlaylist(id: playlist.id) }
                    } label: {
                        HStack(spacing: LaneLineDesign.Spacing.small) {
                            if playlist.id == defaultPlaylistID {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(LaneLineDesign.Colors.primary)
                            }
                            Text(playlist.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: LaneLineDesign.HitTarget.minimum)
                        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: LaneLineDesign.Spacing.large) {
            ContentUnavailableView(
                "Nothing playing",
                systemImage: "music.note",
                description: Text("Start a playlist below.")
            )
            .frame(height: 180)

            ScrollView {
                playlistSection
                    .padding(.horizontal, LaneLineDesign.Spacing.large)
            }
        }
        .padding(.top, LaneLineDesign.Spacing.xlarge)
    }

    // MARK: Shared

    @ViewBuilder
    private func artwork(_ item: NowPlayingItem, size: CGFloat) -> some View {
        if let url = item.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                artworkPlaceholder(size: size)
            }
            .frame(width: size, height: size)
        } else {
            artworkPlaceholder(size: size)
        }
    }

    private func artworkPlaceholder(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.small)
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.secondary)
            )
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Synced lyrics

/// Own `ScrollView`/`ScrollViewReader` so scrolling the lyric list never
/// moves the header controls above it.
private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let currentTime: TimeInterval
    let accentColor: Color
    let onTapLine: (TimeInterval) -> Void

    private var currentID: TimeInterval? {
        lines.last { $0.time <= currentTime }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.medium) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(line.id == currentID ? .title3.weight(.bold) : .body)
                            .foregroundStyle(
                                line.id == currentID
                                    ? accentColor
                                    : .white.opacity(0.55)
                            )
                            .id(line.id)
                            .onTapGesture { onTapLine(line.time) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LaneLineDesign.Spacing.large)
                .padding(.vertical, LaneLineDesign.Spacing.medium)
            }
            .onChange(of: currentID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Turn island

#Preview {
    MusicNowPlayingView(music: MockMusicService(), lyrics: MockLyricsProvider(), defaultPlaylistID: "pl.mock-commute")
}
