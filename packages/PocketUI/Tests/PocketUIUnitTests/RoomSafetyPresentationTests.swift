import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

/// Report, Block and the AI consent, as the room shows them (App Store guidelines 1.2 and 5.1.2(i)).
final class RoomSafetyPresentationTests: XCTestCase {
    private func input(_ id: String, seq: Int64, at seconds: TimeInterval, author: String, text: String = "hi",
                       replyTo: Int64? = nil, inline: Bool = false, kind: RoomChatMessageInput.Kind = .message)
        -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: id,
            sequenceId: seq,
            kind: kind,
            authorId: author,
            authorName: author.hasPrefix("human-") ? String(author.dropFirst("human-".count)) : author,
            isHuman: author.hasPrefix("human-"),
            text: text,
            timestamp: "",
            replyToSequenceId: replyTo,
            date: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            inlineReplyId: inline ? String(id.dropFirst("reply-".count)) : nil
        )
    }

    private func rows(_ state: RoomChatPresentationState) -> [String: RoomChatMessageRow] {
        var rows: [String: RoomChatMessageRow] = [:]
        for row in state.rows {
            if case .message(let message) = row { rows[message.id] = message }
        }
        return rows
    }

    private var messages: [RoomChatMessageInput] {
        [
            input("m1", seq: 1, at: 0, author: "human-me", text: "Can someone check the build?"),
            input("m2", seq: 2, at: 60, author: "human-sam", text: "Something unkind"),
            input("m3", seq: 3, at: 120, author: "review-agent", text: "Build 319 is green"),
            input("m4", seq: 4, at: 180, author: "human-sam", text: "More of the same")
        ]
    }

    private var replies: [RoomChatMessageInput] {
        [input("reply-r1", seq: 3, at: 150, author: "Human-Sam", text: "A reply nobody asked for", replyTo: 3, inline: true)]
    }

    func test_a_blocked_authors_messages_and_replies_each_show_as_one_line_in_place() {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-me"],
            replies: replies, blockedAuthorIds: ["HUMAN-SAM"]
        )
        let rows = rows(state)
        XCTAssertEqual(rows["m2"]?.hidesAsBlocked, true)
        XCTAssertEqual(rows["m4"]?.hidesAsBlocked, true)
        XCTAssertEqual(rows["reply-r1"]?.hidesAsBlocked, true, "a reply shown in the room hides too, whatever the case")
        XCTAssertEqual(rows["m3"]?.hidesAsBlocked, false)
        XCTAssertEqual(rows["m1"]?.hidesAsBlocked, false)
        // Nothing else about the room changes: the same rows, in the same order, with their text kept for Show.
        let unblocked = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-me"], replies: replies
        )
        XCTAssertEqual(state.rows.map(\.id), unblocked.rows.map(\.id))
        XCTAssertEqual(rows["m2"]?.text, "Something unkind")
    }

    func test_show_reveals_that_one_message_and_no_other() {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-me"], replies: replies,
            blockedAuthorIds: ["human-sam"], revealedBlocked: [RoomBlocking.revealKey(message: "m2")]
        )
        let rows = rows(state)
        XCTAssertEqual(rows["m2"]?.hidesAsBlocked, false, "shown, as asked")
        XCTAssertEqual(rows["m2"]?.isAuthorBlocked, true, "still from someone you blocked")
        XCTAssertEqual(rows["m4"]?.hidesAsBlocked, true, "the next one from them stays hidden")
        XCTAssertEqual(rows["reply-r1"]?.hidesAsBlocked, true)

        let reply = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, replies: replies,
            blockedAuthorIds: ["human-sam"], revealedBlocked: [RoomBlocking.revealKey(reply: "r1")]
        )
        XCTAssertEqual(self.rows(reply)["reply-r1"]?.hidesAsBlocked, false)
        XCTAssertEqual(self.rows(reply)["m2"]?.hidesAsBlocked, true)
    }

    func test_your_own_messages_are_never_hidden() {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-me"],
            blockedAuthorIds: ["human-me"]
        )
        XCTAssertEqual(rows(state)["m1"]?.hidesAsBlocked, false)
        XCTAssertEqual(rows(state)["m1"]?.isAuthorBlocked, false)
    }

    func test_a_replys_quote_never_shows_a_hidden_messages_words() {
        let withReply = messages + [input("m5", seq: 5, at: 240, author: "review-agent", text: "Answering", replyTo: 2)]
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: withReply,
                                              blockedAuthorIds: ["human-sam"])
        XCTAssertEqual(rows(state)["m5"]?.replyContext, RoomBlocking.hiddenLine)
        let shown = RoomChatPresentationState(sessionId: "room", title: "Room", messages: withReply,
                                              blockedAuthorIds: ["human-sam"],
                                              revealedBlocked: [RoomBlocking.revealKey(message: "m2")])
        XCTAssertEqual(rows(shown)["m5"]?.replyContext?.contains("Something unkind"), true)
    }

    func test_replies_in_an_open_thread_from_a_blocked_author_show_as_one_line() {
        let thread = RoomChatThreadInput(sequenceId: 3, replies: [
            RoomChatReplyRow(id: "r1", authorName: "sam", isHuman: true, isOwn: false, text: "No", date: nil,
                             isEdited: false, authorId: "human-sam"),
            RoomChatReplyRow(id: "r2", authorName: "review-agent", isHuman: false, isOwn: false, text: "Yes", date: nil,
                             isEdited: false, authorId: "review-agent")
        ])
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, thread: thread,
                                              blockedAuthorIds: ["human-sam"])
        let replies = Dictionary(uniqueKeysWithValues: (state.thread?.replies ?? []).map { ($0.id, $0) })
        XCTAssertEqual(replies["r1"]?.hidesAsBlocked, true)
        XCTAssertEqual(replies["r2"]?.hidesAsBlocked, false)

        let parent = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                               thread: RoomChatThreadInput(sequenceId: 2, replies: []),
                                               blockedAuthorIds: ["human-sam"])
        XCTAssertEqual(parent.thread?.parent.hidesAsBlocked, true, "the message a thread answers hides too")

        let shown = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, thread: thread,
                                              blockedAuthorIds: ["human-sam"],
                                              revealedBlocked: [RoomBlocking.revealKey(reply: "r1")])
        XCTAssertEqual(shown.thread?.replies.first { $0.id == "r1" }?.hidesAsBlocked, false)
    }

    func test_someone_elses_message_or_reply_offers_report_and_block_and_your_own_does_not() {
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                              ownAuthorIds: ["human-me"], replies: replies)
        let rows = rows(state)
        func options(_ id: String, canReport: Bool = true, canBlock: Bool = true) -> [RoomRowOption] {
            rows[id]!.options(canReply: true, canReact: true, canPin: true, isPinned: false, pinsFull: false,
                              canReport: canReport, canBlock: canBlock)
        }
        let others = options("m2")
        XCTAssertEqual(others.first { $0.kind == .report }?.title, "Report…")
        XCTAssertEqual(others.first { $0.kind == .report }?.intent,
                       .openReport(RoomReportTarget(sequenceId: 2, authorId: "human-sam", authorName: "sam")))
        XCTAssertEqual(others.first { $0.kind == .block }?.title, "Block sam")
        XCTAssertEqual(others.first { $0.kind == .block }?.isDestructive, true)
        XCTAssertEqual(Array(others.suffix(2).map(\.kind)), [.report, .block], "at the end of the menu")

        XCTAssertEqual(options("m3").first { $0.kind == .block }?.title, "Block review-agent", "an agent can be blocked")
        XCTAssertEqual(options("reply-r1").first { $0.kind == .report }?.intent,
                       .openReport(RoomReportTarget(sequenceId: 3, replyId: "r1", authorId: "Human-Sam", authorName: "Human-Sam")),
                       "a reply shown in the room is reported as itself")
        XCTAssertFalse(options("m1").contains { $0.kind == .report || $0.kind == .block }, "never your own")
        XCTAssertFalse(options("m2", canReport: false, canBlock: false).contains { $0.kind == .report || $0.kind == .block })

        let blocked = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                                blockedAuthorIds: ["human-sam"],
                                                revealedBlocked: [RoomBlocking.revealKey(message: "m2")])
        let shownOptions = self.rows(blocked)["m2"]!.options(canReply: true, canReact: true, canPin: true, isPinned: false,
                                                              pinsFull: false, canReport: true, canBlock: true)
        XCTAssertFalse(shownOptions.contains { $0.kind == .block }, "someone already blocked is not offered again")
        XCTAssertTrue(shownOptions.contains { $0.kind == .report })

        let checkpoint = RoomChatPresentationState(sessionId: "room", title: "Room",
                                                   messages: [input("c1", seq: 9, at: 0, author: "senti", kind: .checkpoint)])
        XCTAssertNil(self.rows(checkpoint)["c1"]?.reportTarget, "what the room itself posts is not reported")

        // The server's own posts are never offered to block.
        let server = RoomChatPresentationState(sessionId: "room", title: "Room",
                                               messages: [input("s1", seq: 10, at: 0, author: "senti", text: "Room renamed")])
        let serverOptions = self.rows(server)["s1"]!.options(canReply: true, canReact: true, canPin: true, isPinned: false,
                                                              pinsFull: false, canReport: true, canBlock: true)
        XCTAssertFalse(serverOptions.contains { $0.kind == .block }, "no Block senti")

        // A row the server takes no report on (an upload notice, a relayed line) offers Block but not Report.
        var relayed = input("r1", seq: 11, at: 0, author: "human-sam", text: "Attachment uploaded")
        relayed.isReportable = false
        let relayedRow = self.rows(RoomChatPresentationState(sessionId: "room", title: "Room", messages: [relayed]))["r1"]!
        let relayedOptions = relayedRow.options(canReply: true, canReact: true, canPin: true, isPinned: false,
                                                pinsFull: false, canReport: true, canBlock: true)
        XCTAssertNil(relayedRow.reportTarget)
        XCTAssertFalse(relayedOptions.contains { $0.kind == .report })
        XCTAssertTrue(relayedOptions.contains { $0.kind == .block })

        let reply = RoomChatReplyRow(id: "r9", authorName: "sam", isHuman: true, isOwn: false, text: "x", date: nil,
                                     isEdited: false, authorId: "human-sam")
        XCTAssertEqual(reply.reportTarget(inThread: 4),
                       RoomReportTarget(sequenceId: 4, replyId: "r9", authorId: "human-sam", authorName: "sam"))
        let own = RoomChatReplyRow(id: "r8", authorName: "me", isHuman: true, isOwn: true, text: "x", date: nil,
                                   isEdited: false, authorId: "human-me")
        XCTAssertNil(own.reportTarget(inThread: 4))
    }

    func test_a_reports_note_fits_the_apis_500_and_a_reply_is_named_in_it() {
        let message = RoomReportTarget(sequenceId: 7, authorId: "human-sam", authorName: "sam")
        XCTAssertNil(message.apiNote("   "), "no note is null")
        XCTAssertEqual(message.apiNote("  spam links \n"), "spam links")
        XCTAssertEqual(message.apiNote("a\u{0}b"), "ab", "the API refuses NUL in a note")
        XCTAssertEqual(message.noteLimit, 500)
        let long = String(repeating: "é", count: 600)
        XCTAssertEqual(message.apiNote(long)?.unicodeScalars.count, 500)

        // A reply is reported under its own id; its note is only what was written.
        let reply = RoomReportTarget(sequenceId: 7, replyId: "3f0c2a8e-2c4d-4c38-9e0f-2b1f5f1d7a10", authorId: "a", authorName: "a")
        XCTAssertNil(reply.apiNote(""))
        XCTAssertEqual(reply.apiNote("rude"), "rude")
        XCTAssertEqual(reply.noteLimit, 500)
        XCTAssertEqual(reply.apiNote(long)?.unicodeScalars.count, 500)

        // Cut by code points, never inside a character: a family emoji is 7 of them.
        XCTAssertEqual(RoomReport.clamped("ab👨‍👩‍👧‍👦", to: 8), "ab")
        XCTAssertEqual(RoomReport.clamped("ab👨‍👩‍👧‍👦", to: 9), "ab👨‍👩‍👧‍👦")
    }

    func test_the_report_reasons_are_the_apis() {
        XCTAssertEqual(RoomReportReason.allCases.map(\.rawValue),
                       ["spam", "harassment", "hate", "sexual", "violence", "self_harm", "other"])
    }

    func test_the_ai_consent_notice_says_what_is_shared_and_with_whom() {
        let notice = AIConsentText.notice
        for shared in ["messages", "replies", "files", "tickets", "what you say on calls"] {
            XCTAssertTrue(notice.contains(shared), "says it shares \(shared)")
        }
        for whom in ["AI agents in that room", "Senti's own AI features", "room titles", "progress scoring",
                     "finished speaking on a call", "third-party providers"] {
            XCTAssertTrue(notice.contains(whom), "says \(whom)")
        }
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, asksAIConsent: true,
                                              consentRequested: true)
        XCTAssertTrue(state.asksAIConsent)
        XCTAssertTrue(state.consentRequested)
    }

    func test_every_write_to_the_room_waits_for_the_ok_and_reading_never_does() {
        let writes: [RoomChatIntent] = [
            .sendMessage(text: "x"), .retrySend(clientId: "c"), .react(sequenceId: 1, type: "like"),
            .sendReply(sequenceId: 1, text: "x"), .sendReplyToReply(sequenceId: 1, replyId: "r", text: "x"),
            .reactToReply(sequenceId: 1, replyId: "r", type: "ack"),
            .setEmojiReaction(sequenceId: 1, replyId: nil, emoji: "🎉", isOn: true),
            .setPinned(sequenceId: 1, isPinned: true), .renameRoom(title: "x"),
            .editMessage(sequenceId: 1, text: "x"), .editReply(sequenceId: 1, replyId: "r", text: "x")
        ]
        XCTAssertTrue(writes.allSatisfy(\.isRoomWrite))
        let others: [RoomChatIntent] = [
            .loadOlder, .openThread(sequenceId: 1), .readAloud(id: "a", text: "b"), .messageOnScreen(id: "a", isOnScreen: true),
            .openReport(RoomReportTarget(sequenceId: 1, authorId: "human-sam", authorName: "sam")),
            .sendReport(reason: .spam, note: ""), .block(RoomBlockTarget(actorId: "human-sam", name: "sam")),
            .revealBlocked(key: "msg:1"), .allowAIAgents, .declineAIAgents, .discardSend(clientId: "c"),
            .loadOlderReplies(sequenceId: 1), .loadLaterReplies(sequenceId: 1)
        ]
        XCTAssertFalse(others.contains(where: \.isRoomWrite))
    }

    func test_blocking_says_plainly_what_it_does_and_does_not() {
        let agent = RoomBlocking.confirmation(for: RoomBlockTarget(actorId: "Build-Agent", name: "Build Agent"))
        XCTAssertTrue(agent.contains("blocks this one id, build-agent"), "an agent is blocked by its id")
        XCTAssertTrue(agent.contains("the same agent under another id isn't blocked"))
        XCTAssertFalse(agent.contains("their agents' messages"))
        let person = RoomBlocking.confirmation(for: RoomBlockTarget(actorId: "human-sam", name: "Sam"))
        XCTAssertTrue(person.contains("Blocking a person doesn't hide their agents' messages"))
        XCTAssertFalse(person.contains("another id"))
        for said in [agent, person] {
            // The server doesn't ring you for someone you blocked (sentinelayer-api #1118).
            XCTAssertTrue(said.contains("Their calls don't ring your phone and may show as missed"))
            XCTAssertFalse(said.contains("still ring"))
            XCTAssertTrue(said.contains("Waiting on you still shows their questions"))
            XCTAssertTrue(said.contains("They aren't told"))
        }
        // Blocked people says both, for anyone on the list.
        XCTAssertTrue(RoomBlocking.byId.contains("Blocking a person doesn't hide their agents' messages"))
        XCTAssertTrue(RoomBlocking.byId.contains("blocking one agent id doesn't block the same agent under another id"))
    }

    func test_a_reports_outcome_is_said_aloud_and_only_its_outcome() {
        XCTAssertEqual(RoomReport.announcement(for: .sent), RoomReport.thanks)
        XCTAssertEqual(RoomReport.announcement(for: .failed), RoomReport.notSent)
        XCTAssertEqual(RoomReport.announcement(for: .refused), RoomReport.refused)
        XCTAssertNil(RoomReport.announcement(for: .choosing))
        XCTAssertNil(RoomReport.announcement(for: .sending))
        XCTAssertGreaterThanOrEqual(RoomBlocking.minimumTapSize, 44, "Show takes a 44 pt tap")
    }

    /// Block from someone's card (master's member card): with the newest of their messages in the list, never by their
    /// id alone, and never for yourself, the server or someone already blocked.
    func test_block_from_a_profile_card_names_their_newest_message_and_never_the_server_or_someone_already_blocked() {
        let own: Set<String> = ["human-me"]
        XCTAssertTrue(RoomMemberBlock.offers(senderId: "human-sam", ownAuthorIds: own, alreadyBlocked: false))
        XCTAssertFalse(RoomMemberBlock.offers(senderId: "human-sam", ownAuthorIds: own, alreadyBlocked: true),
                       "already blocked: not offered again")
        XCTAssertFalse(RoomMemberBlock.offers(senderId: "senti", ownAuthorIds: own, alreadyBlocked: false),
                       "never the server's own posts")
        XCTAssertFalse(RoomMemberBlock.offers(senderId: "human-me", ownAuthorIds: own, alreadyBlocked: false),
                       "never yourself")
        let listed = RoomMemberMessagesState(rows: [
            RoomMemberMessageRow(sequenceId: 4, text: "More of the same", date: nil),
            RoomMemberMessageRow(sequenceId: 2, text: "Something unkind", date: nil)
        ])
        var blocked: Int64?
        listed.blockAction { blocked = $0 }?()
        XCTAssertEqual(blocked, 4, "the newest of theirs in the list")
        XCTAssertNil(RoomMemberMessagesState().blockAction { _ in }, "no message listed yet: no Block by id alone")
        XCTAssertNil(RoomMemberMessagesState(rows: [RoomMemberMessageRow(sequenceId: 2, text: "x", date: nil)],
                                             isBlocked: true).blockAction { _ in },
                     "someone already blocked: their messages are not listed, and Block is not offered")
    }

    // MARK: - Direct messages and Activity

    private func directList() throws -> SessionListPresentationState {
        let page = try JSONDecoder().decode(SessionListPage.self, from: Data("""
        {"sessions":[
          {"sessionId":"room-1","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"Design review","agentCount":2,"eventCount":9,"totalCostUsd":0,"kind":"room"},
          {"sessionId":"dm-sam","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"dm","agentCount":0,"eventCount":2,"totalCostUsd":0,"kind":"direct",
           "counterpart":{"senderId":"Human-Sam","kind":"human","displayName":"Sam"},"originRoomId":"room-1"},
          {"sessionId":"dm-ada","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"dm","agentCount":0,"eventCount":2,"totalCostUsd":0,"kind":"direct",
           "counterpart":{"senderId":"human-ada","kind":"human","displayName":"Ada"},"originRoomId":"room-1"}
        ],"count":3,"include_archived":false,"next_cursor":null,"has_more":false}
        """.utf8))
        return SessionListPresentationState(page: page, provenance: .fixture)
    }

    /// Someone you blocked can't reach you in a direct message: theirs is not listed (the room list and the side panel),
    /// and nothing else is hidden.
    func test_a_direct_message_with_someone_you_blocked_is_not_listed() throws {
        let list = try directList()
        let shown = list.withoutDirectMessages(from: ["human-sam"])
        XCTAssertEqual(shown.rows.map(\.sessionId), ["room-1", "dm-ada"], "by id, whatever its case")
        XCTAssertEqual(shown.resultCount, 2)
        XCTAssertEqual(list.withoutDirectMessages(from: []), list, "nobody blocked: the list as it is")
        XCTAssertEqual(list.withoutDirectMessages(from: ["human-zed"]).rows.count, 3)
    }

    /// Room info's Activity shows a blocked person's messages and replies as one line, as the room does; everyone else's
    /// as they are.
    func test_activity_shows_a_blocked_persons_messages_and_replies_as_one_line() throws {
        let events = try JSONDecoder().decode(SessionEventForwardPage.self, from: Data("""
        {"events":[{"id":"ev-1","event":"session_message","agent":{"displayName":"sam"},
        "agentId":"Human-Sam","agentModel":"app","payload":{"text":"Something unkind"},
        "ts":"2026-11-06T10:35:00Z","timestamp":"2026-11-06T10:35:00Z","cursor":"c1",
        "sequenceId":2,"sessionId":"room-1","source":"app"},
        {"id":"ev-2","event":"session_message","agent":{"displayName":"ada"},
        "agentId":"human-ada","agentModel":"app","payload":{"text":"Build 319 is green"},
        "ts":"2026-11-06T10:36:00Z","timestamp":"2026-11-06T10:36:00Z","cursor":"c2",
        "sequenceId":3,"sessionId":"room-1","source":"app"}]}
        """.utf8))
        let actions = try JSONDecoder().decode(SessionActionPage.self, from: Data("""
        {"sessionId":"room-1","count":2,"projection":{},"actions":[{"id":"act-1",
        "sessionId":"room-1","targetSequenceId":3,"targetCursor":null,"targetActionId":null,
        "actionType":"reply","actorKind":"human","actorId":"human-sam","actorUserId":null,"actorRole":"member",
        "note":"More of the same","metadata":{},"idempotencyKey":"idem-1","createdAt":"2026-11-06T10:37:00Z"},
        {"id":"act-2","sessionId":"room-1","targetSequenceId":2,"targetCursor":null,"targetActionId":null,
        "actionType":"reply","actorKind":"human","actorId":"human-ada","actorUserId":null,"actorRole":"member",
        "note":"Thanks","metadata":{},"idempotencyKey":"idem-2","createdAt":"2026-11-06T10:38:00Z"}]}
        """.utf8))
        let state = SessionActivityPresentationState(sessionId: "room-1", eventPage: events, actionPage: actions,
                                                     provenance: .fixture, blockedAuthorIds: ["human-sam"])
        XCTAssertEqual(state.events.map(\.text), [RoomBlocking.hiddenLine, "Build 319 is green"])
        XCTAssertEqual(state.actions.map(\.note), [RoomBlocking.hiddenLine, "Thanks"])
        let unblocked = SessionActivityPresentationState(sessionId: "room-1", eventPage: events, actionPage: actions,
                                                         provenance: .fixture)
        XCTAssertEqual(unblocked.events.first?.text, "Something unkind", "nobody blocked: as it is")
    }

    func test_block_names_the_post_it_was_chosen_on() {
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                              ownAuthorIds: ["human-me"], replies: replies)
        let rows = rows(state)
        XCTAssertEqual(rows["m2"]?.blockTarget,
                       RoomBlockTarget(actorId: "human-sam", name: "sam", sequenceId: 2, replyId: nil))
        XCTAssertEqual(rows["reply-r1"]?.blockTarget,
                       RoomBlockTarget(actorId: "Human-Sam", name: "Human-Sam", sequenceId: 3, replyId: "r1"),
                       "a reply shown in the room names the reply, on its message")
        let reply = RoomChatReplyRow(id: "r9", authorName: "sam", isHuman: true, isOwn: false, text: "x", date: nil,
                                     isEdited: false, authorId: "human-sam")
        let fromThread = reply.reportTarget(inThread: 4).map { RoomBlockTarget($0) }
        XCTAssertEqual(fromThread, RoomBlockTarget(actorId: "human-sam", name: "sam", sequenceId: 4, replyId: "r9"))
        let afterReport = RoomBlockTarget(RoomReportTarget(sequenceId: 2, authorId: "human-sam", authorName: "sam"),
                                          name: "Sam")
        XCTAssertEqual(afterReport, RoomBlockTarget(actorId: "human-sam", name: "Sam", sequenceId: 2))
        XCTAssertNil(RoomBlockTarget(actorId: "human-sam", name: "sam").sequenceId, "from Blocked people: no post")
    }

    func test_your_posts_under_the_id_you_had_before_are_never_reported_or_blocked() {
        let old = [input("o1", seq: 5, at: 300, author: "human-sam-rivera", text: "From before the change"),
                   input("reply-o2", seq: 2, at: 330, author: "human-sam-rivera", text: "An old reply", replyTo: 2,
                         inline: true)]
        let thread = RoomChatThreadInput(sequenceId: 2, replies: [
            RoomChatReplyRow(id: "o3", authorName: "sam-rivera", isHuman: true, isOwn: false, text: "Old", date: nil,
                             isEdited: false, authorId: "Human-Sam-Rivera")
        ])
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages + [old[0]], ownAuthorIds: ["human-g.0a1b"],
            thread: thread, replies: [old[1]], formerOwnAuthorIds: ["human-sam-rivera"], canReport: true, canBlock: true
        )
        let rows = rows(state)
        for id in ["o1", "reply-o2"] {
            let row = rows[id]!
            let options = row.options(canReply: true, canReact: true, canPin: true, isPinned: false, pinsFull: false,
                                      canReport: true, canBlock: true)
            XCTAssertFalse(options.contains { $0.kind == .report || $0.kind == .block }, "\(id): never yourself")
            XCTAssertNil(row.reportTarget)
            XCTAssertFalse(row.isBlockable)
            XCTAssertFalse(row.isOwn, "\(id) shows as it did: a GitHub login of that name may have posted there too")
        }
        XCTAssertNil(state.thread?.replies.first { $0.id == "o3" }?.reportTarget(inThread: 2), "nor in a thread")
        let someoneElse = rows["m2"]!.options(canReply: true, canReact: true, canPin: true, isPinned: false,
                                              pinsFull: false, canReport: true, canBlock: true)
        XCTAssertTrue(someoneElse.contains { $0.kind == .report } && someoneElse.contains { $0.kind == .block })
    }

    func test_nothing_to_report_or_block_beside_an_access_failure() {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: messages, failure: .accessDenied, canReport: true, canBlock: true,
            report: RoomReportState(target: RoomReportTarget(sequenceId: 2, authorId: "human-sam", authorName: "sam"))
        )
        XCTAssertFalse(state.canReport)
        XCTAssertFalse(state.canBlock)
        XCTAssertNil(state.report)
    }
}
