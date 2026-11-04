import XCTest
@testable import PocketUI

/// The writing box's height rule (review of the composer fix): one line when empty, the text's height up to six lines,
/// six lines past that (it scrolls), rounded once.
final class ComposerTextFieldTests: XCTestCase {
    func test_the_box_is_one_line_empty_grows_with_the_text_and_stops_at_six_lines() {
        let line: CGFloat = 20.3
        XCTAssertEqual(ComposerTextField.boxHeight(contentHeight: 0, lineHeight: line, maxLines: 6), 21, "empty: one line")
        XCTAssertEqual(ComposerTextField.boxHeight(contentHeight: line, lineHeight: line, maxLines: 6), 21)
        XCTAssertEqual(ComposerTextField.boxHeight(contentHeight: 3 * line, lineHeight: line, maxLines: 6), 61, "three lines")
        XCTAssertEqual(ComposerTextField.boxHeight(contentHeight: 40 * line, lineHeight: line, maxLines: 6), 122,
                       "six lines at most, rounded once (not 6 x 21 = 126)")
        XCTAssertEqual(ComposerTextField.boxHeight(contentHeight: 40 * line, lineHeight: line, maxLines: 1), 21)
    }
}
