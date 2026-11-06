import Foundation
import SwiftUI
import XCTest
@testable import PocketUI

/// Carter, #61655 and #61679: a Working row for every agent that works on a message, Senti thinking while it prepares
/// an answer, "Seen" when the agent your message is for has read it, and a new room's opening line (#61720).
final class AgentActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func line(_ id: String, _ agent: String, _ seconds: TimeInterval, _ text: String,
                      live: Bool = true) -> RoomChatWorkLine {
        RoomChatWorkLine(id: id, actorId: agent, text: text, at: at(seconds), isLive: live)
    }

    // MARK: - Working rows

    func test_a_live_agent_shows_its_newest_step_and_every_step_in_order() throws {
        let sessions = RoomWorkSession.sessions(lines: [
            line("w2", "build-agent", 30, "Reproducing the bug", live: false),
            line("w1", "build-agent", 0, "Reading the form", live: false),
            line("w3", "build-agent", 70, "Running the tests")
        ], posts: [:])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1, "one row per agent")
        XCTAssertTrue(session.isLive)
        XCTAssertEqual(session.latestStep, "Running the tests")
        XCTAssertEqual(session.steps.map(\.text), ["Reading the form", "Reproducing the bug", "Running the tests"])
        XCTAssertNil(session.workedFor, "no time while it works")
        XCTAssertEqual(RoomWorkingRows.accessibilityLabel(session), "build-agent is working: Running the tests")
    }

    func test_its_answer_after_the_last_step_ends_the_work_and_says_how_long() throws {
        let lines = [line("w1", "build-agent", 0, "Reading the form", live: false),
                     line("w2", "build-agent", 90, "Drafting the answer")]
        let answered = try XCTUnwrap(RoomWorkSession.sessions(lines: lines, posts: ["build-agent": [at(-50), at(134), at(400)]]).first)
        XCTAssertFalse(answered.isLive, "the relay never says done for a box: its answer does")
        XCTAssertEqual(answered.workedFor, 134, "from its first step to its answer")
        XCTAssertEqual(answered.workedFor.map(RoomWorkSession.workedForLabel), "Worked for 2m 14s")
        XCTAssertEqual(answered.steps.count, 2, "the steps are kept")
        XCTAssertEqual(RoomWorkingRows.accessibilityLabel(answered), "build-agent worked for 2 minutes 14 seconds")

        let saysDone = try XCTUnwrap(RoomWorkSession.sessions(lines: lines + [
            line("w3", "build-agent", 100, "done: filed 1 ticket", live: false)
        ], posts: [:]).first)
        XCTAssertFalse(saysDone.isLive)
        XCTAssertEqual(saysDone.workedFor, 100, "its done note ends it")

        let stale = try XCTUnwrap(RoomWorkSession.sessions(lines: [
            line("w1", "build-agent", 0, "Reading", live: false), line("w2", "build-agent", 45, "Writing", live: false)
        ], posts: [:]).first)
        XCTAssertFalse(stale.isLive, "too old to be live")
        XCTAssertEqual(stale.workedFor, 45, "its last step ends it")

        let earlierPost = try XCTUnwrap(RoomWorkSession.sessions(lines: lines, posts: ["build-agent": [at(60)]]).first)
        XCTAssertTrue(earlierPost.isLive, "a post before its newest step does not end the work")
    }

    func test_several_agents_are_one_row_each_live_first_then_newest() {
        let sessions = RoomWorkSession.sessions(lines: [
            line("a1", "review-agent", 10, "Reviewing"),
            line("b1", "build-agent", 20, "Building"),
            line("c1", "docs-agent", 5, "Done: notes updated", live: false),
            line("d1", "test-agent", 30, "Testing"),
            line("e1", "Lint-Agent", 25, "Linting"),
            line("f1", "old-agent", 40, "Old", live: false)
        ], posts: [:])
        XCTAssertEqual(sessions.map(\.id), ["test-agent", "lint-agent", "build-agent", "review-agent", "old-agent", "docs-agent"])
        XCTAssertEqual(sessions.first { $0.id == "lint-agent" }?.agentId, "Lint-Agent", "named as it posts")
        XCTAssertEqual(RoomWorkSession.shownLimit, 3)
        let hidden = Array(sessions.dropFirst(RoomWorkSession.shownLimit))
        XCTAssertEqual(RoomWorkingRows.moreLabel(hidden: hidden), "+1 working · 2 done")
        XCTAssertEqual(RoomWorkingRows.moreLabel(hidden: Array(hidden.prefix(1))), "+1 working")
        XCTAssertEqual(RoomWorkingRows.moreLabel(hidden: Array(hidden.suffix(1))), "+1 done")
    }

    func test_how_long_reads_in_short_words() {
        XCTAssertEqual(RoomWorkSession.workedForLabel(9), "Worked for 9s")
        XCTAssertEqual(RoomWorkSession.workedForLabel(134), "Worked for 2m 14s")
        XCTAssertEqual(RoomWorkSession.workedForLabel(120), "Worked for 2m 0s")
        XCTAssertEqual(RoomWorkSession.workedForLabel(3_900), "Worked for 1h 5m")
        XCTAssertEqual(RoomWorkSession.workedForLabel(3_600), "Worked for 1h")
        XCTAssertEqual(RoomWorkSession.spokenDuration(61), "1 minute 1 second")
        XCTAssertEqual(RoomWorkSession.spokenDuration(3_660), "1 hour 1 minute")
    }

    /// A box's own record adds its narration while it worked on the message, between its notes; nothing from before
    /// or after, and no line twice.
    func test_a_boxs_record_fills_in_the_steps_while_it_worked() throws {
        let session = try XCTUnwrap(RoomWorkSession.sessions(lines: [
            line("w1", "build-agent", 0, "Reading the form", live: false),
            line("w2", "build-agent", 100, "Drafting the answer", live: false)
        ], posts: ["build-agent": [at(120)]]).first)
        let record = [
            RoomWorkSession.Step(id: "r0", text: "Earlier job", at: at(-30)),
            RoomWorkSession.Step(id: "r1", text: "Opened OnboardingForm.swift", at: at(20)),
            RoomWorkSession.Step(id: "r2", text: "Reading the form", at: at(1)),
            RoomWorkSession.Step(id: "r3", text: "Paste skips validate()", at: at(60)),
            RoomWorkSession.Step(id: "r4", text: "Next job", at: at(500))
        ]
        XCTAssertEqual(RoomWorkingRows.allSteps(session, record: record).map(\.text),
                       ["Reading the form", "Opened OnboardingForm.swift", "Paste skips validate()", "Drafting the answer"])
        XCTAssertEqual(RoomWorkingRows.allSteps(session, record: []).map(\.text), ["Reading the form", "Drafting the answer"])
    }

    func test_a_message_row_carries_its_working_rows() throws {
        func input(_ id: String, _ seq: Int64, _ author: String, _ seconds: TimeInterval, _ text: String,
                   work: [RoomChatWorkLine] = [], reply: String? = nil) -> RoomChatMessageInput {
            RoomChatMessageInput(id: id, sequenceId: seq, kind: .message, authorId: author, authorName: author,
                                 isHuman: author.hasPrefix("human-"), text: text, timestamp: "",
                                 replyToSequenceId: reply == nil ? nil : seq, date: at(seconds), inlineReplyId: reply, work: work)
        }
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            input("m1", 1, "human-alex", -10, "@build-agent please fix it",
                  work: [line("w1", "build-agent", 0, "Reading", live: false), line("w2", "build-agent", 30, "Fixing")]),
            input("m2", 2, "human-alex", 20, "and the tests",
                  work: [line("w3", "test-agent", 10, "Testing")])
        ], ownAuthorIds: ["human-alex"], replies: [
            input("reply-r1", 1, "build-agent", 75, "Fixed in build 320.", reply: "r1")
        ])
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        let fixed = try XCTUnwrap(rows.first { $0.id == "m1" }?.workSessions.first)
        XCTAssertFalse(fixed.isLive, "its answer, a reply in the thread, ended it")
        XCTAssertEqual(fixed.workedFor, 75)
        XCTAssertEqual(rows.first { $0.id == "m2" }?.workSessions.first?.isLive, true)
        XCTAssertTrue(rows.first { $0.id == "reply-r1" }?.workSessions.isEmpty ?? true, "a reply has none of its own")
    }

    // MARK: - Seen

    func test_your_newest_message_is_seen_once_the_agent_it_is_for_has_read_it() {
        func seen(_ text: String, viewers: [RoomChatViews.Viewer], roomAgent: String? = nil,
                  newerOwn: Bool = false) -> [String: Bool] {
            let views = RoomChatViews.make(viewedCount: viewers.count, viewers: viewers, selfViewed: false,
                                           authorActorId: "account-1", ownAccountId: "account-1", ownName: "Alex",
                                           names: [:], time: { _ in "10:42" })
            var messages = [
                RoomChatMessageInput(id: "m1", sequenceId: 1, kind: .message, authorId: "human-alex", authorName: "Alex",
                                     isHuman: true, text: text, timestamp: "", date: at(0), views: views)
            ]
            if newerOwn {
                messages.append(RoomChatMessageInput(id: "m2", sequenceId: 2, kind: .message, authorId: "human-alex",
                                                     authorName: "Alex", isHuman: true, text: "one more", timestamp: "",
                                                     date: at(10)))
            }
            let launch = roomAgent.map {
                [RoomChatMessageInput(id: "l0", sequenceId: 0, kind: .message, authorId: "respawn-orchestrator",
                                      authorName: "respawn-orchestrator", isHuman: false,
                                      text: "🚀 Minted \($0) on m: its own machine (life 0123456789ab)", timestamp: "",
                                      date: at(-60))]
            } ?? []
            let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: launch + messages,
                                                  ownAuthorIds: ["human-alex"])
            var byId: [String: Bool] = [:]
            for row in state.rows { if case .message(let message) = row { byId[message.id] = message.isSeenByAddressee } }
            return byId
        }
        let agent = RoomChatViews.Viewer(isHuman: false, actorId: "build-agent", viewedAt: nil)
        let other = RoomChatViews.Viewer(isHuman: false, actorId: "review-agent", viewedAt: nil)
        let person = RoomChatViews.Viewer(isHuman: true, actorId: "account-2", viewedAt: nil)
        let senti = RoomChatViews.Viewer(isHuman: false, actorId: "senti", viewedAt: nil)
        XCTAssertEqual(seen("@build-agent can you check?", viewers: [agent])["m1"], true, "the agent it names read it")
        XCTAssertEqual(seen("@build-agent can you check?", viewers: [other])["m1"], false, "another agent is not it")
        XCTAssertEqual(seen("@build-agent can you check?", viewers: [person])["m1"], false, "a person is the ticks' business")
        XCTAssertEqual(seen("@senti what changed?", viewers: [senti])["m1"], true, "Senti, when it records a view")
        XCTAssertEqual(seen("hi", viewers: [agent], roomAgent: "build-agent")["m1"], true, "in its own chat, the agent")
        XCTAssertEqual(seen("hi", viewers: [agent])["m1"], false, "not named, not its chat")
        XCTAssertEqual(seen("hi", viewers: [])["m1"], false, "no receipts, no Seen")
        XCTAssertEqual(seen("@build-agent check", viewers: [agent], newerOwn: true)["m1"], false, "only your newest message")
    }

    // MARK: - Senti and the room's lines

    private static func file(version: Int = 2, phrases: [String] = ["Untangling the thread", "Reading the room"],
                             intros: [String] = ["Any model, any human, one room. Go.", "Room's empty. Not for long."]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: ["version": version, "note": "x", "phrases": phrases, "roomIntros": intros])
    }

    func test_a_phrases_file_is_taken_only_when_every_line_is_fit_to_show() throws {
        let good = try XCTUnwrap(SentiPhrases.checked(Self.file(), minimumVersion: 2))
        XCTAssertEqual(good.version, 2)
        XCTAssertEqual(good.phrases, ["Untangling the thread", "Reading the room"])
        XCTAssertNotNil(SentiPhrases.checked(Self.file(version: 3), minimumVersion: 2), "a newer version")
        XCTAssertNil(SentiPhrases.checked(Self.file(version: 1), minimumVersion: 2), "older than the app's own")
        XCTAssertNil(SentiPhrases.checked(Data("not json".utf8), minimumVersion: 0))
        XCTAssertNil(SentiPhrases.checked(Data(#"{"version":2,"phrases":["a"]}"#.utf8), minimumVersion: 0), "no intros")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: []), minimumVersion: 0), "no phrases")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: [String(repeating: "a", count: 81)]), minimumVersion: 0), "81")
        XCTAssertNotNil(SentiPhrases.checked(Self.file(phrases: [String(repeating: "a", count: 80)]), minimumVersion: 0), "80")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: [""]), minimumVersion: 0), "empty")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: ["   "]), minimumVersion: 0), "blank")
        XCTAssertNil(SentiPhrases.checked(Self.file(intros: ["Two\nlines"]), minimumVersion: 0), "a line break")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: ["Bell\u{7}"]), minimumVersion: 0), "a control character")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: ["Tab\there"]), minimumVersion: 0), "a tab")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: ["Line\u{2028}sep"]), minimumVersion: 0), "a line separator")
        XCTAssertNotNil(SentiPhrases.checked(Self.file(intros: ["Claude and you walk into a room…", "👩‍💻 Humans welcome"]),
                                             minimumVersion: 0), "an ellipsis and an emoji with joiners are fine")
        XCTAssertNil(SentiPhrases.checked(Self.file(phrases: Array(repeating: "Thinking", count: 501)), minimumVersion: 0))
    }

    func test_senti_shows_one_phrase_at_a_time_and_the_next_each_turn() {
        let phrases = SentiPhrases(version: 2, phrases: ["One", "Two", "Three"], roomIntros: ["Hi"])
        XCTAssertEqual((0..<5).map { phrases.phrase(turn: $0, seed: 0) }, ["One", "Two", "Three", "One", "Two"])
        XCTAssertEqual(phrases.phrase(turn: 0, seed: 4), "Two", "the seed picks where an answer starts")
        XCTAssertEqual(phrases.phrase(turn: 1, seed: -1), "One")
        XCTAssertEqual(SentiPhrases(version: 0, phrases: [], roomIntros: []).phrase(turn: 3, seed: 1),
                       SentiPhrases.fallback.phrases[0])
        XCTAssertEqual(SentiThinkingLine.interval, 2)
        XCTAssertEqual(SentiThinkingLine.accessibilityText, "Senti is thinking")
    }

    func test_a_new_room_opens_with_one_line_the_same_all_day() {
        let intros = (1...25).map { "Line \($0)" }
        let phrases = SentiPhrases(version: 2, phrases: ["x"], roomIntros: intros)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let first = phrases.roomIntro(roomId: "room-a", on: morning, calendar: utc)
        XCTAssertTrue(intros.contains(first))
        XCTAssertEqual(phrases.roomIntro(roomId: "room-a", on: morning.addingTimeInterval(3_600), calendar: utc), first,
                       "the same room, the same day: the same line")
        let rooms = Set((0..<60).map { phrases.roomIntro(roomId: "room-\($0)", on: morning, calendar: utc) })
        XCTAssertGreaterThan(rooms.count, 10, "rooms get different lines")
        let days = Set((0..<20).map { phrases.roomIntro(roomId: "room-a", on: morning.addingTimeInterval(Double($0) * 86_400),
                                                        calendar: utc) })
        XCTAssertGreaterThan(days.count, 3, "a room's line changes from day to day")
        XCTAssertEqual(SentiPhrases.stableHash("room-a"), SentiPhrases.stableHash("room-a"))
        XCTAssertEqual(SentiPhrases.stableHash(""), 0xcbf2_9ce4_8422_2325, "FNV-1a's offset basis")
    }

    /// The pulse and Senti's avatar stop with Reduce Motion, while the room is covered, and while the app is away.
    func test_motion_runs_only_while_it_can_be_seen_and_is_wanted() {
        XCTAssertTrue(LayerMotion.runs(reduceMotion: false, roomIsCovered: false, scenePhase: .active))
        XCTAssertFalse(LayerMotion.runs(reduceMotion: true, roomIsCovered: false, scenePhase: .active))
        XCTAssertFalse(LayerMotion.runs(reduceMotion: false, roomIsCovered: true, scenePhase: .active))
        XCTAssertFalse(LayerMotion.runs(reduceMotion: false, roomIsCovered: false, scenePhase: .inactive))
        XCTAssertFalse(LayerMotion.runs(reduceMotion: false, roomIsCovered: false, scenePhase: .background))
    }
}
