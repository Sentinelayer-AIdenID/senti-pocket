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

    /// Ticket 40c57e0c: the frame the API sends (agent-composing:v1, as SessionComposingService writes it) is the
    /// room's typing leases as a whole set. Senti's lease decodes with the time it has left by the server's clock; an
    /// empty frame is no one typing; an agent id the contract does not allow is left out.
    func test_the_apis_composing_frame_is_the_rooms_whole_typing_set() {
        let frame = RoomStreamFrame.decode(
            #"{"type":"control","control":"agent_composing","schema":"agent-composing:v1","status":"ok","# +
            #""serverNowMs":1793980800000,"ttlSeconds":45,"active":[{"agentId":"senti","runId":"room_1-msg-7","# +
            #""targetKind":"message","targetId":"7f2e4c4e-5f1a-4f55-9c7e-2b8d6f1d0a11","targetSequenceId":7,"# +
            #""startedAtMs":1793980795000,"expiresAtMs":1793980840000},{"agentId":"Not An Id","runId":"r","# +
            #""targetKind":"message","targetId":"7f2e4c4e-5f1a-4f55-9c7e-2b8d6f1d0a11","targetSequenceId":7,"# +
            #""startedAtMs":1793980795000,"expiresAtMs":1793980840000}]}"#
        )
        XCTAssertEqual(frame, .composingSet([RoomComposingLease(agentId: "senti", targetSequenceId: 7, secondsLeft: 40)]))
        XCTAssertEqual(
            RoomStreamFrame.decode(#"{"type":"control","control":"agent_composing","schema":"agent-composing:v1","status":"ok","serverNowMs":1,"ttlSeconds":45,"active":[]}"#),
            .composingSet([]), "an empty set: no one is typing"
        )
    }

    /// A frame the web would refuse shows no one, even with a lease in it: one that is not `ok` (degraded, or no
    /// status), one without the server's time, one with more than 256 leases.
    func test_a_composing_frame_the_web_refuses_shows_no_one_even_with_a_lease() {
        let senti = Self.lease()
        XCTAssertEqual(Self.frame(status: "degraded", [senti]), .composingSet([]), "degraded: no stale lease")
        XCTAssertEqual(Self.frame(status: nil, [senti]), .composingSet([]), "no status")
        XCTAssertEqual(Self.frame(serverNowMs: nil, [senti]), .composingSet([]), "no server time")
        XCTAssertEqual(Self.frame(serverNowMs: #""1793980800000""#, [senti]), .composingSet([]), "a time that is text")
        XCTAssertEqual(Self.frame(Array(repeating: senti, count: 257)), .composingSet([]), "more than 256")
        guard case .composingSet(let most)? = Self.frame(Array(repeating: senti, count: 256)) else {
            return XCTFail("256 leases decode")
        }
        XCTAssertEqual(most.count, 256)
        XCTAssertEqual(Self.frame([senti]), .composingSet([Self.senti(40)]), "and the same lease in an ok frame shows")
    }

    /// Each lease needs every field as the contract has it, as on the web; one that lacks one, or has one out of shape,
    /// is left out and the rest of the set still shows.
    func test_a_lease_missing_a_field_or_out_of_shape_is_left_out() {
        let broken = [
            Self.lease(dropping: "runId"), Self.lease(["runId": #""run 7""#]),
            Self.lease(dropping: "targetKind"), Self.lease(["targetKind": #""thread""#]),
            Self.lease(dropping: "targetId"), Self.lease(["targetId": #""7f2e4c4e""#]),
            Self.lease(dropping: "targetSequenceId"), Self.lease(["targetSequenceId": "0"]),
            Self.lease(["targetSequenceId": "7.5"]), Self.lease(["targetSequenceId": "9007199254740992"]),
            Self.lease(dropping: "startedAtMs"), Self.lease(["startedAtMs": #""soon""#]),
            Self.lease(dropping: "expiresAtMs"), Self.lease(["expiresAtMs": "null"]),
            Self.lease(["agentId": #""Not An Id""#]),
        ]
        for lease in broken {
            XCTAssertEqual(Self.frame([lease]), .composingSet([]), lease)
        }
        XCTAssertEqual(Self.frame(broken + [Self.lease(["targetKind": #""reply""#])]), .composingSet([Self.senti(40)]))
    }

    /// The time left is by the server's clock, at most 45 s whatever the frame's TTL says, and a lease at or past its
    /// expiry is left out rather than shown for a whole lease.
    func test_a_leases_time_left_is_at_most_45_seconds_and_a_spent_one_is_left_out() {
        XCTAssertEqual(Self.frame(ttl: 300, [Self.lease(["expiresAtMs": "1793981800000"])]),
                       .composingSet([Self.senti(45)]), "1,000 s ahead, a TTL of 300: 45 s")
        XCTAssertEqual(Self.frame([Self.lease(["expiresAtMs": "1793980800000"])]), .composingSet([]), "at its expiry")
        XCTAssertEqual(Self.frame([Self.lease(["expiresAtMs": "1793980790000"])]), .composingSet([]), "10 s past it")
        XCTAssertEqual(Self.frame([Self.lease(["expiresAtMs": "1793980800500.5"])]),
                       .composingSet([Self.senti(0.5005)]), "a fraction of a second left still shows")
    }

    /// The times come from the network: numbers at the limits of a whole number decode without trapping.
    func test_huge_and_negative_times_never_crash_the_decode() {
        XCTAssertEqual(Self.frame(serverNowMs: "-1", [Self.lease(["expiresAtMs": "9223372036854775807"])]),
                       .composingSet([Self.senti(45)]))
        XCTAssertEqual(Self.frame(serverNowMs: "1", [Self.lease(["expiresAtMs": "-9223372036854775808"])]),
                       .composingSet([]))
        let widest = Self.lease(["expiresAtMs": "9223372036854775807"])
        XCTAssertEqual(Self.frame(serverNowMs: "-9223372036854775808", [widest]), .composingSet([Self.senti(45)]))
        XCTAssertEqual(Self.frame(serverNowMs: "-1e308", [Self.lease(["expiresAtMs": "1e308"])]),
                       .composingSet([Self.senti(45)]))
        XCTAssertEqual(Self.frame(serverNowMs: "1e308", [Self.lease(["expiresAtMs": "-1e308"])]), .composingSet([]))
    }

    /// Senti's lease, `seconds` left.
    private static func senti(_ seconds: TimeInterval) -> RoomComposingLease {
        RoomComposingLease(agentId: "senti", targetSequenceId: 7, secondsLeft: seconds)
    }

    /// Senti's lease as the API writes it, 40 s left at the frame's time, with fields replaced or one left out.
    private static func lease(_ replacing: [String: String] = [:], dropping: String? = nil) -> String {
        let fields: [(String, String)] = [
            ("agentId", #""senti""#), ("runId", #""room_1-msg-7""#), ("targetKind", #""message""#),
            ("targetId", #""7f2e4c4e-5f1a-4f55-9c7e-2b8d6f1d0a11""#), ("targetSequenceId", "7"),
            ("startedAtMs", "1793980795000"), ("expiresAtMs", "1793980840000"),
        ]
        let kept = fields.filter { $0.0 != dropping }.map { "\"\($0.0)\":\(replacing[$0.0] ?? $0.1)" }
        return "{" + kept.joined(separator: ",") + "}"
    }

    /// An `agent-composing:v1` frame as the API writes it, at the server's time 1793980800000 unless told otherwise.
    private static func frame(status: String? = "ok", serverNowMs: String? = "1793980800000", ttl: Int = 45,
                              _ leases: [String]) -> RoomStreamFrame? {
        var fields = [#""type":"control""#, #""control":"agent_composing""#, #""schema":"agent-composing:v1""#,
                      "\"ttlSeconds\":\(ttl)"]
        if let status { fields.append("\"status\":\"\(status)\"") }
        if let serverNowMs { fields.append("\"serverNowMs\":\(serverNowMs)") }
        fields.append("\"active\":[" + leases.joined(separator: ",") + "]")
        return RoomStreamFrame.decode("{" + fields.joined(separator: ",") + "}")
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
