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
    /// Runs once when the microphone gives up on the turn being heard (the phone's sound kept changing, or could not be
    /// set up again): nothing more will be heard in this turn.
    var onMicrophoneLost: (@MainActor () -> Void)? { get set }
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

/// The phone's own call (CallKit) a voice room talks inside, when it answers an agent's call. Its call screen has a
/// Mute of its own, so the panel's Mute is asked of it, and its answer mutes the voice room the way a tap there does:
/// one mute, the same on both screens.
@MainActor
protocol VoiceRoomCallScreen: AnyObject {
    /// Mutes or unmutes the call as if on its screen; `done(false)` when the call screen could not.
    func setMuted(_ on: Bool, done: @escaping @MainActor (Bool) -> Void)
}

/// The phone's audio for a voice room: held for the whole call, for listening and speaking in turn, through the
/// speaker (or the headset), with other audio lowered.
@MainActor
protocol VoiceRoomAudioSession: AnyObject {
    func activate() throws
    func deactivate()
    /// Whether the call plays through the phone's loudspeaker now (not the earpiece, a headset or a car).
    var isSpeakerOn: Bool { get }
    /// The loudspeaker (true) or the earpiece, for the rest of the call.
    func setSpeaker(_ on: Bool) throws
    /// Runs `changed` each time the call's sound moves (a headset plugged in or out, the speaker chosen), until
    /// `deactivate`.
    func watchRoute(_ changed: @escaping @MainActor () -> Void)
}

/// The loudspeaker or the earpiece for a voice room (Carter, 11-05: a call picked up on the speaker by accident had no
/// way back). The choice is the category's own default route, not a one-off override, so it holds for the whole call:
/// through every turn's listening and every route change that is not a new headset. It is the call's only: when the
/// call ends the phone's audio is put back on the speaker, so what plays next (a room video sets no audio of its own)
/// is not left on the earpiece.
final class VoiceRoomSpeakerRoute {
    private let mode: AVAudioSession.Mode
    private let options: AVAudioSession.CategoryOptions
    /// The loudspeaker is chosen (calls start on it, as they always have).
    private(set) var speaker = true
    private var watch: NSObjectProtocol?

    init(mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
        self.mode = mode
        self.options = options
    }

    /// The call's category options: the base options, with the loudspeaker as the default route or without it.
    static func options(speaker: Bool, base: AVAudioSession.CategoryOptions) -> AVAudioSession.CategoryOptions {
        speaker ? base.union(.defaultToSpeaker) : base.subtracting(.defaultToSpeaker)
    }

    /// Sets the call's category, on the route chosen.
    func applyCategory() throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: mode,
                                                        options: Self.options(speaker: speaker, base: options))
    }

    /// Chooses the loudspeaker or the earpiece now, and for the rest of the call.
    func setSpeaker(_ on: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: mode, options: Self.options(speaker: on, base: options))
        try session.overrideOutputAudioPort(on ? .speaker : .none)
        speaker = on
    }

    var isSpeakerOn: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    func watch(_ changed: @escaping @MainActor () -> Void) {
        stopWatching()
        watch = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                       queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    func stopWatching() {
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    /// The call ended: the phone's audio goes back to its default, the speaker, whatever the call chose.
    func restore() {
        stopWatching()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: mode, options: Self.options(speaker: true, base: options))
        try? session.overrideOutputAudioPort(.none)
        speaker = true
    }
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
    private let route = VoiceRoomSpeakerRoute(mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])

    func activate() throws {
        try route.applyCategory()
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivate() {
        route.restore()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var isSpeakerOn: Bool { route.isSpeakerOn }

    func setSpeaker(_ on: Bool) throws { try route.setSpeaker(on) }

    func watchRoute(_ changed: @escaping @MainActor () -> Void) { route.watch(changed) }
}

/// An answered agent's call: CallKit owns the audio session (it activates it after the answer and ends it with the
/// call), so the voice room only sets how it sounds, as a call does (the dial's category, with echo cancellation).
/// This is what lets the call talk with the phone locked.
final class CallKitVoiceRoomAudioSession: VoiceRoomAudioSession {
    private let route = VoiceRoomSpeakerRoute(mode: .voiceChat, options: [.allowBluetooth])

    func activate() throws {
        try route.applyCategory()
    }

    func deactivate() {
        route.restore()
    }

    var isSpeakerOn: Bool { route.isSpeakerOn }

    func setSpeaker(_ on: Bool) throws { try route.setSpeaker(on) }

    func watchRoute(_ changed: @escaping @MainActor () -> Void) { route.watch(changed) }
}

/// The microphone's audio engine as the listener uses it: `AVAudioEngine`, or a fake in tests.
protocol VoiceInputEngine: AnyObject {
    var isRunning: Bool { get }
    /// The microphone's format now. It changes with the route (the speaker, the earpiece, a headset).
    var inputFormat: AVAudioFormat { get }
    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock)
    func removeInputTap()
    func prepare()
    func start() throws
    func stop()
}

extension AVAudioEngine: VoiceInputEngine {
    var inputFormat: AVAudioFormat { inputNode.outputFormat(forBus: 0) }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func removeInputTap() {
        inputNode.removeTap(onBus: 0)
    }
}

/// The microphone feeding a turn's recognition. The audio engine stops when the phone's audio is set up again (the
/// Speaker button, a headset plugged in or out): while a turn is being heard, the tap goes back on in the new format
/// and the engine starts again, so the turn goes on and what is said after the change is heard. It used to stop for
/// good, and listening went quiet.
final class MicrophoneTap {
    private let engine: any VoiceInputEngine
    /// Runs on the audio thread, for each buffer the microphone hears.
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var tapped = false
    private var watches: [NSObjectProtocol] = []
    /// How many times the engine was started again after a change.
    private(set) var restarts = 0
    /// The most changes a turn's microphone is set up again for. A route that keeps changing (a headset that keeps
    /// dropping) must never keep restarting it: after that the turn ends with what was heard, and the call's record
    /// says why.
    static let setUpsPerTurn = 3
    private var setUpsThisTurn = 0
    private var gaveUp = false
    private let log: (String) -> Void
    /// Runs once when the microphone gives up on the turn: nothing more is heard in it.
    var onGaveUp: (() -> Void)?

    init(engine: any VoiceInputEngine,
         log: @escaping (String) -> Void = { step in Task { @MainActor in CrashReporter.shared.note(step) } }) {
        self.engine = engine
        self.log = log
    }

    /// Whether the microphone gives usable audio now.
    var hasInput: Bool { Self.usable(engine.inputFormat) }

    /// Feeds the microphone's audio to `onBuffer` until `stop()`, across changes to the phone's audio setup.
    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        setUpsThisTurn = 0
        gaveUp = false
        let format = engine.inputFormat
        guard Self.usable(format) else { throw VoiceRoomAudioError.invalidAudioFormat }
        self.onBuffer = onBuffer
        tap(format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        let center = NotificationCenter.default
        watches = [
            // The engine stopped because the audio setup changed.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.setUpAgain()
            },
            // The route moved; if that stopped the engine without a configuration change, it starts again too.
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.engine.isRunning else { return }
                self.setUpAgain()
            }
        ]
    }

    func stop() {
        for watch in watches { NotificationCenter.default.removeObserver(watch) }
        watches = []
        if engine.isRunning { engine.stop() }
        if tapped {
            engine.removeInputTap()
            tapped = false
        }
        onBuffer = nil
    }

    /// The audio setup changed while listening: the tap goes back on in the new format and the engine starts again.
    /// Past the turn's limit, without usable audio, or when the engine will not start, the microphone gives up on the
    /// turn: the call's record says why, once, and the turn is told, so it ends now with what was heard.
    func setUpAgain() {
        guard onBuffer != nil, !gaveUp else { return }
        guard setUpsThisTurn < Self.setUpsPerTurn else {
            giveUp("microphone not started again: the audio changed more than \(Self.setUpsPerTurn) times in one turn")
            return
        }
        setUpsThisTurn += 1
        if engine.isRunning { engine.stop() }
        if tapped {
            engine.removeInputTap()
            tapped = false
        }
        let format = engine.inputFormat
        guard Self.usable(format) else {
            giveUp("microphone not started again: no usable audio after the change")
            return
        }
        tap(format)
        engine.prepare()
        guard (try? engine.start()) != nil else {
            giveUp("microphone not started again: it would not start after the change")
            return
        }
        restarts += 1
    }

    private func giveUp(_ why: String) {
        guard !gaveUp else { return }
        gaveUp = true
        log(why)
        onGaveUp?()
    }

    private func tap(_ format: AVAudioFormat) {
        guard let onBuffer else { return }
        engine.installInputTap(bufferSize: 1_024, format: format) { buffer, _ in onBuffer(buffer) }
        tapped = true
    }

    private static func usable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }
}

/// Apple's on-device recognizer, as in push-to-talk, but it leaves the audio session to the voice room and reports
/// partial results. It never falls back to server recognition.
final class OnDeviceVoiceListener: VoiceListening {
    /// How loud the microphone is, 0 to 1, about fifty times a second while listening (for the call's waveform).
    var onLevel: (@MainActor @Sendable (Double) -> Void)?
    var onMicrophoneLost: (@MainActor () -> Void)?
    /// The microphone, which keeps a turn going when the Speaker button or a headset changes the audio setup.
    private let microphone = MicrophoneTap(engine: AVAudioEngine())
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
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
        guard microphone.hasInput else { throw VoiceRoomAudioError.invalidAudioFormat }
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
        // The microphone gave up on this turn: the call ends it now.
        microphone.onGaveUp = { [weak self] in
            Task { @MainActor [weak self] in self?.onMicrophoneLost?() }
        }
        do {
            try microphone.start { buffer in
                request.append(buffer)
                guard let onLevel else { return }
                let level = Self.level(of: buffer)
                Task { @MainActor in onLevel(level) }
            }
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
        microphone.stop()
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
