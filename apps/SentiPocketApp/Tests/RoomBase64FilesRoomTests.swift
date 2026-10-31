import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The room's newest page and its replies, read again at each refresh (the last page given stays).
private final class FilesRoom: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let newest: [RoomMessage]
    private var actions: [RoomActionsPage]

    init(newest: [RoomMessage], actions: [RoomActionsPage]) {
        self.newest = newest
        self.actions = actions
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? newest : [], nextBeforeSequence: nil, hasMore: false)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        lock.lock()
        defer { lock.unlock() }
        return actions.count > 1 ? actions.removeFirst() : (actions.first ?? RoomActionsPage())
    }
}

/// A file an agent posts as base64 parts, in replies under one message: the room puts it back together, shows it as a
/// card at that message, and folds the parts. Only bytes that hash to the declared hash are offered.
@MainActor
final class RoomBase64FilesRoomTests: XCTestCase {
    private let file = Data((1...30).map { "row \($0),\($0 * 2)" }.joined(separator: "\n").utf8)

    private func message(_ seq: Int64, _ text: String) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "ada-agent", authorName: "ada-agent",
                    isHuman: false, text: text, timestamp: "2026-10-31T14:00:00Z")
    }

    /// The file in `total` envelope parts, as replies to message 300.
    private func parts(_ total: Int, name: String = "rows.csv") throws -> [RoomReply] {
        let encoded = file.base64EncodedString()
        let size = (encoded.count + total - 1) / total
        return try (0..<total).map { index in
            let start = encoded.index(encoded.startIndex, offsetBy: index * size)
            let end = encoded.index(start, offsetBy: min(size, encoded.distance(from: start, to: encoded.endIndex)))
            let body = try JSONSerialization.data(withJSONObject: [
                "artifact": name, "sha256": RoomBase64Files.sha256Hex(file), "bytes": file.count,
                "part": index + 1, "parts": total, "data": String(encoded[start..<end])
            ], options: [.sortedKeys])
            return RoomReply(id: "r\(index + 1)", targetSequenceId: 300, authorId: "ada-agent",
                             text: String(decoding: body, as: UTF8.self),
                             createdAt: "2026-10-31T14:0\(index + 1):00Z")
        }
    }

    private func room(_ transport: FilesRoom) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            membershipRole: "contributor",
            ownAuthorIds: ["human-sam"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    private func rows(_ room: RoomChatCoordinator) -> [RoomChatMessageRow] {
        room.state.rows.compactMap { row in
            if case .message(let message) = row { return message }
            return nil
        }
    }

    private func card(_ room: RoomChatCoordinator) -> RoomChatFileCard? {
        rows(room).first { $0.id == "evt-300" }?.files.first
    }

    func test_parts_in_a_thread_become_one_verified_file_at_its_root() async throws {
        let transport = FilesRoom(newest: [message(299, "Morning."), message(300, "The rows, in 3 parts below.")],
                                  actions: [RoomActionsPage(replies: try parts(3))])
        let room = room(transport)
        room.resume()
        await waitUntil("the file put together") { self.card(room)?.isVerified == true }
        let verified = try XCTUnwrap(card(room))
        XCTAssertEqual(verified.name, "rows.csv")
        XCTAssertEqual(verified.content?.data, file)
        XCTAssertTrue(verified.detail.contains("sha256 ✓ \(RoomBase64Files.sha256Hex(file).prefix(12)) · 3 parts"),
                      verified.detail)
        XCTAssertEqual(verified.partCount, 3)
        XCTAssertNotNil(verified.preview, "a text file previews")
        XCTAssertTrue(rows(room).filter(\.isInlineReply).allSatisfy { $0.filePartOf == 300 }, "the parts fold")
        XCTAssertNil(rows(room).first { $0.id == "evt-299" }?.filePartOf, "an ordinary message stays")
        room.pause()
    }

    /// Two of three parts are no file: the card says so and offers nothing. The third part arriving completes it.
    func test_a_missing_part_shows_why_until_it_arrives() async throws {
        let all = try parts(3)
        let transport = FilesRoom(newest: [message(300, "The rows, in 3 parts below.")],
                                  actions: [RoomActionsPage(replies: Array(all.prefix(2))),
                                            RoomActionsPage(replies: all)])
        let room = room(transport)
        room.resume()
        await waitUntil("the parts read") { self.card(room) != nil }
        XCTAssertEqual(card(room)?.detail, "2 of 3 parts")
        XCTAssertNil(card(room)?.content, "nothing to save")

        await room.refreshActions(force: true)
        await waitUntil("the file put together") { self.card(room)?.isVerified == true }
        XCTAssertEqual(card(room)?.content?.data, file)
    }

    /// Parts edited into something else are parts no more: the file goes with them.
    func test_a_thread_whose_parts_are_gone_shows_no_file() async throws {
        let gone = try parts(3).map { part in
            RoomReply(id: part.id, targetSequenceId: 300, authorId: "ada-agent", text: "Removed.",
                      createdAt: part.createdAt, revision: 2, isEdited: true)
        }
        let transport = FilesRoom(newest: [message(300, "The rows, in 3 parts below.")],
                                  actions: [RoomActionsPage(replies: try parts(3)), RoomActionsPage(replies: gone)])
        let room = room(transport)
        room.resume()
        await waitUntil("the file put together") { self.card(room)?.isVerified == true }

        await room.refreshActions(force: true)
        await waitUntil("the file gone") { self.card(room) == nil }
        XCTAssertTrue(rows(room).allSatisfy { $0.filePartOf == nil })
        room.pause()
    }

    func test_a_room_without_parts_shows_no_file() async throws {
        let transport = FilesRoom(newest: [message(300, "Plain notes.")], actions: [RoomActionsPage(replies: [
            RoomReply(id: "r1", targetSequenceId: 300, authorId: "lin-agent", text: "Looks good.",
                      createdAt: "2026-10-31T14:01:00Z")
        ])])
        let room = room(transport)
        room.resume()
        await waitUntil("the reply read") { self.rows(room).contains(where: \.isInlineReply) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(rows(room).allSatisfy { $0.files.isEmpty && $0.filePartOf == nil })
        room.pause()
    }
}
