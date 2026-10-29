import Foundation
import XCTest
@testable import PocketUI

final class RoomSearchPresentationTests: XCTestCase {
    func test_the_first_match_is_marked_whatever_its_case() {
        let parts = RoomSearchPresentationState.highlight("Validation runs on PASTE and on paste", query: " paste ")
        XCTAssertEqual(parts?.before, "Validation runs on ")
        XCTAssertEqual(parts?.match, "PASTE")
        XCTAssertEqual(parts?.after, " and on paste")
        XCTAssertNil(RoomSearchPresentationState.highlight("nothing here", query: "paste"))
        XCTAssertNil(RoomSearchPresentationState.highlight("anything", query: "  "))
    }
}
