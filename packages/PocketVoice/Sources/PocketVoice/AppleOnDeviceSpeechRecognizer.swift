#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognition as a `SpeechRecognizer`: what a call listens with when no Whisper model file is
/// installed (a Release build never asks for one). It brings its own model, so it needs no file (`needsModelFile`).
/// Never server-backed: without on-device recognition for its language, or without the Speech Recognition permission,
/// it transcribes nothing.
public actor AppleOnDeviceSpeechRecognizer: SpeechRecognizer {
    private let localeIdentifier: String
    private let authorizer: @Sendable () async -> Bool
    private var running: RecognitionRun?

    public nonisolated var needsModelFile: Bool { false }

    /// Speech Recognition, asked with the microphone's permission, before anything is captured.
    public func authorize() async -> Bool { await authorizer() }

    public init(
        localeIdentifier: String = "en-US",
        authorize: @escaping @Sendable () async -> Bool = { await AppleOnDeviceSpeechRecognizer.requestAuthorization() }
    ) {
        self.localeIdentifier = localeIdentifier
        self.authorizer = authorize
    }

    /// Nothing to load: Apple's model is on the device. Answers at once, whatever `modelURL` is.
    public func prepareModel(at modelURL: URL) async throws -> SpeechModelMetrics {
        SpeechModelMetrics(
            modelIdentifier: "apple-on-device-\(localeIdentifier)",
            loadMilliseconds: 0,
            residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
            thermalState: VoiceRuntimeSnapshot.thermalLevel
        )
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard running == nil else { throw VoiceError.recognizerBusy }
        guard await authorizer() else { throw VoiceError.speechPermissionDenied }
        guard running == nil else { throw VoiceError.recognizerBusy }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.onDeviceRecognitionUnavailable
        }
        let speech = try Self.speechRequest(request)
        let run = RecognitionRun()
        running = run
        defer { if running === run { running = nil } }
        let started = ContinuousClock.now
        let text = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                run.start(continuation) {
                    recognizer.recognitionTask(with: speech) { result, error in
                        if let result, result.isFinal {
                            run.finish(.success(result.bestTranscription.formattedString))
                        } else if let error {
                            run.finish(.failure(error))
                        }
                    }
                }
            }
        } onCancel: {
            run.cancel()
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw VoiceError.noSpeech }
        let elapsed = started.duration(to: .now).voiceMilliseconds
        return TranscriptionResult(
            text: normalized,
            metrics: TranscriptionMetrics(
                audioDurationSeconds: request.durationSeconds,
                transcriptionMilliseconds: elapsed,
                realTimeFactor: elapsed / 1_000 / request.durationSeconds,
                residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
                thermalState: VoiceRuntimeSnapshot.thermalLevel
            )
        )
    }

    public func cancel() async {
        running?.cancel()
    }

    /// The captured 16 kHz mono samples as one buffer, on the device only, ended so the result comes at once.
    static func speechRequest(_ request: TranscriptionRequest) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TranscriptionRequest.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(request.samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw VoiceError.invalidAudio
        }
        for (index, sample) in request.samples.enumerated() { channel[index] = sample }
        buffer.frameLength = AVAudioFrameCount(request.samples.count)
        let speech = SFSpeechAudioBufferRecognitionRequest()
        speech.requiresOnDeviceRecognition = true
        speech.shouldReportPartialResults = false
        if #available(iOS 16.0, macOS 13.0, *) { speech.addsPunctuation = true }
        speech.append(buffer)
        speech.endAudio()
        return speech
    }

    /// Asks for Speech Recognition once; true only when it is allowed. An answer that doesn't come within `wait` seconds
    /// (a call answered on a locked phone, where the question can't show yet) counts as no, so a call never waits on it.
    public static func requestAuthorization(
        wait seconds: Double = 20,
        status: () -> SFSpeechRecognizerAuthorizationStatus = { SFSpeechRecognizer.authorizationStatus() },
        request: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = {
            SFSpeechRecognizer.requestAuthorization($0)
        }
    ) async -> Bool {
        let current = status()
        if current == .authorized { return true }
        guard current == .notDetermined else { return false }
        let answer = AuthorizationAnswer()
        return await withCheckedContinuation { continuation in
            answer.start(continuation)
            request { answer.resume($0 == .authorized) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                answer.resume(false)
            }
        }
    }
}

/// The permission question's answer, taken once: the person's, or no when it doesn't come in time.
private final class AuthorizationAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func start(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ allowed: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: allowed)
    }
}

/// One recognition: answered once (its result, an error, or a cancel), and its task cancelled with it.
private final class RecognitionRun: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var task: SFSpeechRecognitionTask?
    private var isCancelled = false

    func start(_ continuation: CheckedContinuation<String, Error>, task makeTask: () -> SFSpeechRecognitionTask) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(throwing: VoiceError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()
        let task = makeTask()
        lock.lock()
        let cancelledMeanwhile = isCancelled
        self.task = task
        lock.unlock()
        if cancelledMeanwhile { task.cancel() }
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: VoiceError.cancelled)
    }
}
#endif
