import AVFoundation
import AudioToolbox

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

    /// Deliberately terse: the climb chip on screen carries the numbers
    /// (grade, distance, length), and every spoken second is a second the
    /// rider's music stays dimmed. The alert chime plays before this.
    static let climbAhead = "Steep climb ahead."

    /// Spoken approach to the destination, fired once when the rider
    /// crosses each threshold so they get an early warning before the
    /// arrival phrase (which fires when `remainingMeters < 10`). Two
    /// thresholds instead of one keeps the guidance useful for both
    /// fast descents into a familiar endpoint (need early heads-up)
    /// and slow climbs approaching a turn (the late heads-up is
    /// enough).
    static func destinationApproach(inMeters: Double) -> String {
        "\(spokenDistance(inMeters)) to your destination."
    }

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
    /// Non-speech cue (climb warning chime). A protocol REQUIREMENT, not
    /// just an extension default — extension methods bind statically on an
    /// `any` existential, so conformers' overrides would never run.
    func playAlertSound()
}

extension RideVoiceGuiding {
    /// Default no-op so lightweight test mocks only implement what they
    /// assert on.
    func playAlertSound() {}
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

    /// Quick mixed-in chime for the climb warning: plays *alongside* music
    /// with no ducking — the ping alone should be enough to notice, and the
    /// terse phrase that follows ducks music only for its ~1 second. If no
    /// music is playing, duckOthers is a no-op and this is just the chime
    /// plus the phrase.
    func playAlertSound() {
        guard !isMuted else { return }
        AudioServicesPlaySystemSound(Self.climbAlertSound)
    }

    /// System "Tink" — subtle and distinct from the turn-guidance voice.
    /// Swap the ID here if a custom tone lands in the asset catalog.
    private static let climbAlertSound: SystemSoundID = 1104

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
