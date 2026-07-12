import AVFoundation

// MARK: - Phrases

/// Pure phrase construction for spoken guidance — separated from synthesis
/// so announcement wording and trigger logic stay unit-testable.
enum RideAnnouncements {
    static func rideStart(street: String?, totalMeters: Double) -> String {
        let distance = spokenDistance(totalMeters)
        if let street {
            return "Starting ride on \(street). \(distance) to your destination."
        }
        return "Starting ride. \(distance) to your destination."
    }

    static func approach(turn: TurnType, street: String?, inMeters: Double) -> String {
        "In \(spokenDistance(inMeters)), \(turnPhrase(turn, street: street))."
    }

    static func imminent(turn: TurnType, street: String?) -> String {
        "\(turnPhrase(turn, street: street).prefix(1).uppercased() + turnPhrase(turn, street: street).dropFirst())."
    }

    static let offRoute = "Off route. Recalculating."
    static let rerouted = "Route updated."
    static let arrival = "You have arrived at your destination."

    private static func turnPhrase(_ turn: TurnType, street: String?) -> String {
        let action: String
        switch turn {
        case .straight, .unknown: action = "continue"
        case .slightLeft: action = "bear left"
        case .slightRight: action = "bear right"
        case .left: action = "turn left"
        case .right: action = "turn right"
        case .sharpLeft: action = "make a sharp left"
        case .sharpRight: action = "make a sharp right"
        case .uTurn: action = "make a U-turn"
        }
        if let street {
            return "\(action) onto \(street)"
        }
        return action
    }

    /// "300 meters" below a kilometer (rounded to 50 m), "1.2 kilometers" above.
    static func spokenDistance(_ meters: Double) -> String {
        if meters < 950 {
            let rounded = max(50, Int((meters / 50).rounded()) * 50)
            return "\(rounded) meters"
        }
        let km = meters / 1000
        let formatted = km < 10
            ? String(format: "%.1f", km).replacingOccurrences(of: ".0", with: "")
            : String(Int(km.rounded()))
        return formatted == "1" ? "1 kilometer" : "\(formatted) kilometers"
    }
}

// MARK: - Synthesis

/// Speech output contract; tests substitute a recorder.
@MainActor
protocol RideVoiceGuiding: AnyObject {
    var isMuted: Bool { get set }
    func announce(_ phrase: String)
    func stopSpeaking()
}

/// Speaks guidance over the rider's music: the audio session ducks other
/// audio (including Apple Music) for the duration of each utterance and
/// releases it afterwards so the music swells back — navigation is always
/// audible, music never overpowers it.
@MainActor
final class RideVoiceGuide: NSObject, RideVoiceGuiding, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    var isMuted = false {
        didSet { if isMuted { stopSpeaking() } }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func announce(_ phrase: String) {
        guard !isMuted else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .voicePrompt,
            options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
        )
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.releaseAudioSession() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.releaseAudioSession() }
    }
}
