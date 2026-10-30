import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

@MainActor
final class ReadAloudSourceTests: XCTestCase {
    /// Carter (#55339): the player outside its room takes you back to what it is reading.
    func test_the_player_title_links_back_to_what_is_read() {
        XCTAssertEqual(ReadAloudSource.link(readingId: "msg:55290", sessionId: "room-a"),
                       SentiLink(sessionId: "room-a", messageSequence: 55290))
        XCTAssertEqual(ReadAloudSource.link(readingId: "reply:6f1c2b9e", sessionId: "room-a"),
                       SentiLink(sessionId: "room-a", replyId: "6f1c2b9e"))
        XCTAssertEqual(ReadAloudSource.link(readingId: "summary:room-a", sessionId: "room-a"), SentiLink(sessionId: "room-a"))
        XCTAssertEqual(ReadAloudSource.link(readingId: "msg:not-a-number", sessionId: "room-a"), SentiLink(sessionId: "room-a"))
    }

    func test_the_source_is_the_room_that_started_reading() {
        let source = ReadAloudSource.shared
        source.reading(in: "room-b")
        XCTAssertEqual(source.sessionId, "room-b")
    }
}
