import XCTest
@testable import PocketUI

/// Ticket 40c57e0c: the line under the last message while agents prepare replies.
final class RoomComposingWordsTests: XCTestCase {
    func test_senti_is_typing_and_other_agents_are_preparing_a_reply() {
        XCTAssertEqual(RoomComposingWords.line(["senti"]), "Senti is typing…")
        XCTAssertEqual(RoomComposingWords.line(["build-agent"]), "build-agent is preparing a reply…")
        XCTAssertEqual(RoomComposingWords.line(["build-agent", "senti"]), "build-agent and Senti are preparing replies…")
        XCTAssertEqual(RoomComposingWords.line(["a", "b", "senti"]), "3 agents are preparing replies…")
        XCTAssertEqual(RoomComposingWords.line([]), "")
    }
}
