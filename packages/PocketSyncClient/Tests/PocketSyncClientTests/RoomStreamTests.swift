import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PocketSyncClient

final class RoomStreamTests: XCTestCase {
    // MARK: - SSE parsing

    func test_parser_dispatches_on_blank_line_and_joins_multi_line_data() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed("id: 0000000005678:0000beef"))
        XCTAssertNil(parser.feed("data: {\"a\":1,"))
        XCTAssertNil(parser.feed("data:\"b\":2}"))
        XCTAssertEqual(parser.feed(""), "{\"a\":1,\n\"b\":2}")
        XCTAssertEqual(parser.lastEventId, "0000000005678:0000beef")
        XCTAssertNil(parser.feed(""), "a second blank line dispatches nothing")
    }

    func test_parser_ignores_comments_unknown_fields_and_strips_carriage_returns() {
        var parser = SSELineParser()
        XCTAssertNil(parser.feed(": keep-alive"))
        XCTAssertNil(parser.feed("event: message\r"))
        XCTAssertNil(parser.feed("retry: 3000"))
        XCTAssertNil(parser.feed("data: {\"x\":true}\r"))
        XCTAssertEqual(parser.feed("\r"), "{\"x\":true}")
    }

    // MARK: - Frames

    func test_frames_decode_messages_controls_and_errors() {
        let messageFrame = RoomStreamFrame.decode("""
        {"id":"e1","event":"session_message","sequenceId":9,"agentId":"a","payload":{"message":"hi"}}
        """)
        if case .message(let message)? = messageFrame {
            XCTAssertEqual(message.sequenceId, 9)
        } else {
            XCTFail("expected a message frame, got \(String(describing: messageFrame))")
        }

        XCTAssertEqual(
            RoomStreamFrame.decode(#"{"type":"control","control":"agent_composing","schema":"agent-composing:v1","agentId":"cobalt-warden","targetSequenceId":5678}"#),
            .composing(agentId: "cobalt-warden", targetSequenceId: 5678)
        )
        XCTAssertEqual(RoomStreamFrame.decode(#"{"type":"control","control":"agent_observability_tick"}"#), .control)
        XCTAssertEqual(
            RoomStreamFrame.decode(#"{"type":"error","error":{"code":"SESSION_STREAM_BACKPRESSURE"}}"#),
            .serverError(code: "SESSION_STREAM_BACKPRESSURE")
        )
        XCTAssertEqual(
            RoomStreamFrame.decode(#"{"id":"h","event":"listener_heartbeat","sequenceId":11,"payload":{}}"#),
            .nonDisplayable(sequenceId: 11)
        )
        XCTAssertNil(RoomStreamFrame.decode("not json"))
    }

    // MARK: - Backoff

    func test_backoff_reconnects_at_once_after_a_productive_connection_and_doubles_otherwise() {
        var backoff = RoomStreamBackoff()
        XCTAssertEqual(backoff.delayAfter(.closed, deliveredEvents: true), 0)
        XCTAssertEqual(backoff.delayAfter(.retryable(retryAfterSeconds: nil), deliveredEvents: false), 2)
        XCTAssertEqual(backoff.delayAfter(.retryable(retryAfterSeconds: nil), deliveredEvents: false), 4)
        XCTAssertEqual(backoff.delayAfter(.closed, deliveredEvents: false), 8)
        for _ in 0..<5 { _ = backoff.delayAfter(.retryable(retryAfterSeconds: nil), deliveredEvents: false) }
        XCTAssertEqual(backoff.delayAfter(.retryable(retryAfterSeconds: nil), deliveredEvents: false), 30, "capped")
        XCTAssertEqual(backoff.delayAfter(.closed, deliveredEvents: true), 0, "a productive connection resets it")
    }

    func test_backoff_honours_retry_after_and_stops_on_terminal_ends() {
        var backoff = RoomStreamBackoff()
        XCTAssertEqual(backoff.delayAfter(.retryable(retryAfterSeconds: 45), deliveredEvents: false), 45)
        XCTAssertNil(backoff.delayAfter(.reauthenticationRequired, deliveredEvents: false))
        XCTAssertNil(backoff.delayAfter(.accessDenied, deliveredEvents: true))
    }
}
