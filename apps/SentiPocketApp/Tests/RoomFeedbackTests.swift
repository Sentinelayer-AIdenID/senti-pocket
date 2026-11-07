import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// A quiet room: one message of history, nothing streamed unless the test hands a frame in.
private final class QuietRoom: RoomTransport, @unchecked Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? [
            RoomMessage(id: "evt-1", sequenceId: 1, kind: .message, authorId: "review-agent", authorName: "review-agent",
                        isHuman: false, text: "history: @mrrcarter from yesterday", timestamp: "2026-10-28T20:00:00Z")
        ] : [])
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { RoomActionsPage() }
}

private struct AcceptingSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

/// Accepts every send and counts them.
private final class CountingSender: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var sends: Int { lock.withLock { count } }
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { count += 1 }
    }
}

@MainActor
final class RoomFeedbackTests: XCTestCase {
    private func live(_ seq: Int64, from author: String, _ text: String) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: text, timestamp: "2026-10-30T01:00:00Z")
    }

    func test_a_burst_sounds_once_and_a_mention_waits_longer_than_a_message() {
        let t = Date(timeIntervalSince1970: 1_793_300_000)
        XCTAssertTrue(RoomFeedback.shouldPlay(.received, last: nil, now: t))
        XCTAssertFalse(RoomFeedback.shouldPlay(.received, last: t, now: t.addingTimeInterval(1)))
        XCTAssertTrue(RoomFeedback.shouldPlay(.received, last: t, now: t.addingTimeInterval(1.6)))
        XCTAssertFalse(RoomFeedback.shouldPlay(.mentioned, last: t, now: t.addingTimeInterval(2)))
        XCTAssertTrue(RoomFeedback.shouldPlay(.sent, last: t, now: t.addingTimeInterval(0.3)))
    }

    /// Carter: a subtle sound when a message arrives while you're in the room, a different one when you send, and
    /// vibration even on silent.
    func test_the_room_on_screen_sounds_for_arrivals_mentions_and_sends_but_not_for_history_or_your_own_echo() async {
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: QuietRoom(),
            sender: AcceptingSender(),
            ownAuthorIds: ["human-mrrcarter"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        var events: [RoomFeedbackEvent] = []
        coordinator.onFeedback = { events.append($0) }
        coordinator.resume()
        for _ in 0..<500 where coordinator.state.isLoadingInitial { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(events, [], "history makes no sound, even a mention")

        coordinator.handle(.message(live(2, from: "pocket-forge", "Build 10 is up")))
        XCTAssertEqual(events, [.received])
        coordinator.handle(.message(live(3, from: "claude-warden", "@mrrcarter one question")))
        XCTAssertEqual(events, [.received, .mentioned])
        coordinator.handle(.message(live(4, from: "human-mrrcarter", "my own echo")))
        XCTAssertEqual(events, [.received, .mentioned], "your own message makes no arrival sound")

        coordinator.send(.sendMessage(text: "Ship it"))
        for _ in 0..<500 where !events.contains(.sent) { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(events.last, .sent)
        coordinator.pause()
    }

    /// A voice room speaks instead: while one is on, its screen mutes the room (`feedbackMuted`, ticket 02a80e6f: the
    /// screen tells the coordinator, so the closure it sets holds nothing of the screen), and no arrival, mention or
    /// send makes a sound; once it ends, the room sounds again.
    ///
    /// Mutant it must catch: the mute ignored for arrivals, or for a send.
    func test_a_room_in_a_voice_call_makes_no_sound_and_sounds_again_once_it_ends() async {
        let sender = CountingSender()
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: QuietRoom(),
            sender: sender,
            ownAuthorIds: ["human-mrrcarter"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        var events: [RoomFeedbackEvent] = []
        coordinator.onFeedback = { events.append($0) }
        coordinator.resume()
        for _ in 0..<500 where coordinator.state.isLoadingInitial { try? await Task.sleep(nanoseconds: 2_000_000) }

        coordinator.feedbackMuted = true
        coordinator.handle(.message(live(2, from: "pocket-forge", "Build 10 is up")))
        coordinator.handle(.message(live(3, from: "claude-warden", "@mrrcarter one question")))
        XCTAssertEqual(events, [], "an arrival and a mention make no sound during a voice room")
        coordinator.send(.sendMessage(text: "Ship it"))
        for _ in 0..<500 where sender.sends == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sender.sends, 1)
        XCTAssertEqual(events, [], "nor does a send")

        coordinator.feedbackMuted = false
        coordinator.handle(.message(live(4, from: "pocket-forge", "Build 11 is up")))
        XCTAssertEqual(events, [.received], "the call over, the room sounds again")
        coordinator.pause()
    }
}

final class PushRouteTests: XCTestCase {
    func test_a_tapped_notification_opens_its_room_at_the_message_or_reply() {
        let room = "11111111-2222-4333-8444-555555555555"
        let reply = "41bd8285-0df2-4b1c-8e6f-5e811ca737e7"
        let link = PushRoute.link(from: ["sessionId": room, "sequenceId": NSNumber(value: 54_918), "replyId": reply.uppercased()])
        XCTAssertEqual(link, SentiLink(sessionId: room, messageSequence: 54_918, replyId: reply))
        XCTAssertEqual(PushRoute.link(from: ["sessionId": room]), SentiLink(sessionId: room))
        XCTAssertEqual(PushRoute.link(from: ["sessionId": room, "sequenceId": "0", "replyId": "not-a-uuid"]), SentiLink(sessionId: room))
        XCTAssertNil(PushRoute.link(from: ["sessionId": "../../evil"]), "a push is held to the rules a link is")
        XCTAssertNil(PushRoute.link(from: [:]))
    }
}
