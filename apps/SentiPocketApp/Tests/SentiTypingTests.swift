import Combine
import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// Ticket 40c57e0c, "Senti is typing…": Senti answers in every new room under the room's typing lease (agent id
// "senti"), and the room stream sends the room's leases as a whole set each time it changes (agent-composing:v1).
// The line shows on the set, goes on Senti's reply, on a set without it, or at the lease's own expiry, and never in a
// direct message. Frames are fed to the room as the stream would; the clock is the test's.

private struct QuietRoom: RoomTransport {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        RoomActionsPage()
    }
}

/// The test's clock, read from the room's own (Sendable) clock closure.
private final class TypingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_980_800)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current.addTimeInterval(seconds) } }
}

/// The room's sleeps: by default a long one never ends within a test; in a room whose sleeps move the clock, each
/// returns at once with the clock moved on by its length, as if that time had passed.
private enum TypingSleep {
    case realShortOnly
    case movesTheClock
}

@MainActor
final class SentiTypingTests: XCTestCase {
    private let clock = TypingClock()

    private func room(isDirect: Bool = false, sleeps: TypingSleep = .realShortOnly) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: QuietRoom(), membershipRole: "owner",
            ownAuthorIds: ["human-alex"],
            sleep: { [clock] seconds in
                switch sleeps {
                case .movesTheClock: clock.advance(seconds)
                case .realShortOnly: if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
                }
            },
            now: { [clock] in clock.now },
            isDirect: isDirect,
            onReauthenticationRequired: {}
        )
    }

    private func typing(_ agents: [(String, TimeInterval)]) -> RoomStreamFrame {
        .composingSet(agents.map { RoomComposingLease(agentId: $0.0, targetSequenceId: 7, secondsLeft: $0.1) })
    }

    private func reply(from author: String) -> RoomMessage {
        RoomMessage(id: "evt-8", sequenceId: 8, kind: .message, authorId: author, authorName: author, isHuman: false,
                    text: "Here is what I found.", timestamp: "2026-11-06T15:00:00.000000+00:00")
    }

    /// Lets the room's own tasks (its expiry timer) run.
    private func settle() async {
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// The set with Senti in it shows "Senti is typing…"; Senti's reply takes it away at once.
    func test_senti_typing_shows_on_the_frame_and_goes_on_its_reply() {
        let room = room()
        room.handle(typing([("senti", 45)]))
        XCTAssertEqual(room.state.composingAgents, ["senti"])
        XCTAssertEqual(RoomComposingWords.line(room.state.composingAgents), "Senti is typing…")
        room.handle(.message(reply(from: "senti")))
        XCTAssertEqual(room.state.composingAgents, [], "Senti's reply ends its line")
    }

    /// The server takes the lease away when Senti is done (a reply, an error, a refusal): the next set, without it,
    /// ends the line.
    func test_senti_typing_goes_when_the_set_no_longer_has_it() {
        let room = room()
        room.handle(typing([("senti", 45), ("build-agent", 45)]))
        XCTAssertEqual(room.state.composingAgents, ["build-agent", "senti"])
        room.handle(typing([("build-agent", 40)]))
        XCTAssertEqual(room.state.composingAgents, ["build-agent"], "who is not in the set has stopped")
        room.handle(typing([]))
        XCTAssertEqual(room.state.composingAgents, [])
    }

    /// With no other frame (the stream dropped the one that ended it), the line goes at the lease's own expiry: it
    /// never sticks.
    func test_senti_typing_goes_at_its_lease_expiry_with_no_other_frame() {
        let room = room()
        room.handle(typing([("senti", 30)]))
        clock.advance(29)
        room.pruneComposing()
        XCTAssertEqual(room.state.composingAgents, ["senti"], "still within its lease")
        clock.advance(2)
        room.pruneComposing()
        XCTAssertEqual(room.state.composingAgents, [], "past its lease: gone")
    }

    /// One agent's reply ends only its own line: another still typing stays.
    func test_one_agents_reply_leaves_another_agents_line() {
        let room = room()
        room.handle(typing([("senti", 45), ("build-agent", 45)]))
        room.handle(.message(reply(from: "build-agent")))
        XCTAssertEqual(room.state.composingAgents, ["senti"], "build-agent's reply leaves Senti typing")
        XCTAssertEqual(RoomComposingWords.line(room.state.composingAgents), "Senti is typing…")
    }

    /// The room's own timer takes the line away when its lease runs out, with no other frame and nothing else asking.
    func test_senti_typing_goes_by_itself_when_its_lease_runs_out() async {
        let room = room(sleeps: .movesTheClock)
        let start = clock.now
        room.handle(typing([("senti", 30)]))
        XCTAssertEqual(room.state.composingAgents, ["senti"])
        await settle()
        XCTAssertEqual(room.state.composingAgents, [], "its lease ran out")
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 30, "and not before")
    }

    /// A reply takes the soonest lease away before it expires: the timer, set for it, still goes on to the next, so
    /// Senti's line goes at its own expiry.
    func test_after_a_reply_takes_the_soonest_line_the_next_still_goes_at_its_own_expiry() async {
        let room = room(sleeps: .movesTheClock)
        room.handle(typing([("build-agent", 10), ("senti", 30)]))
        room.handle(.message(reply(from: "build-agent")))
        XCTAssertEqual(room.state.composingAgents, ["senti"])
        await settle()
        XCTAssertEqual(room.state.composingAgents, [], "Senti's lease ran out too")
    }

    /// Each set carries each lease's new expiry; the room redraws only when who is typing changes.
    func test_a_set_with_the_same_agents_redraws_nothing() {
        let room = room()
        var redraws = 0
        let watch = room.$state.dropFirst().sink { _ in redraws += 1 }
        room.handle(typing([("senti", 45)]))
        XCTAssertEqual(redraws, 1)
        clock.advance(5)
        room.handle(typing([("senti", 38)]))
        XCTAssertEqual(redraws, 1, "Senti still typing, with a new expiry: nothing to redraw")
        room.handle(typing([("senti", 38), ("build-agent", 45)]))
        XCTAssertEqual(redraws, 2, "another agent began")
        withExtendedLifetime(watch) {}
    }

    /// Senti does not answer in a direct message, so it is never shown typing there; another agent still is.
    func test_senti_is_never_shown_typing_in_a_direct_message() {
        let direct = room(isDirect: true)
        direct.handle(typing([("senti", 45)]))
        XCTAssertEqual(direct.state.composingAgents, [])
        direct.handle(.composing(agentId: "senti", targetSequenceId: 7))
        XCTAssertEqual(direct.state.composingAgents, [])
        direct.handle(typing([("build-agent", 45)]))
        XCTAssertEqual(direct.state.composingAgents, ["build-agent"])
    }

    /// A reconnect sends the room's set again: the line comes back once, never twice, and a set sent after Senti
    /// finished during the gap takes it away.
    func test_a_reconnect_sends_the_set_again_and_the_line_neither_doubles_nor_sticks() {
        let room = room()
        room.handle(typing([("senti", 45)]))
        clock.advance(5)
        room.handle(typing([("senti", 40)]))
        XCTAssertEqual(room.state.composingAgents, ["senti"], "the same set again: one line")
        XCTAssertEqual(RoomComposingWords.line(room.state.composingAgents), "Senti is typing…")
        clock.advance(5)
        room.handle(typing([]))
        XCTAssertEqual(room.state.composingAgents, [], "Senti finished during the gap")
        room.handle(typing([("senti", 45)]))
        XCTAssertEqual(room.state.composingAgents, ["senti"], "and a new answer shows again")
    }
}
