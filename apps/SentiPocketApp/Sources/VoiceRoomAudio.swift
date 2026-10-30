import AVFoundation
import Foundation
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
    func stop()
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

/// Apple's on-device recognizer, as in push-to-talk, but it leaves the audio session to the voice room and reports
/// partial results. It never falls back to server recognition.
final class OnDeviceVoiceListener: VoiceListening {
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
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
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
    private var synthesizer: AVSpeechSynthesizer?
    private var last: AVSpeechUtterance?
    private var finished: (@MainActor () -> Void)?

    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        stop()
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
        last = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
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
