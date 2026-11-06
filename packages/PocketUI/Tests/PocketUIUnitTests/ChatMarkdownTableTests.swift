import XCTest
@testable import PocketUI

/// Carter, #55366: "You wrote some tables inside your markdown. It should render as a table ... All the things an md
/// file should have." GitHub's table and task-list rules, on the report that showed them as run-on text.
final class ChatMarkdownTableTests: XCTestCase {
    func test_the_reports_table_is_a_table_with_its_rows_and_alignment() {
        let source = """
        **How safe, graded against evidence**

        | Area | Grade | Why |
        | --- | :-: | --: |
        | Pocket stability | B, rising | 3 crash causes found |
        | Scale | C | One VM |

        Brag-safe one-liners:
        """
        let blocks = ChatMarkdown.parse(source)
        XCTAssertEqual(blocks, [
            .paragraph("**How safe, graded against evidence**"),
            .table(ChatMarkdownTable(
                header: ["Area", "Grade", "Why"],
                alignments: [.leading, .center, .trailing],
                rows: [["Pocket stability", "B, rising", "3 crash causes found"], ["Scale", "C", "One VM"]]
            )),
            .paragraph("Brag-safe one-liners:")
        ])
    }

    func test_a_table_inside_a_list_item_indent_and_right_after_a_paragraph_line() {
        let blocks = ChatMarkdown.parse("Code, across 7 repos:\n  | Repo | Merged |\n  |---|---|\n  | Pocket | 20 |\n\nnext\n| a | b |\n|---|---|\n- item")
        XCTAssertEqual(blocks.first, .paragraph("Code, across 7 repos:"))
        guard case .table(let table)? = blocks.dropFirst().first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.header, ["Repo", "Merged"])
        XCTAssertEqual(table.rows, [["Pocket", "20"]])
        XCTAssertEqual(blocks.dropFirst(2).first, .paragraph("next"), "a blank line ends the table")
        guard case .table(let second)? = blocks.dropFirst(3).first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(second.rows, [], "the start of a list ends it too")
        XCTAssertEqual(blocks.count, 5)
    }

    func test_short_rows_are_filled_long_rows_cut_and_escaped_pipes_kept() {
        let blocks = ChatMarkdown.parse("a | b\n--- | ---\nonly\n1 | 2 | 3\n`x \\| y` | z")
        guard case .table(let table)? = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [["only", ""], ["1", "2"], ["`x | y`", "z"]])
    }

    func test_what_is_not_a_table_stays_as_it_was() {
        XCTAssertEqual(ChatMarkdown.parse("a | b\nno delimiter"), [.paragraph("a | b no delimiter")])
        XCTAssertEqual(ChatMarkdown.parse("a | b | c\n--- | ---"), [.paragraph("a | b | c --- | ---")], "cell counts must match")
        XCTAssertEqual(ChatMarkdown.parse("x |\n---"), [.paragraph("x |"), .rule], "a delimiter row needs a pipe")
        XCTAssertEqual(ChatMarkdown.parse("---\n| a |"), [.rule, .paragraph("| a |")])
    }

    func test_columns_are_as_wide_as_their_longest_cell_up_to_a_cap() {
        let table = ChatMarkdownTable(header: ["Grade", "Why"], alignments: [.leading, .leading],
                                      rows: [["B", String(repeating: "w", count: 200)]])
        let widths = table.columnWidths()
        XCTAssertEqual(widths[0], 5 * 7.6 + 20, accuracy: 0.01)
        XCTAssertEqual(widths[1], 240, "a long cell wraps instead of widening the column")
    }

    func test_task_items_read_their_box() {
        XCTAssertEqual(ChatMarkdownListItem.task("[ ] ship it")?.done, false)
        XCTAssertEqual(ChatMarkdownListItem.task("[x] shipped")?.text, "shipped")
        XCTAssertEqual(ChatMarkdownListItem.task("[X] shipped")?.done, true)
        XCTAssertNil(ChatMarkdownListItem.task("[link](https://x.io)"))
        XCTAssertNil(ChatMarkdownListItem.task("[]"))
    }
}
