import XCTest
@testable import PocketUI

/// Carter: "shell does not show me shell. Shows me the same details as the first tab." The Shell tab reads the box's
/// terminal from its console's events stream (frame shapes as respawn-mint `console.ts` reads them).
final class BoxShellTests: XCTestCase {
    func test_the_stream_comes_from_the_consoles_own_read_only_link() throws {
        let console = try XCTUnwrap(URL(string: "https://mint.example.invalid/console?life=0000life0001&view=fake-view-token"))
        XCTAssertEqual(BoxShell.eventsURL(console: console)?.absoluteString,
                       "https://mint.example.invalid/api/lives/0000life0001/events?life=0000life0001&view=fake-view-token")
    }

    func test_no_stream_without_a_view_token_or_from_another_kind_of_link() {
        let refused = [
            "https://mint.example.invalid/console?life=0000life0001",
            "http://mint.example.invalid/console?life=0000life0001&view=v",
            "https://mint.example.invalid/other?life=0000life0001&view=v",
            "https://mint.example.invalid/console?life=../admin&view=v"
        ]
        for link in refused {
            XCTAssertNil(URL(string: link).flatMap(BoxShell.eventsURL(console:)), link)
        }
    }

    func test_commands_output_errors_and_exits_read_as_a_terminal() {
        XCTAssertEqual(BoxShell.lines(fromFrame: #"{"kind":"cmd_start","data":{"id":1,"cmd":["bash","-lc","npm test"],"pid":42}}"#, firstId: 0),
                       [BoxShellLine(id: 0, kind: .command, text: "$ bash -lc npm test")])
        XCTAssertEqual(BoxShell.lines(fromFrame: #"{"kind":"stdout","data":{"id":1,"text":"ok 1\nok 2\n"}}"#, firstId: 5),
                       [BoxShellLine(id: 5, kind: .output, text: "ok 1"), BoxShellLine(id: 6, kind: .output, text: "ok 2")])
        XCTAssertEqual(BoxShell.lines(fromFrame: #"{"kind":"stderr","data":{"id":1,"text":"warn"}}"#, firstId: 0),
                       [BoxShellLine(id: 0, kind: .error, text: "warn")])
        XCTAssertEqual(BoxShell.lines(fromFrame: #"{"kind":"cmd_end","data":{"id":1,"exitCode":1,"signal":null,"durationMs":812}}"#, firstId: 0),
                       [BoxShellLine(id: 0, kind: .exit, text: "↳ exit 1 (812 ms)")])
    }

    func test_what_is_not_the_shell_is_left_out() {
        for frame in [
            #"{"kind":"metric","data":{"heartbeat":true}}"#,
            #"{"kind":"say","data":{"from":"room","text":"hi"}}"#,
            #"{"kind":"capture","data":{"b64":"AAAA","done":false}}"#,
            #"{"kind":"lifecycle","data":{"phase":"working"}}"#,
            "not json"
        ] {
            XCTAssertEqual(BoxShell.lines(fromFrame: frame, firstId: 0), [], frame)
        }
    }

    func test_a_very_long_printed_line_is_cut() {
        let long = String(repeating: "x", count: 1_000)
        let line = BoxShell.lines(fromFrame: #"{"kind":"stdout","data":{"text":"\#(long)"}}"#, firstId: 0).first
        XCTAssertEqual(line?.text.count, BoxShell.lineLimit + 1)
    }
}
