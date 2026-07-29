import Foundation

/// Lyrics are not exposed by MusicKit at all — Apple gives third-party apps
/// no lyrics API, synced or plain. This is a fundamentally different problem
/// from "elevation is slow" or "Overpass is unreliable" elsewhere in this
/// service layer: there is no first-party source to fall back to.
///
/// This queries LRCLIB (lrclib.net), a free, keyless, community-sourced
/// lyrics database used by several open-source music apps for exactly this
/// gap. It's not licensed by rights holders and coverage/accuracy varies by
/// track, so a miss here is normal, not an error condition.
protocol LyricsProviding: Sendable {
    func lyrics(
        title: String, artist: String, album: String?, durationSeconds: Double?
    ) async throws -> SongLyrics?
}

struct LRCLibLyricsClient: LyricsProviding {
    var endpoint = URL(string: "https://lrclib.net/api/get")!
    var session: URLSession = .shared

    private struct Response: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    func lyrics(
        title: String, artist: String, album: String?, durationSeconds: Double?
    ) async throws -> SongLyrics? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let durationSeconds, durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(durationSeconds.rounded()))))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("LaneLine/1.2 (iOS bike routing app)", forHTTPHeaderField: "User-Agent")

        // Best-effort: LRCLIB returns 404 for no match, which is an
        // expected, common outcome here, not a failure worth surfacing to
        // the rider or retrying. Any non-200, or a body that doesn't decode,
        // is treated the same way — "no lyrics found."
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }

        if decoded.instrumental == true {
            return SongLyrics(plainText: nil, lines: [])
        }

        let lines = decoded.syncedLyrics.map(Self.parseLRC) ?? []
        return SongLyrics(plainText: decoded.plainLyrics, lines: lines)
    }

    /// Hand-rolled rather than `NSRegularExpression`/regex-literal — LRC
    /// lines are a fixed `[mm:ss.xx]text` shape, and metadata lines like
    /// `[ar:Artist]` fall out naturally since `Double("ar")` fails to parse.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard rawLine.hasPrefix("["), let closeIndex = rawLine.firstIndex(of: "]") else { continue }
            let timestamp = rawLine[rawLine.index(after: rawLine.startIndex)..<closeIndex]
            let parts = timestamp.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1])
            else { continue }

            let lineText = rawLine[rawLine.index(after: closeIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }

            lines.append(LyricLine(time: minutes * 60 + seconds, text: lineText))
        }
        return lines.sorted { $0.time < $1.time }
    }
}

/// Wraps any `LyricsProviding` with an in-memory, session-lifetime cache.
/// Lyrics are supplementary display, not routing-critical, so unlike the
/// elevation cache there's no need for disk persistence — re-fetching once
/// per app launch is fine.
actor CachingLyricsProvider: LyricsProviding {
    private let upstream: any LyricsProviding
    private var cache: [String: SongLyrics] = [:]

    init(upstream: any LyricsProviding = LRCLibLyricsClient()) {
        self.upstream = upstream
    }

    func lyrics(
        title: String, artist: String, album: String?, durationSeconds: Double?
    ) async throws -> SongLyrics? {
        let key = "\(artist.lowercased())|\(title.lowercased())"
        if let cached = cache[key] { return cached }
        guard let result = try await upstream.lyrics(
            title: title, artist: artist, album: album, durationSeconds: durationSeconds
        ) else { return nil }
        cache[key] = result
        return result
    }
}

/// Preview/test stand-in with a couple of fixed results so lyrics UI has
/// something real to render without a network call.
struct MockLyricsProvider: LyricsProviding {
    func lyrics(
        title: String, artist: String, album: String?, durationSeconds: Double?
    ) async throws -> SongLyrics? {
        guard title == "Bicycle Race" else { return nil }
        return SongLyrics(plainText: nil, lines: [
            LyricLine(time: 0, text: "I want to ride my bicycle"),
            LyricLine(time: 3, text: "I want to ride my bike"),
            LyricLine(time: 6, text: "I want to ride my bicycle"),
            LyricLine(time: 9, text: "I want to ride it where I like"),
        ])
    }
}
