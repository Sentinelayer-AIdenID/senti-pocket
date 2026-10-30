import AVFoundation
import Foundation
import PocketUI
import PocketVoice
import Speech

/// Hearing you in a voice room: speech recognized on the phone, word by word.
@MainActor
protocol VoiceListening: AnyObject {
    /// Starts listening; `partial` gets what has been recognized so far, each time it changes.
    func start(partial: @escaping @MainActor (String) -> Void) async throws
    /// Stops listening and returns what was said ("" when nothing was).
    func stop() async -> String
    func cancel()
}

/// Saying an agent's answer in a voice room, in that agent's own voice.
@MainActor
protocol VoiceSpeaking: AnyObject {
    /// `finished` runs once when the answer has been said, unless `stop()` comes first.
    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void)
    /// The same, and `started` runs once at the answer's first sound (for the call's timings).
    func speak(_ markdown: String, as speaker: String, started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor () -> Void)
    func stop()
}

extension VoiceSpeaking {
    /// A speaker that cannot tell when sound starts reports it at once.
    func speak(_ markdown: String, as speaker: String, started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor () -> Void) {
        started()
        speak(markdown, as: speaker, finished: finished)
    }
}

/// The ring you hear while a call waits for the agent to pick up.
@MainActor
protocol VoiceRoomRinging: AnyObject {
    func startRinging()
    func stopRinging()
}

/// The phone's audio for a voice room: held for the whole call, for listening and speaking in turn, through the
/// speaker (or the headset), with other audio lowered.
@MainActor
protocol VoiceRoomAudioSession: AnyObject {
    func activate() throws
    func deactivate()
}

enum VoiceRoomAudioError: LocalizedError, Equatable {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied: return "Allow Speech Recognition for Senti Pocket in Settings to talk."
        case .microphonePermissionDenied: return "Allow the microphone for Senti Pocket in Settings to talk."
        case .recognizerUnavailable: return "Speech recognition is unavailable right now."
        case .onDeviceRecognitionUnavailable:
            return "This phone can't recognize speech on the device, and audio is never sent to a server."
        case .invalidAudioFormat: return "The microphone did not give usable audio."
        }
    }
}

/// The ring you hear while a call waits: the two-tone ring of a phone line (440 and 480 Hz together, two seconds on
/// and four off), made on the phone and played softly on a loop through the call's audio until the agent picks up.
final class RingbackTone: VoiceRoomRinging {
    private var player: AVAudioPlayer?

    func startRinging() {
        guard player == nil, let player = try? AVAudioPlayer(data: Self.cycle) else { return }
        player.numberOfLoops = -1
        player.volume = 0.35
        player.prepareToPlay()
        player.play()
        self.player = player
    }

    func stopRinging() {
        player?.stop()
        player = nil
    }

    static let sampleRate = 16_000

    /// One ring cycle as a WAV file.
    static let cycle: Data = wav(ringCycle(), sampleRate: sampleRate)

    /// Two seconds of the two tones, faded in and out so they do not click, then four seconds of quiet.
    static func ringCycle() -> [Int16] {
        let on = 2 * sampleRate, fade = sampleRate / 50
        var samples = [Int16](repeating: 0, count: 6 * sampleRate)
        for index in 0..<on {
            let time = Double(index) / Double(sampleRate)
            let edge = min(1, Double(min(index, on - 1 - index)) / Double(fade))
            let tone = (sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)) / 2
            samples[index] = Int16(tone * edge * 0.5 * Double(Int16.max))
        }
        return samples
    }

    /// 16-bit mono PCM samples as a WAV file.
    static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(bytes))
        for sample in samples { put(sample) }
        return data
    }
}

final class PhoneVoiceRoomAudioSession: VoiceRoomAudioSession {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
        try session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// An answered agent's call: CallKit owns the audio session (it activates it after the answer and ends it with the
/// call), so the voice room only sets how it sounds, as a call does (the dial's category, with echo cancellation).
/// This is what lets the call talk with the phone locked.
final class CallKitVoiceRoomAudioSession: VoiceRoomAudioSession {
    func activate() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
                                                        options: [.defaultToSpeaker, .allowBluetooth])
    }

    func deactivate() {}
}

/// Apple's on-device recognizer, as in push-to-talk, but it leaves the audio session to the voice room and reports
/// partial results. It never falls back to server recognition.
final class OnDeviceVoiceListener: VoiceListening {
    /// How loud the microphone is, 0 to 1, about fifty times a second while listening (for the call's waveform).
    var onLevel: (@MainActor @Sendable (Double) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasTap = false
    private var best = ""
    private var isFinal = false

    func start(partial: @escaping @MainActor (String) -> Void) async throws {
        cancel()
        guard await Self.speechAuthorization() == .authorized else { throw VoiceRoomAudioError.speechPermissionDenied }
        guard await Self.microphonePermission() else { throw VoiceRoomAudioError.microphonePermissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw VoiceRoomAudioError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw VoiceRoomAudioError.onDeviceRecognitionUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceRoomAudioError.invalidAudioFormat }
        best = ""
        isFinal = false
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let text, !text.isEmpty, text != self.best {
                    self.best = text
                    partial(text)
                }
                if final { self.isFinal = true }
            }
        }
        let onLevel = self.onLevel
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
            guard let onLevel else { return }
            let level = Self.level(of: buffer)
            Task { @MainActor in onLevel(level) }
        }
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func stop() async -> String {
        guard let request else { return "" }
        stopEngine()
        request.endAudio()
        // A short bounded wait for the recognizer's final words.
        for _ in 0..<12 where !isFinal {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let text = best.trimmingCharacters(in: .whitespacesAndNewlines)
        finish()
        return text
    }

    func cancel() {
        request?.endAudio()
        stopEngine()
        finish()
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
    }

    private func finish() {
        task?.cancel()
        task = nil
        request = nil
    }

    /// The buffer's loudness (its root mean square, in decibels) as 0 to 1.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        return VoiceLevelMeter.level(decibels: 20 * log10(Double(max(rms, 1e-7))))
    }

    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func microphonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

/// The phone's voices, one per agent (see `AgentVoices`), paced like Listen.
final class AgentVoiceSpeaker: NSObject, VoiceSpeaking, AVSpeechSynthesizerDelegate {
    /// Each word as it is said, by its length (for the call's waveform: the synthesizer reports words, not loudness).
    var onWord: (@MainActor (Int) -> Void)?
    private var synthesizer: AVSpeechSynthesizer?
    private var last: AVSpeechUtterance?
    private var finished: (@MainActor () -> Void)?
    private var started: (@MainActor () -> Void)?

    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        speak(markdown, as: speaker, started: {}, finished: finished)
    }

    func speak(_ markdown: String, as speaker: String, started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor () -> Void) {
        stop()
        self.started = started
        let spoken = SpeechText.spoken(fromMarkdown: markdown)
        let segments = SpeechText.segments(spoken)
        guard !segments.isEmpty else {
            finished()
            return
        }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        let voice = AgentVoices.identifier(for: speaker, saying: spoken).flatMap(AVSpeechSynthesisVoice.init(identifier:))
        for segment in segments {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
            utterance.postUtteranceDelay = segment.pauseAfter
            synthesizer.speak(utterance)
            last = utterance
        }
        self.finished = finished
    }

    func stop() {
        finished = nil
        started = nil
        last = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard let started else { return }
            self.started = nil
            started()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard synthesizer === self.synthesizer else { return }
            onWord?(characterRange.length)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated {
            guard utterance === last, let finished else { return }
            self.finished = nil
            last = nil
            finished()
        }
    }
}
