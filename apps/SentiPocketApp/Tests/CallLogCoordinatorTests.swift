import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedCalls: CallLogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<SentiCallLogPage, Error>]
    private(set) var cursors: [String?] = []

    init(_ pages: [Result<SentiCallLogPage, Error>]) { self.pages = pages }

    func calls(limit: Int, cursor: String?) async throws -> SentiCallLogPage {
        let next: Result<SentiCallLogPage, Error> = lock.withLock {
            cursors.append(cursor)
            return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .success(SentiCallLogPage(calls: [])))
        }
        return try next.get()
    }
}

/// Carter (10-30): "there should be ... past ones like when I called yall and the details I asked for".
@MainActor
final class CallLogCoordinatorTests: XCTestCase {
    private func voiceRoom(_ id: String, with agents: [String] = ["pocket-forge"], meeting: Bool = false,
                           status: String = "ended") -> SentiCall {
        SentiCall(kind: .voiceRoom, id: id, sessionId: "room-1", roomTitle: "Senti-expansion-proj", status: status,
                  startedAt: "2026-10-30T17:38:19Z", with: agents, isMeeting: meeting, durationText: "2 min 40 s",
                  turns: 7, timingsText: "Timings: you stop → answer heard 2.1 s",
                  summaries: [SentiCall.Summary(author: "pocket-forge", text: "Next build rings first.")],
                  startSequenceId: 55589, endSequenceId: 55598)
    }

    func test_calls_read_as_who_you_talked_with_how_long_and_what_was_decided() async {
        let missed = SentiCall(kind: .ring, id: "r-1", sessionId: "room-2", roomTitle: "Lab", status: "missed",
                               startedAt: "2026-10-30T12:00:00Z", direction: "incoming", callerName: "claude-warden",
                               reason: "Review is ready")
        let outgoing = SentiCall(kind: .ring, id: "r-2", sessionId: "room-2", status: "answered",
                                 startedAt: "2026-10-30T11:00:00Z", direction: "outgoing", calleeName: "mrrCarter")
        let log = CallLogCoordinator(transport: ScriptedCalls([.success(SentiCallLogPage(calls: [
            voiceRoom("v1"), voiceRoom("v2", with: ["pocket-forge", "claude-warden"]),
            voiceRoom("v3", with: [], meeting: true, status: "ongoing"), missed, outgoing
        ]))]))
        await log.refresh()
        let rows = log.state.rows
        XCTAssertEqual(rows.map(\.title), ["pocket-forge", "pocket-forge and claude-warden", "Meeting",
                                           "claude-warden called you", "You called mrrCarter"])
        XCTAssertEqual(rows[0].detail, "2 min 40 s · 7 turns")
        XCTAssertEqual(rows[0].summaries.first?.text, "Next build rings first.")
        XCTAssertEqual(rows[2].detail, "In progress · 2 min 40 s · 7 turns")
        XCTAssertTrue(rows[2].isOngoing)
        XCTAssertTrue(rows[3].isMissed)
        XCTAssertEqual(rows[3].direction, .incoming)
        XCTAssertEqual(rows[3].reason, "Review is ready")
        XCTAssertFalse(rows[4].isMissed)
        XCTAssertEqual(log.readable("v1")?.markdown, "pocket-forge: Next build rings first.")
    }

    /// Warden (#272): the room folds a closed call onto its start, so the link must land there, on a row that exists.
    func test_a_call_opens_in_its_room_at_its_card_which_the_room_shows() async {
        let log = CallLogCoordinator(transport: ScriptedCalls([.success(SentiCallLogPage(calls: [voiceRoom("v1")]))]))
        await log.refresh()
        let link = log.link(for: "v1")
        XCTAssertEqual(link?.sessionId, "room-1")
        XCTAssertEqual(link?.messageSequence, 55589)

        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let at = Date()
        func input(_ seq: Int64, _ author: String, _ text: String, _ seconds: Double) -> RoomChatMessageInput {
            RoomChatMessageInput(id: "m\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                                 isHuman: author.hasPrefix("human-"), text: text, timestamp: "",
                                 date: at.addingTimeInterval(seconds))
        }
        let folded = VoiceCallCard.fold([
            input(55589, "human-mrrcarter", start, 0),
            input(55590, "pocket-forge", "Hi Carter, forge here.", 10),
            input(55598, "human-mrrcarter", "📞 Voice room with pocket-forge ended · 2 min 40 s · 7 turns.", 160)
        ])
        let rows = Set(folded.kept.map(\.sequenceId))
        XCTAssertTrue(rows.contains(link?.messageSequence ?? -1), "the link lands on the card's row")
        XCTAssertFalse(rows.contains(55598), "the end folds into the card and has no row of its own")
    }

    /// Warden (#272): opening still works after a refresh replaced the list under an open detail; the model name never
    /// shows.
    func test_a_call_stays_openable_after_a_refresh_and_its_words_hide_the_model_name() async {
        var call = voiceRoom("v1")
        call = SentiCall(kind: call.kind, id: call.id, sessionId: call.sessionId, roomTitle: "Jev lab", status: call.status,
                         startedAt: call.startedAt, with: call.with, summaries: [SentiCall.Summary(author: "pocket-forge",
                         text: "Route it through Jev first.")], startSequenceId: 10)
        let log = CallLogCoordinator(transport: ScriptedCalls([
            .success(SentiCallLogPage(calls: [call])),
            .success(SentiCallLogPage(calls: []))
        ]))
        await log.refresh()
        XCTAssertEqual(log.state.rows.first?.roomTitle, "the signal layer lab")
        XCTAssertEqual(log.state.rows.first?.summaries.first?.text, "Route it through the signal layer first.")
        await log.refresh()
        XCTAssertNotNil(log.link(for: "v1"), "a detail still open can still open its call")
    }

    func test_earlier_calls_page_in_without_repeats_and_an_older_server_says_so() async {
        let transport = ScriptedCalls([
            .success(SentiCallLogPage(calls: [voiceRoom("v1")], nextCursor: "c-2")),
            .success(SentiCallLogPage(calls: [voiceRoom("v1"), voiceRoom("v0")]))
        ])
        let log = CallLogCoordinator(transport: transport)
        await log.refresh()
        XCTAssertTrue(log.state.canLoadMore)
        await log.loadMore()
        XCTAssertEqual(log.state.rows.map(\.id), ["v1", "v0"])
        XCTAssertFalse(log.state.canLoadMore)
        XCTAssertEqual(transport.cursors, [nil, "c-2"])

        let older = CallLogCoordinator(transport: ScriptedCalls([.failure(SessionTransportError.accessDenied)]))
        await older.refresh()
        XCTAssertFalse(older.state.isAvailable)
    }
}
