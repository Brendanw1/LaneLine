import Foundation

/// One timestamped line, in seconds from track start.
struct LyricLine: Identifiable, Equatable {
    let id: TimeInterval
    let time: TimeInterval
    let text: String

    init(time: TimeInterval, text: String) {
        self.id = time
        self.time = time
        self.text = text
    }
}

struct SongLyrics: Equatable {
    let plainText: String?
    /// Time-synced lines, sorted ascending. Empty when the source only had
    /// plain text, or the track is instrumental.
    let lines: [LyricLine]

    var isSynced: Bool { !lines.isEmpty }
    var isEmpty: Bool { (plainText?.isEmpty ?? true) && lines.isEmpty }

    /// The line that should be highlighted for a given playback position.
    func currentLine(at time: TimeInterval) -> LyricLine? {
        lines.last { $0.time <= time }
    }
}
