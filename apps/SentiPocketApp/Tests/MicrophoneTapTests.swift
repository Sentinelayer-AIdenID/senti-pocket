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

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
