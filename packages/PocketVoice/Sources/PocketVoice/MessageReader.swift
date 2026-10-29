import AVFoundation
import Combine
import Foundation
import NaturalLanguage

/// Reads chat messages aloud with the phone's own voices, one at a time, like the web's Listen (sentinelayer-web
/// `ListenButton`): reading another message stops the first.
///
/// It never touches a call: while a call or briefing holds the audio session it does not start, and a call or
/// briefing that starts takes the session back and stops the reading. An interruption (a phone call, Siri, another
/// app taking audio) or unplugged headphones stop it too, rather than moving the voice to the speaker.
@MainActor
public final class MessageReader: ObservableObject {
    public enum Outcome: Equatable, Sendable {
        case started
        /// A call or briefing holds the audio session.
        case unavailable
        /// The message has nothing a voice can say.
        case nothingToSay
    }

    /// Why a reading stops by itself.
    enum Interruption: Equatable, Sendable {
        /// A phone call, Siri or another app took the audio.
        case began
        /// The headphones it was playing through went away.
        case outputDeviceUnavailable
    }

    /// What is being read, by the id given to `read`.
    @Published public private(set) var readingId: String?

    private let engine: any MessageSpeechEngine
    private let sessions: DuplexAudioSessionLeaseManager
    private let voices: () -> [VoiceOption]
    private let phoneLanguageTag: () -> String
    nonisolated(unsafe) private var lease: PlaybackAudioSessionLease?
    /// Tells apart the current reading's completion from an earlier one's.
    private var readingToken = 0
    /// Tells apart the current lease's preemption from an earlier one's.
    private var leaseGeneration = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public convenience init() {
        self.init(
            engine: AVMessageSpeechEngine(),
            sessions: .shared,
            voices: VoiceOption.installed,
            phoneLanguageTag: { Locale.preferredLanguages.first ?? Locale.current.identifier }
        )
        observeAudioSession()
    }

    init(
        engine: any MessageSpeechEngine,
        sessions: DuplexAudioSessionLeaseManager,
        voices: @escaping () -> [VoiceOption],
        phoneLanguageTag: @escaping () -> String
    ) {
        self.engine = engine
        self.sessions = sessions
        self.voices = voices
        self.phoneLanguageTag = phoneLanguageTag
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Never leave the session held (and other audio ducked) by a reader that is gone.
        if let lease { sessions.releasePlayback(lease) }
    }

    /// Reads a message aloud from the start, `markdown` being the text its row shows. Whatever was being read stops,
    /// the same message included (it starts over).
    @discardableResult
    public func read(id: String, markdown: String) -> Outcome {
        let spoken = SpeechText.spoken(fromMarkdown: markdown)
        let segments = SpeechText.segments(spoken)
        guard !segments.isEmpty else { return .nothingToSay }

        if readingId != nil, let lease, sessions.holdsPlayback(lease) {
            // Something is being read: it stops once, and this reading keeps its audio session.
            engine.stop()
        } else {
            stop()
            leaseGeneration += 1
            let generation = leaseGeneration
            do {
                lease = try sessions.acquirePlayback { [weak self] in
                    Task { @MainActor in self?.preempted(generation) }
                }
            } catch {
                return .unavailable
            }
        }
        readingToken += 1
        let token = readingToken
        readingId = id
        let phone = phoneLanguageTag()
        let language = VoicePicker.language(of: spoken, phoneLanguageTag: phone)
        engine.speak(
            segments,
            voiceIdentifier: VoicePicker.voice(for: language, phoneLanguageTag: phone, from: voices()),
            language: language
        ) { [weak self] in
            self?.finished(token)
        }
        return .started
    }

    /// Stops reading, if anything is being read, and gives the audio session back.
    public func stop() {
        guard readingId != nil else { return }
        readingId = nil
        readingToken += 1
        engine.stop()
        if let lease {
            self.lease = nil
            sessions.releasePlayback(lease)
        }
    }

    func handle(_ interruption: Interruption) {
        stop()
    }

    /// A call or briefing took the session from this lease: stop, unless a newer lease is reading by now.
    private func preempted(_ generation: Int) {
        guard generation == leaseGeneration else { return }
        stop()
    }

    private func finished(_ token: Int) {
        guard token == readingToken, readingId != nil else { return }
        readingId = nil
        if let lease {
            self.lease = nil
            sessions.releasePlayback(lease)
        }
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let interruption = Interruption(interruption: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.handle(interruption) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let interruption = Interruption(routeChange: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.handle(interruption) }
        })
        #endif
    }
}

#if os(iOS)
extension MessageReader.Interruption {
    /// An interruption that began; one that ended does not restart the reading.
    init?(interruption userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return nil }
        self = .began
    }

    /// Headphones unplugged (Apple's guidance: stop rather than move to the speaker).
    init?(routeChange userInfo: [AnyHashable: Any]?) {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return nil }
        self = .outputDeviceUnavailable
    }
}
#endif

/// Says paced segments, one after another, with the pause after each.
@MainActor
protocol MessageSpeechEngine: AnyObject {
    /// `finished` runs once, after the last segment, unless `stop()` comes first.
    func speak(
        _ segments: [SpeechText.Segment],
        voiceIdentifier: String?,
        language: String,
        finished: @escaping @MainActor () -> Void
    )
    func stop()
}

/// One installed voice, as much as the choice needs.
struct VoiceOption: Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    /// A BCP 47 tag, for example "en-US".
    let language: String
    let quality: Quality
    /// The voice the system itself picks for this language.
    var isLanguageDefault = false

    static func installed() -> [VoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let defaults = Set(Set(voices.map(\.language)).compactMap { AVSpeechSynthesisVoice(language: $0)?.identifier })
        return voices.compactMap { voice in
            if #available(iOS 17.0, macOS 14.0, *) {
                // Novelty voices (bells, whispers) and someone's Personal Voice are never used to read a message.
                if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) { return nil }
            }
            let quality: Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            return VoiceOption(
                identifier: voice.identifier,
                language: voice.language,
                quality: quality,
                isLanguageDefault: defaults.contains(voice.identifier)
            )
        }
    }
}

/// Which voice reads a message: the message's own language when that is clear, else the phone's, and in that
/// language the best voice installed.
enum VoicePicker {
    /// How sure the language guess must be before it overrides the phone's language.
    static let clearLanguageConfidence = 0.8

    /// A BCP 47 language code ("fr"), from the text when it is clearly one language, else from the phone.
    static func language(of text: String, phoneLanguageTag: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let top = recognizer.languageHypotheses(withMaximum: 1).first,
           top.value >= clearLanguageConfidence, top.key != .undetermined {
            return code(top.key.rawValue)
        }
        return code(phoneLanguageTag)
    }

    /// The best installed voice for `language`: premium, then enhanced, then standard; among equals, the system's own
    /// choice for the language, then the phone's region. Nil when no voice speaks it.
    static func voice(for language: String, phoneLanguageTag: String, from options: [VoiceOption]) -> String? {
        let wanted = code(language)
        let phoneTag = phoneLanguageTag.replacingOccurrences(of: "_", with: "-").lowercased()
        return options
            .filter { code($0.language) == wanted }
            .sorted { lhs, rhs in
                let left = rank(lhs, phoneTag: phoneTag)
                let right = rank(rhs, phoneTag: phoneTag)
                return left != right ? left > right : lhs.identifier < rhs.identifier
            }
            .first?
            .identifier
    }

    private static func rank(_ option: VoiceOption, phoneTag: String) -> (Int, Int, Int) {
        let sameRegion = option.language.replacingOccurrences(of: "_", with: "-").lowercased() == phoneTag
        return (option.quality.rawValue, option.isLanguageDefault ? 1 : 0, sameRegion ? 1 : 0)
    }

    /// "en-US", "en_GB" and "zh-Hans" to "en", "en" and "zh".
    private static func code(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { String($0).lowercased() } ?? tag.lowercased()
    }
}

/// The phone's own speech synthesizer, reading one segment per utterance with the pause after it.
@MainActor
final class AVMessageSpeechEngine: NSObject, MessageSpeechEngine, AVSpeechSynthesizerDelegate {
    /// A hair under the default, like the web's 0.98: calmer and more natural.
    static let rate = AVSpeechUtteranceDefaultSpeechRate * 0.98

    /// A new synthesizer for each reading: speaking right after stopping the same one can lose the new speech.
    private var synthesizer: AVSpeechSynthesizer?
    private var lastUtterance: AVSpeechUtterance?
    private var finished: (@MainActor () -> Void)?

    func speak(
        _ segments: [SpeechText.Segment],
        voiceIdentifier: String?,
        language: String,
        finished: @escaping @MainActor () -> Void
    ) {
        stop()
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        let voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: language)
        for segment in segments {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = Self.rate
            utterance.postUtteranceDelay = segment.pauseAfter
            synthesizer.speak(utterance)
            lastUtterance = utterance
        }
        self.finished = finished
    }

    func stop() {
        finished = nil
        lastUtterance = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard utterance === lastUtterance, let finished else { return }
            self.finished = nil
            lastUtterance = nil
            finished()
        }
    }
}
