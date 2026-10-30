import XCTest
@testable import SentiPocketApp

/// The ring a call plays until the agent picks up (Carter, 10-30: "there should be a ring calling").
@MainActor
final class RingbackToneTests: XCTestCase {
    func test_the_ring_is_two_seconds_of_tone_then_four_of_quiet_as_a_wav_file() {
        let rate = RingbackTone.sampleRate
        let samples = RingbackTone.ringCycle()
        XCTAssertEqual(samples.count, 6 * rate)
        XCTAssertGreaterThan(samples[rate / 2 ..< rate].map { abs(Int($0)) }.max() ?? 0, 8_000, "the tone sounds")
        XCTAssertEqual(samples[0], 0, "faded in, no click")
        XCTAssertTrue(samples[(2 * rate)...].allSatisfy { $0 == 0 }, "then quiet")

        let wav = RingbackTone.cycle
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8 ..< 16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: wav[36 ..< 40], as: UTF8.self), "data")
    }
}
