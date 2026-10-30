import Foundation
import XCTest
@testable import PocketUI

/// The helpers every room update runs, made cheap, must say exactly what the expressions they replaced said.
final class HotPathTests: XCTestCase {
    func test_a_notices_shape_drops_its_numbers_as_before() {
        let samples = [
            "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after 105 failed relay attempts.",
            "[cost] box: $19.05 est over 1462 calls · room so far $4103.34",
            "no digits here", "", "٣ Arabic-Indic digits stay", "v2.3.10 build 2026103004"
        ]
        for sample in samples {
            let expression = sample.replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
            XCTAssertEqual(RoomChatRepeats.shape(sample), expression, sample)
        }
    }

    func test_a_quiet_line_is_the_same_the_second_time() {
        let text = "**READY** for [carry](/x)\nmore ⟂ speech 1"
        XCTAssertEqual(RoomChatQuiet.line(text), "READY for carry")
        XCTAssertEqual(RoomChatQuiet.line(text), "READY for carry", "remembered")
        XCTAssertEqual(RoomChatQuiet.line("> # Heading `code`"), "Heading code")
        XCTAssertEqual(ChatReferences.mentionHandles(in: "no mention here"), [])
    }
}
