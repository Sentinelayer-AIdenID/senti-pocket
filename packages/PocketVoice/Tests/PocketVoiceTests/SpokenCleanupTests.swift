import XCTest
@testable import PocketVoice

final class SpokenCleanupTests: XCTestCase {
    func test_fillers_go_and_the_rest_is_kept_as_said() {
        XCTAssertEqual(SpokenCleanup.clean("um so uh can you ship it, erm, tonight"), "So can you ship it, tonight")
        XCTAssertEqual(SpokenCleanup.clean("Hmm. What about the build?"), "What about the build?")
    }

    func test_a_word_or_short_phrase_said_twice_in_a_row_is_kept_once() {
        XCTAssertEqual(SpokenCleanup.clean("the the build is green"), "The build is green")
        XCTAssertEqual(SpokenCleanup.clean("can you can you hear me"), "Can you hear me")
        XCTAssertEqual(SpokenCleanup.clean("I I I think so"), "I think so")
        XCTAssertEqual(SpokenCleanup.clean("Ship it. Ship it."), "Ship it.", "the repeat keeps the punctuation that ends it")
    }

    func test_nothing_else_is_touched() {
        XCTAssertEqual(SpokenCleanup.clean("Run the tests, then run the build"), "Run the tests, then run the build")
        XCTAssertEqual(SpokenCleanup.clean("@pocket-forge what changed tonight?"), "@pocket-forge what changed tonight?")
        XCTAssertEqual(SpokenCleanup.clean(""), "")
        XCTAssertEqual(SpokenCleanup.clean("um"), "")
    }
}
