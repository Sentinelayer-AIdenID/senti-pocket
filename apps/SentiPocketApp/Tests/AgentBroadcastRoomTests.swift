import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

// Ticket 2f95466a (Carter #62572): a room offers @any once its read says it takes it, read beside the room and never
// before it; agents of a box are grouped from presence; under a message, who picked up its @any.

/// A room whose read (`features`) answers when the test lets it, or fails.
private final class FeatureRoom: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let history: [RoomMessage]
    private let actions: RoomActionsPage
    private let answer: Result<RoomFeatures, Error>
    private var gate: CheckedContinuation<Void, Never>?
    private var held: Bool
    private var reads = 0

    init(history: [RoomMessage], answer: Result<RoomFeatures, Error>, held: Bool = false,
         actions: RoomActionsPage = RoomActionsPage()) {
        self.history = history
        self.actions = actions
        self.answer = answer
        self.held = held
    }

    func featureReads() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// Lets a held read answer.
    func release() {
        lock.lock()
        held = false
        let waiting = gate
        gate = nil
        lock.unlock()
        waiting?.resume()
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        actions
    }

    func roomFeatures(sessionId: String) async throws -> RoomFeatures {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            reads += 1
            if held {
                gate = continuation
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
        return try answer.get()
    }
}

/// Presence with the room's agents, some in a box.
private final class BoxPresence: RoomReceiptsClient, @unchecked Sendable {
    let snapshot: RoomPresence

    init(_ snapshot: RoomPresence) { self.snapshot = snapshot }

    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {}
    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] { [] }
    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? { 90 }
    func presence(sessionId: String) async throws -> RoomPresence { snapshot }
}

private struct AcceptingSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

private struct NoRead: Error {}

@MainActor
final class AgentBroadcastRoomTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func room(_ transport: FeatureRoom, presence: RoomPresence? = nil) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: AcceptingSender(),
            membershipRole: "contributor",
            ownAuthorIds: ["human-alex"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            receipts: presence.map(BoxPresence.init),
            onReauthenticationRequired: {}
        )
    }

    private static func message(_ seq: Int64, _ text: String, addressed: RoomAddressed? = nil) -> RoomMessage {
        RoomMessage(id: "e\(seq)", sequenceId: seq, kind: .message, authorId: "human-alex", authorName: "alex",
                    isHuman: true, text: text, timestamp: "2026-11-06T18:3\(seq % 10):00Z", addressed: addressed)
    }

    private static let history = [message(1, "morning"),
                                  RoomMessage(id: "e2", sequenceId: 2, kind: .message, authorId: "build-agent",
                                              authorName: "build-agent", isHuman: false, text: "on it",
                                              timestamp: "2026-11-06T18:32:00Z")]

    private func offersAny(_ coordinator: RoomChatCoordinator) -> Bool {
        coordinator.state.mentionCandidates.contains { $0.isAny }
    }

    /// The room's messages show while its read is still out, and @any is not offered until the read says the room
    /// takes it.
    func test_the_room_shows_before_its_read_answers_and_at_any_waits_for_it() async {
        let transport = FeatureRoom(history: Self.history, answer: .success(RoomFeatures(agentBroadcast: true)),
                                    held: true)
        let coordinator = room(transport)
        coordinator.resume()
        await waitUntil("the room's messages, the read still out") {
            !coordinator.state.isLoadingInitial && !coordinator.state.rows.isEmpty
        }
        await waitUntil("the read asked") { transport.featureReads() == 1 }
        XCTAssertFalse(offersAny(coordinator), "not offered before the room says so")
        transport.release()
        await waitUntil("@any offered") { self.offersAny(coordinator) }
        XCTAssertEqual(MentionSuggester.suggestions(for: "", among: coordinator.state.mentionCandidates)
            .prefix(2).map(\.handle), ["all", "any"])
        coordinator.pause()
    }

    /// A room that says it does not take @any, or whose read fails, never offers it.
    func test_a_room_that_does_not_take_at_any_never_offers_it() async {
        for answer in [Result<RoomFeatures, Error>.success(RoomFeatures(agentBroadcast: false)), .failure(NoRead())] {
            let transport = FeatureRoom(history: Self.history, answer: answer)
            let coordinator = room(transport)
            coordinator.resume()
            await waitUntil("loaded and read") {
                !coordinator.state.isLoadingInitial && transport.featureReads() == 1
            }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertFalse(offersAny(coordinator))
            XCTAssertTrue(coordinator.state.mentionCandidates.contains { $0.handle == "build-agent" })
            coordinator.pause()
        }
    }

    /// Under each message that asked for any free agent: who the server chose, named as the room names people and
    /// agents, or that nobody was free; nothing when its author was over the limit.
    func test_the_line_under_a_message_names_who_picked_up_its_at_any() async {
        let history = [
            Self.message(1, "@any can you look?", addressed: RoomAddressed(any: "build-agent")),
            Self.message(2, "@any and you?", addressed: RoomAddressed(any: "human-griff")),
            Self.message(3, "@any anyone?", addressed: RoomAddressed(anyUnresolved: true)),
            Self.message(4, "@any again", addressed: RoomAddressed(throttled: true)),
            Self.message(5, "no one asked"),
        ]
        let coordinator = room(FeatureRoom(history: history, answer: .success(RoomFeatures())))
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial && !coordinator.state.rows.isEmpty }
        var lines: [Int64: String?] = [:]
        for case .message(let row) in coordinator.state.rows { lines[row.sequenceId] = row.addressedLine }
        XCTAssertEqual(lines[1], "Picked up by build-agent")
        XCTAssertEqual(lines[2], "Picked up by griff", "a person by their login, as the room names them")
        XCTAssertEqual(lines[3], "Nobody free right now")
        XCTAssertEqual(lines[4], .some(nil), "over the limit: nothing extra")
        XCTAssertEqual(lines[5], .some(nil))
        coordinator.pause()
    }

    /// A thread reply that asked for any free agent says who picked it up, as a message does.
    func test_a_thread_reply_shows_who_picked_up_its_at_any() async {
        let replies = [
            RoomReply(id: "act-1", targetSequenceId: 2, authorId: "human-alex", text: "@any can you check?",
                      createdAt: "2026-11-06T18:40:00Z", addressed: RoomAddressed(any: "senti-3f2a9c01-1")),
            RoomReply(id: "act-2", targetSequenceId: 2, authorId: "human-alex", text: "@any anyone?",
                      createdAt: "2026-11-06T18:41:00Z", addressed: RoomAddressed(anyUnresolved: true)),
            RoomReply(id: "act-3", targetSequenceId: 2, authorId: "human-alex", text: "thanks",
                      createdAt: "2026-11-06T18:42:00Z"),
        ]
        let transport = FeatureRoom(history: Self.history, answer: .success(RoomFeatures()),
                                    actions: RoomActionsPage(replies: replies))
        let coordinator = room(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.send(.openThread(sequenceId: 2))
        await waitUntil("the thread's replies") { coordinator.state.thread?.replies.count == 3 }
        XCTAssertEqual(coordinator.state.thread?.replies.map(\.addressedLine),
                       ["Picked up by senti-3f2a9c01-1", "Nobody free right now", nil])
        coordinator.pause()
    }

    /// A box member who posted but is not here now groups from the author record of what it posted
    /// (`agent.boxMember`), with no presence at all.
    func test_a_box_member_who_posted_but_is_not_here_still_groups() async {
        let history = Self.history + [
            RoomMessage(id: "e3", sequenceId: 3, kind: .message, authorId: "senti-3f2a9c01-1",
                        authorName: "senti-3f2a9c01-1", isHuman: false, text: "done", timestamp: "2026-11-06T18:33:00Z",
                        authorBox: RoomAgentBox(id: "3f2a9c01", index: 1)),
        ]
        let coordinator = room(FeatureRoom(history: history, answer: .success(RoomFeatures())))
        coordinator.resume()
        await waitUntil("offered") { coordinator.state.mentionCandidates.contains { $0.handle == "senti-3f2a9c01-1" } }
        let candidates = coordinator.state.mentionCandidates
        XCTAssertEqual(candidates.first { $0.handle == "senti-3f2a9c01-1" }?.group?.label, "Box 3f2a")
        XCTAssertNil(candidates.first { $0.handle == "build-agent" }?.group, "an agent outside any box")
        coordinator.pause()
    }

    /// Agents in a box (presence's `boxMember`) are grouped under their box in the picker; the rest are not.
    func test_agents_in_a_box_are_grouped_from_presence() async {
        let presence = RoomPresence(
            isAvailable: true,
            participants: [
                RoomPresentParticipant(id: "senti-3f2a9c01-2", isHuman: false, isBox: true,
                                       boxMember: RoomAgentBox(id: "3f2a9c01", index: 2)),
                RoomPresentParticipant(id: "senti-3f2a9c01-1", isHuman: false, isBox: true,
                                       boxMember: RoomAgentBox(id: "3f2a9c01", index: 1)),
                RoomPresentParticipant(id: "review-agent", isHuman: false, isBox: true),
            ],
            humansOnline: 0, agentsOnline: 3, ttlSeconds: 90
        )
        let coordinator = room(FeatureRoom(history: Self.history, answer: .success(RoomFeatures())), presence: presence)
        coordinator.resume()
        await waitUntil("box members offered") {
            coordinator.state.mentionCandidates.contains { $0.handle == "senti-3f2a9c01-1" }
        }
        let agents = coordinator.state.mentionCandidates.filter { !$0.isHuman }
        XCTAssertEqual(agents.map(\.handle), ["build-agent", "review-agent", "senti-3f2a9c01-1", "senti-3f2a9c01-2"])
        XCTAssertEqual(agents.map { $0.group?.label }, [nil, nil, "Box 3f2a", "Box 3f2a"])
        coordinator.pause()
    }
}

/// VoiceOver reads who picked up a message's @any with the message.
@MainActor
final class AgentBroadcastLineViewTests: XCTestCase {
    func test_voiceover_reads_who_picked_up_with_the_message() throws {
        var asked = RoomChatMessageInput(id: "e12", sequenceId: 12, kind: .message, authorId: "human-alex",
                                         authorName: "alex", isHuman: true, text: "@any can you look?",
                                         timestamp: "2026-11-06T18:30:00.000000+00:00")
        asked.addressedLine = "Picked up by build-agent"
        let state = RoomChatPresentationState(sessionId: "room_1", title: "Room", messages: [asked],
                                              ownAuthorIds: ["human-alex"], connection: .live)
        let window = try HostedSummary.host(NavigationStack { RoomChatView(state: state) { _ in } })
        defer { HostedSummary.close(window) }
        let line = HostedSummary.wait(for: "pocket.room.addressed.12", in: window, label: "Picked up by build-agent")
        XCTAssertEqual(line?.accessibilityLabel, "Picked up by build-agent", "read with the message, in its row")
    }
}
