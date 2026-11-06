import AVFoundation
import XCTest
@testable import SentiPocketApp

/// An audio engine that records what the microphone does with it, hands buffers to the installed tap while it runs, and
/// stops as the real one does when the phone's audio is set up again.
private final class FakeEngine: VoiceInputEngine {
    var isRunning = false
    var inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private(set) var starts = 0
    private(set) var taps = 0
    private(set) var removals = 0
    /// The engine refuses to start (after a change the phone's audio cannot give it).
    var refusesToStart = false
    private var tap: AVAudioNodeTapBlock?

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        taps += 1
        tap = block
    }

    func removeInputTap() {
        removals += 1
        tap = nil
    }

    func prepare() {}

    func start() throws {
        if refusesToStart { throw VoiceRoomAudioError.invalidAudioFormat }
        starts += 1
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    /// The microphone hears something: the tap gets it while the engine runs.
    func hear() {
        guard isRunning, let tap, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 160) else { return }
        buffer.frameLength = 160
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: inputFormat.sampleRate))
    }

    /// The phone's audio is set up again (the Speaker button, a headset): the engine stops, in a new format, and says so.
    func reconfigure(to format: AVAudioFormat) {
        isRunning = false
        inputFormat = format
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
}

/// What the tap delivered, counted from the audio thread.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    func add() { lock.withLock { buffers += 1 } }
    var count: Int { lock.withLock { buffers } }
}

/// Switching the Speaker mid-turn sets the phone's audio up again, which stops the audio engine. The turn being heard
/// goes on: the microphone starts again on the new route and what is said after the switch reaches the recognizer.
final class MicrophoneTapTests: XCTestCase {
    func test_a_turn_goes_on_when_the_audio_is_set_up_again_mid_listen() throws {
        let engine = FakeEngine()
        let microphone = MicrophoneTap(engine: engine)
        let heard = Heard()
        try microphone.start { _ in heard.add() }
        engine.hear()
        XCTAssertEqual(heard.count, 1)

        engine.reconfigure(to: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        pump(0.1)
        XCTAssertTrue(engine.isRunning, "listening starts again on the new route")
        XCTAssertEqual(engine.starts, 2)
        XCTAssertEqual(engine.taps, 2, "the tap goes back on, in the new format")
        XCTAssertEqual(engine.removals, 1)
        XCTAssertEqual(microphone.restarts, 1)
        engine.hear()
        XCTAssertEqual(heard.count, 2, "and the turn goes on: what is said after the switch is heard")

        // A route change that left the engine running changes nothing; one that stopped it starts it again.
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        pump(0.1)
        XCTAssertEqual(engine.starts, 2)
        engine.isRunning = false
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        pump(0.1)
        XCTAssertEqual(engine.starts, 3)
        engine.hear()
        XCTAssertEqual(heard.count, 3)

        // Once the turn is over, nothing starts the microphone again.
        microphone.stop()
        XCTAssertFalse(engine.isRunning)
        engine.reconfigure(to: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        pump(0.1)
        XCTAssertEqual(engine.starts, 3, "a turn that ended is not listened to again")
        XCTAssertFalse(engine.isRunning)
    }

    /// A route that keeps changing (a headset that keeps dropping) never keeps restarting the microphone: three changes
    /// in one turn set it up again, a fourth does not, and the call's record says why, once. The next turn starts afresh.
    func test_a_turn_sets_the_microphone_up_again_at_most_three_times() throws {
        let engine = FakeEngine()
        var logged: [String] = []
        let microphone = MicrophoneTap(engine: engine, log: { logged.append($0) })
        var gaveUp = 0
        microphone.onGaveUp = { gaveUp += 1 }
        let heard = Heard()
        let formats = [48_000.0, 16_000.0].map { AVAudioFormat(standardFormatWithSampleRate: $0, channels: 1)! }
        try microphone.start { _ in heard.add() }
        for change in 0..<MicrophoneTap.setUpsPerTurn {
            engine.reconfigure(to: formats[change % 2])
            pump(0.05)
            XCTAssertTrue(engine.isRunning, "change \(change + 1): listening starts again")
        }
        XCTAssertEqual(engine.starts, 1 + MicrophoneTap.setUpsPerTurn)
        XCTAssertTrue(logged.isEmpty)

        engine.reconfigure(to: formats[1])
        pump(0.05)
        XCTAssertFalse(engine.isRunning, "a fourth change in one turn does not start it again: it can never loop")
        XCTAssertEqual(engine.starts, 1 + MicrophoneTap.setUpsPerTurn)
        XCTAssertEqual(logged.count, 1, "the record says why")
        XCTAssertEqual(gaveUp, 1, "the turn is told: it ends now")
        XCTAssertTrue(logged.first?.contains("more than 3 times in one turn") == true, "\(logged)")
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        engine.reconfigure(to: formats[0])
        pump(0.05)
        XCTAssertEqual(engine.starts, 1 + MicrophoneTap.setUpsPerTurn, "nor any change after it")
        XCTAssertEqual(logged.count, 1, "said once")
        XCTAssertEqual(gaveUp, 1, "and told once")

        try microphone.start { _ in heard.add() }
        engine.reconfigure(to: formats[1])
        pump(0.05)
        XCTAssertTrue(engine.isRunning, "the next turn may set it up again")
        microphone.stop()
    }

    /// After a change the engine will not start again: the microphone gives up on the turn at once (the turn is told,
    /// and the record says why, once), rather than leaving the turn listening to nothing.
    func test_a_microphone_that_will_not_start_again_gives_up_on_the_turn_once() throws {
        let engine = FakeEngine()
        var logged: [String] = []
        let microphone = MicrophoneTap(engine: engine, log: { logged.append($0) })
        var gaveUp = 0
        microphone.onGaveUp = { gaveUp += 1 }
        try microphone.start { _ in }
        engine.refusesToStart = true
        engine.reconfigure(to: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        pump(0.05)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(gaveUp, 1, "the turn is told at once")
        XCTAssertEqual(logged, ["microphone not started again: it would not start after the change"])
        engine.refusesToStart = false
        engine.reconfigure(to: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        pump(0.05)
        XCTAssertFalse(engine.isRunning, "a turn given up on stays given up")
        XCTAssertEqual(gaveUp, 1)
        XCTAssertEqual(logged.count, 1, "the record says it once")
        try microphone.start { _ in }
        XCTAssertTrue(engine.isRunning, "the next turn starts as usual")
        microphone.stop()
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
