@testable import PocketVoice
import Foundation
import XCTest

@MainActor
private final class FakeSpeechEngine: MessageSpeechEngine {
    struct Spoken {
        let segments: [SpeechText.Segment]
        let voiceIdentifier: String?
        let language: String
        let finished: @MainActor () -> Void
    }

    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func speak(
        _ segments: [SpeechText.Segment],
        voiceIdentifier: String?,
        language: String,
        finished: @escaping @MainActor () -> Void
    ) {
        spoken.append(Spoken(segments: segments, voiceIdentifier: voiceIdentifier, language: language, finished: finished))
    }

    func stop() {
        stopCount += 1
    }
}

private final class RecordingSessionSystem: DuplexAudioSessionSystem, @unchecked Sendable {
    private(set) var callActivations = 0
    private(set) var playbackActivations = 0
    private(set) var deactivations = 0

    func activate() throws { callActivations += 1 }
    func activatePlayback() throws { playbackActivations += 1 }
    func deactivate() throws { deactivations += 1 }
}

@MainActor
final class MessageReaderTests: XCTestCase {
    private var system: RecordingSessionSystem!
    private var sessions: DuplexAudioSessionLeaseManager!
    private var engine: FakeSpeechEngine!

    override func setUp() async throws {
        system = RecordingSessionSystem()
        sessions = DuplexAudioSessionLeaseManager(system: system)
        engine = FakeSpeechEngine()
    }

    private func reader(voices: [VoiceOption] = [], phone: String = "en-US") -> MessageReader {
        MessageReader(engine: engine, sessions: sessions, voices: { voices }, phoneLanguageTag: { phone })
    }

    func test_reading_takes_a_playback_session_and_finishing_gives_it_back() {
        let reader = reader()
        XCTAssertEqual(reader.read(id: "msg:111", markdown: "Two findings so far. **One** is fixed."), .started)
        XCTAssertEqual(reader.readingId, "msg:111")
        XCTAssertEqual(engine.spoken.first?.segments.map(\.text), ["Two findings so far.", "One is fixed."])
        XCTAssertEqual(system.playbackActivations, 1)
        XCTAssertEqual(system.callActivations, 0)

        engine.spoken[0].finished()
        XCTAssertNil(reader.readingId)
        XCTAssertEqual(system.deactivations, 1)
    }

    func test_a_second_listen_stops_the_first_exactly_once_and_keeps_the_session() {
        let reader = reader()
        reader.read(id: "msg:111", markdown: "First message.")
        XCTAssertEqual(reader.read(id: "msg:121", markdown: "Second message."), .started)

        XCTAssertEqual(engine.stopCount, 1, "the first reading stops once")
        XCTAssertEqual(reader.readingId, "msg:121")
        XCTAssertEqual(system.playbackActivations, 1, "the session is handed on, not torn down and set up again")
        XCTAssertEqual(system.deactivations, 0)

        engine.spoken[0].finished()
        XCTAssertEqual(reader.readingId, "msg:121", "the first reading's late end changes nothing")
        XCTAssertEqual(system.deactivations, 0)

        engine.spoken[1].finished()
        XCTAssertNil(reader.readingId)
        XCTAssertEqual(system.deactivations, 1)
    }

    func test_listening_to_the_same_message_again_starts_it_over_and_stop_stops_it() {
        let reader = reader()
        reader.read(id: "msg:111", markdown: "A message.")
        XCTAssertEqual(reader.read(id: "msg:111", markdown: "A message."), .started)
        XCTAssertEqual(reader.readingId, "msg:111")
        XCTAssertEqual(engine.spoken.count, 2)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(system.playbackActivations, 1)

        reader.stop()
        XCTAssertNil(reader.readingId)
        XCTAssertEqual(engine.stopCount, 2)
        XCTAssertEqual(system.deactivations, 1)
        reader.stop()
        XCTAssertEqual(engine.stopCount, 2, "stopping when nothing is read does nothing")
        XCTAssertEqual(system.deactivations, 1)
    }

    func test_listen_never_reconfigures_an_active_call_or_briefing() throws {
        let reader = reader()
        let call = try sessions.acquire()
        XCTAssertEqual(reader.read(id: "msg:111", markdown: "A message."), .unavailable)
        XCTAssertNil(reader.readingId)
        XCTAssertTrue(engine.spoken.isEmpty)
        XCTAssertEqual(system.playbackActivations, 0, "the call's session is never switched to playback")
        XCTAssertEqual(system.callActivations, 1)
        sessions.release(call)

        sessions.callKitDidActivate()
        XCTAssertEqual(reader.read(id: "msg:111", markdown: "A message."), .unavailable, "nor while CallKit owns it")
        XCTAssertEqual(system.playbackActivations, 0)
    }

    func test_a_call_that_starts_takes_the_session_back_and_stops_the_reading() async throws {
        let reader = reader()
        reader.read(id: "msg:111", markdown: "A long message being read.")
        let call = try sessions.acquire()
        for _ in 0..<20 where reader.readingId != nil { await Task.yield() }

        XCTAssertNil(reader.readingId)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(system.callActivations, 1, "the call sets up its own session")
        XCTAssertEqual(system.deactivations, 0, "the reading does not deactivate the call's session")

        XCTAssertEqual(reader.read(id: "msg:121", markdown: "Another."), .unavailable)
        XCTAssertEqual(sessions.release(call), .deactivated)
    }

    func test_an_interruption_or_unplugged_headphones_stop_the_reading() {
        let reader = reader()
        reader.read(id: "msg:111", markdown: "A message.")
        reader.handle(.began)
        XCTAssertNil(reader.readingId)
        XCTAssertEqual(system.deactivations, 1)

        reader.read(id: "msg:121", markdown: "Another message.")
        reader.handle(.outputDeviceUnavailable)
        XCTAssertNil(reader.readingId)
        XCTAssertEqual(engine.stopCount, 2)
        XCTAssertEqual(system.deactivations, 2)
    }

    func test_a_message_with_nothing_to_say_does_not_start() {
        let reader = reader()
        XCTAssertEqual(reader.read(id: "msg:111", markdown: "  \n "), .nothingToSay)
        XCTAssertEqual(system.playbackActivations, 0)
    }

    func test_the_voice_follows_a_clear_message_language_and_otherwise_the_phone() {
        let voices = [
            VoiceOption(identifier: "fr.standard", language: "fr-FR", quality: .standard, isLanguageDefault: true),
            VoiceOption(identifier: "fr.enhanced", language: "fr-CA", quality: .enhanced),
            VoiceOption(identifier: "de.standard", language: "de-DE", quality: .standard, isLanguageDefault: true),
            VoiceOption(identifier: "en.standard", language: "en-US", quality: .standard, isLanguageDefault: true)
        ]
        let reader = reader(voices: voices, phone: "de-DE")
        reader.read(id: "msg:1", markdown: "Bonjour à tous, la correction pour la validation est prête pour la revue de ce soir.")
        XCTAssertEqual(engine.spoken.last?.language, "fr")
        XCTAssertEqual(engine.spoken.last?.voiceIdentifier, "fr.enhanced", "the better voice wins over the region")

        reader.read(id: "msg:2", markdown: "ok")
        XCTAssertEqual(engine.spoken.last?.language, "de", "a word too short to tell falls back to the phone")
        XCTAssertEqual(engine.spoken.last?.voiceIdentifier, "de.standard")
    }

    func test_the_best_voice_is_premium_then_enhanced_then_the_systems_own_then_the_phones_region() {
        let options = [
            VoiceOption(identifier: "b.us", language: "en-US", quality: .standard),
            VoiceOption(identifier: "a.gb", language: "en-GB", quality: .standard),
            VoiceOption(identifier: "c.us.default", language: "en-US", quality: .standard, isLanguageDefault: true)
        ]
        XCTAssertEqual(VoicePicker.voice(for: "en", phoneLanguageTag: "en-GB", from: options), "c.us.default")
        XCTAssertEqual(VoicePicker.voice(for: "en", phoneLanguageTag: "en-GB", from: Array(options.prefix(2))), "a.gb")
        XCTAssertEqual(VoicePicker.voice(for: "en", phoneLanguageTag: "en_GB", from: options + [
            VoiceOption(identifier: "z.enhanced", language: "en-AU", quality: .enhanced)
        ]), "z.enhanced")
        XCTAssertEqual(VoicePicker.voice(for: "en", phoneLanguageTag: "en-US", from: options + [
            VoiceOption(identifier: "z.enhanced", language: "en-AU", quality: .enhanced),
            VoiceOption(identifier: "y.premium", language: "en-IE", quality: .premium)
        ]), "y.premium")
        XCTAssertNil(VoicePicker.voice(for: "ja", phoneLanguageTag: "en-US", from: options))
    }
}
