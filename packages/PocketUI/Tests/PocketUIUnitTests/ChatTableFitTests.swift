import XCTest
@testable import PocketUI

/// Carter, #55517: "if they are only 2 or 3 cells they stay within the bounds of the screen they're in and if more then
/// they can move with slider? And if I copy that message im not copying some really weirdly formatted message".
final class ChatTableFitTests: XCTestCase {
    private func table(_ header: [String], _ rows: [[String]]) -> ChatMarkdownTable {
        ChatMarkdownTable(header: header, alignments: header.map { _ in .leading }, rows: rows)
    }

    func test_a_narrow_table_with_long_cells_is_fitted_to_the_screen_and_wraps() {
        let long = String(repeating: "word ", count: 30)
        let two = table(["Step", "What happens"], [["1", long], ["2", long]])
        let fit = two.fittedWidths(available: 330)
        XCTAssertFalse(fit.scrolls)
        XCTAssertEqual(fit.widths.reduce(0, +), 330, accuracy: 0.5, "it fills the screen and no more")
        XCTAssertEqual(fit.widths[0], two.columnWidths()[0], accuracy: 0.5, "a short column keeps its width")

        let three = table(["A", "B", "C"], [[long, long, long]])
        let fitThree = three.fittedWidths(available: 330)
        XCTAssertFalse(fitThree.scrolls)
        XCTAssertEqual(fitThree.widths.reduce(0, +), 330, accuracy: 0.5)
        XCTAssertTrue(fitThree.widths.allSatisfy { $0 >= 90 }, "every column stays readable")
    }

    func test_a_table_that_already_fits_keeps_its_widths() {
        let small = table(["Name", "Done"], [["warden", "yes"]])
        let fit = small.fittedWidths(available: 330)
        XCTAssertFalse(fit.scrolls)
        XCTAssertEqual(fit.widths, small.columnWidths())
    }

    func test_a_wide_table_keeps_readable_columns_and_scrolls() {
        let long = String(repeating: "word ", count: 10)
        let wide = table(["A", "B", "C", "D", "E"], [[long, long, long, long, long]])
        let fit = wide.fittedWidths(available: 330)
        XCTAssertTrue(fit.scrolls)
        XCTAssertEqual(fit.widths, wide.columnWidths())
        XCTAssertFalse(wide.fittedWidths(available: 1024).scrolls, "a wider screen fits it")
    }

    func test_a_copied_table_is_tab_separated_rows_and_the_rest_is_as_written() {
        let message = """
        Status for **today**:

        | Lane | State |
        | --- | :-: |
        | **API** | green |
        | Phone | `building` |

        Next: ship it.
        """
        XCTAssertEqual(ChatMarkdown.copyText(message), """
        Status for **today**:

        Lane\tState
        API\tgreen
        Phone\tbuilding

        Next: ship it.
        """)
    }

    func test_a_table_inside_a_code_block_is_copied_as_written() {
        let message = """
        ```
        | a | b |
        | - | - |
        ```
        """
        XCTAssertEqual(ChatMarkdown.copyText(message), message)
    }
}
