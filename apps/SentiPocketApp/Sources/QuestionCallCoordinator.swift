import Foundation
import SwiftUI

/// One answered timer call, using the same local speech and CallKit audio as a voice room. Its only write is the
/// question answer API: no agent persona, model turn, generic room post or synthetic call transcript.
@MainActor
final class QuestionCallCoordinator: ObservableObject {
    enum Phase: Equatable { case loading, speaking, ready, listening, recognizing, sending, retry, answered, ended }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var question: RoomQuestion?
    @Published private(set) var partial = ""
    @Published private(set) var notice: String?
    @Published private(set) var isMuted = false
    @Published private(set) var listenerBusy = false

    private let expected: RoomQuestion
    private let api: any RoomQuestionsAPI
    private let listener: any VoiceListening
    private let speaker: any VoiceSpeaking
    private let audio: any VoiceRoomAudioSession
    private let callScreen: (any VoiceRoomCallScreen)?
    private let now: () -> Date
    private let onEnded: () -> Void
    private let onNotice: (String) -> Void
    private var generation = 0
    private var lastWords: Date?
    private var silence: Task<Void, Never>?
    private var submitted: RoomQuestionAnswer?
    private var began = false

    init(question: RoomQuestion, api: any RoomQuestionsAPI, listener: any VoiceListening,
         speaker: any VoiceSpeaking, audio: any VoiceRoomAudioSession,
         callScreen: (any VoiceRoomCallScreen)? = nil, now: @escaping () -> Date = { Date() },
         onEnded: @escaping () -> Void, onNotice: @escaping (String) -> Void = { _ in }) {
        expected = question
        self.api = api
        self.listener = listener
        self.speaker = speaker
        self.audio = audio
        self.callScreen = callScreen
        self.now = now
        self.onEnded = onEnded
        self.onNotice = onNotice
    }

    var canAnswer: Bool { question != nil && submitted == nil && [.speaking, .ready, .listening].contains(phase) }
    var canSpeak: Bool { canAnswer && !isMuted && !listenerBusy }

    func begin() async {
        guard !began, phase == .loading else { return }
        began = true
        let revision = generation
        do {
            let current = try await api.question(sessionId: expected.sessionId, questionId: expected.id)
            guard revision == generation, phase != .ended else { return }
            guard current.isSameSource(as: expected), current.canAnswer(at: now()), current.status == "called"
            else { refuse("This question is no longer waiting for an answer."); return }
            try audio.activate()
            question = current
            phase = .ready
            readQuestion()
        } catch {
            guard revision == generation, phase != .ended else { return }
            refuse("The question could not be read safely. Open its room to answer.")
        }
    }

    func readQuestion() {
        guard let question, canAnswer, question.canAnswer(at: now()) else { return }
        generation += 1
        silence?.cancel()
        listener.cancel()
        partial = ""
        phase = .speaking
        let revision = generation
        speaker.speakVerbatim(question.spoken, as: "Senti") { [weak self] in
            guard let self, self.generation == revision, self.phase == .speaking else { return }
            self.phase = .ready
            if !self.isMuted { Task { await self.listen() } }
        }
    }

    func listen() async {
        guard canSpeak, let question else { return }
        guard question.canAnswer(at: now()) else { refuse("This question has expired."); return }
        generation += 1
        let revision = generation
        silence?.cancel()
        speaker.stop()
        partial = ""
        lastWords = nil
        phase = .listening
        // start() may suspend for permission and stop() for final words. cancel() alone does not drain either.
        // Keep this listener exclusive until the pending operation returns, even after mute changes the phase.
        listenerBusy = true
        defer { listenerBusy = false }
        do {
            try await listener.start { [weak self] text in
                guard let self, self.generation == revision, self.phase == .listening else { return }
                if text != self.partial { self.partial = text; self.lastWords = self.now() }
            }
            guard revision == generation, phase == .listening else { listener.cancel(); return }
            // The existing on-device recognizer supplies words; a pause sends exactly one answer. A tap can stop
            // earlier. There is no server recognition fallback and no listening over the spoken question.
            silence = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self, self.generation == revision, self.phase == .listening else { return }
                    if let last = self.lastWords, !self.partial.isEmpty, self.now().timeIntervalSince(last) >= 1.8 {
                        self.silence = nil
                        await self.finishSpeaking()
                        return
                    }
                }
            }
        } catch {
            guard revision == generation, phase != .ended else { return }
            listener.cancel()
            phase = .ready
            notice = (error as? LocalizedError)?.errorDescription ?? "Speech is unavailable. You can tap a choice."
        }
    }

    func finishSpeaking() async {
        guard phase == .listening, !isMuted, !listenerBusy else { return }
        generation += 1
        let revision = generation
        silence?.cancel()
        phase = .recognizing
        listenerBusy = true
        let heard = await listener.stop()
        listenerBusy = false
        guard revision == generation, phase == .recognizing, !isMuted else { return }
        let text = (heard.isEmpty ? partial : heard).trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !text.isEmpty else { phase = .ready; return }
        guard text.unicodeScalars.count <= 2_000 else {
            phase = .ready
            notice = "Keep your answer under 2,000 characters, or tap a choice."
            return
        }
        guard let question else { return }
        await submit(question.answer(from: text))
    }

    func choose(_ id: String) async {
        guard canAnswer, question?.choices.contains(where: { $0.id == id }) == true else { return }
        await submit(.choice(id))
    }

    func retry() async {
        guard phase == .retry, let submitted else { return }
        await submit(submitted)
    }

    private func submit(_ answer: RoomQuestionAnswer) async {
        guard let question, phase != .ended, phase != .answered,
              submitted == nil || (phase == .retry && submitted == answer) else { return }
        guard question.canAnswer(at: now()) || submitted != nil else { refuse("This question has expired."); return }
        // Claim the answer before the first await: competing taps/voice callbacks cannot create a second request.
        submitted = answer
        generation += 1
        let revision = generation
        silence?.cancel()
        listener.cancel()
        speaker.stop()
        partial = ""
        notice = nil
        phase = .sending
        do {
            let result = try await api.answer(answer, question: question)
            guard revision == generation, phase != .ended else { return }
            guard result.isSameSource(as: question), result.status == "answered", result.answerActionId != nil else {
                throw RoomCallsClient.Failure.unreadable
            }
            phase = .answered
            speaker.speak("Your answer is posted under the question.", as: "Senti") { [weak self] in self?.hangUp() }
        } catch RoomCallsClient.Failure.refused(let status) where [401, 403, 404, 409, 410, 422].contains(status) {
            guard revision == generation, phase != .ended else { return }
            refuse("The answer was not accepted. Open the question in its room to check its current state.")
        } catch RoomCallsClient.Failure.signedOut {
            guard revision == generation, phase != .ended else { return }
            refuse("Sign in again to answer this question.")
        } catch {
            guard revision == generation, phase != .ended else { return }
            phase = .retry
            notice = "The answer is not confirmed. Retry sends the same answer once more; the room keeps one copy."
        }
    }

    func callScreenMuted(_ muted: Bool) {
        isMuted = muted
        if muted, phase == .listening || phase == .recognizing {
            generation += 1
            silence?.cancel()
            listener.cancel()
            partial = ""
            phase = .ready
        }
    }

    func requestMute() {
        callScreen?.setMuted(!isMuted) { [weak self] accepted in
            if !accepted { self?.notice = "Mute could not be changed. Use the phone's call screen." }
        }
    }

    func hangUp() {
        guard phase != .ended else { return }
        generation += 1
        silence?.cancel()
        listener.cancel()
        speaker.stop()
        audio.deactivate()
        question = nil
        partial = ""
        phase = .ended
        onEnded()
    }

    private func refuse(_ message: String) {
        onNotice(message)
        hangUp()
    }
}
