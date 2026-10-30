import XCTest
@testable import PocketUI

/// Carter (10-30): "a wave form for when yall talking".
@MainActor
final class VoiceLevelMeterTests: XCTestCase {
    func test_a_level_heard_becomes_the_newest_bar_and_then_fades() {
        let meter = VoiceLevelMeter()
        defer { meter.reset() }
        meter.hear(0.8, from: .you)
        XCTAssertTrue(meter.isTicking)
        meter.advance()
        XCTAssertEqual(meter.bars.last ?? -1, 0.8, accuracy: 0.0001)
        meter.advance()
        XCTAssertEqual(meter.bars.last ?? -1, 0.8 * VoiceLevelMeter.fade, accuracy: 0.0001, "nothing new: it fades")
        XCTAssertEqual(meter.bars.count, VoiceLevelMeter.barCount, "the waveform keeps its width")
    }

    func test_the_loudest_since_the_last_step_is_shown_and_the_colour_follows_who_is_talking() {
        let meter = VoiceLevelMeter()
        defer { meter.reset() }
        meter.hear(0.3, from: .you)
        meter.hear(0.6, from: .agent)
        meter.hear(0.2, from: .agent)
        XCTAssertEqual(meter.source, .agent)
        meter.advance()
        XCTAssertEqual(meter.bars.last ?? -1, 0.6, accuracy: 0.0001)
        meter.hear(4, from: .agent)
        meter.advance()
        XCTAssertEqual(meter.bars.last ?? -1, 1, accuracy: 0.0001, "never past the top")
    }

    func test_once_everything_is_quiet_it_stops_ticking() {
        let meter = VoiceLevelMeter()
        defer { meter.reset() }
        meter.hear(0.5, from: .you)
        for _ in 0..<(VoiceLevelMeter.barCount + 40) { meter.advance() }
        XCTAssertFalse(meter.isTicking, "no timer runs for a flat line")
        XCTAssertTrue(meter.bars.allSatisfy { $0 == 0 })
        meter.hear(0.4, from: .you)
        XCTAssertTrue(meter.isTicking, "it starts again with the next sound")
    }

    func test_microphone_decibels_and_spoken_words_become_levels_from_zero_to_one() {
        XCTAssertEqual(VoiceLevelMeter.level(decibels: -80), 0)
        XCTAssertEqual(VoiceLevelMeter.level(decibels: -.infinity), 0)
        XCTAssertEqual(VoiceLevelMeter.level(decibels: 0), 1)
        XCTAssertGreaterThan(VoiceLevelMeter.level(decibels: -20), VoiceLevelMeter.level(decibels: -40))
        XCTAssertGreaterThan(VoiceLevelMeter.level(wordLength: 9), VoiceLevelMeter.level(wordLength: 2))
        XCTAssertLessThanOrEqual(VoiceLevelMeter.level(wordLength: 40), 1)
    }
}
