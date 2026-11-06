import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The server's rooms you share with someone, as `GET /me/shared-rooms` pages them: newest first, `limit` at a time,
/// with the total, every read recorded.
private final class SharedRoomsFixture: SharedRoomsReading, @unchecked Sendable {
    private let lock = NSLock()
    private let rooms: [SharedRoom]
    private var failure: Error?
    private var _calls: [(with: String, cursor: String?, limit: Int)] = []

    init(count: Int, failure: Error? = nil) {
        // Room 12 is the newest: they were last active in it a minute ago, in room 1 twelve minutes ago.
        rooms = (1...max(count, 1)).reversed().prefix(count).map { index in
            SharedRoom(sessionId: "room-\(index)", title: "Room \(index)",
                       lastActiveAt: String(format: "2026-11-06T05:%02d:00Z", 30 + index))
        }
        self.failure = failure
    }

    var calls: [(with: String, cursor: String?, limit: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func sharedRooms(with principal: String, cursor: String?, limit: Int) async throws -> SharedRoomsPage {
        lock.lock()
        _calls.append((principal, cursor, limit))
        let failure = self.failure
        lock.unlock()
        if let failure { throw failure }
        let start = cursor.flatMap { Int($0.dropFirst("c-".count)) } ?? 0
        let page = Array(rooms.dropFirst(start).prefix(limit))
        let next = start + page.count < rooms.count ? "c-\(start + page.count)" : nil
        return SharedRoomsPage(rooms: page, total: rooms.count, nextCursor: next)
    }
}

/// Ticket ab3c079b: review-agent's card said "1 Room you share" though Carter shares many rooms with it. The card
/// listed only the room it was opened from; now it reads the rooms you share from the server.
@MainActor
final class RoomSharedRoomsCardTests: XCTestCase {
    private static let agent = RoomProfileTarget(senderId: "review-agent", name: "review-agent", isAgent: true)
    private static let person = RoomProfileTarget(senderId: "human-alex", name: "alex", isAgent: false)

    private func card(_ target: RoomProfileTarget) -> RoomProfileModel {
        RoomProfileModel(target: target, sharedRoom: "Design review", canMessage: false, canBlock: false)
    }

    func test_twelve_shared_rooms_show_their_count_and_the_newest_first_for_an_agent_and_a_person() async {
        for target in [Self.agent, Self.person] {
            let fixture = SharedRoomsFixture(count: 12)
            let model = card(target)
            XCTAssertEqual(model.state.sharedRooms, ["Design review"], "before the server answers, the room you are in")
            XCTAssertNil(model.state.sharedRoomsTotal)

            let answered = await model.loadSharedRooms(fixture)
            XCTAssertTrue(answered, target.senderId)
            XCTAssertEqual(fixture.calls.map(\.with), [target.senderId])
            XCTAssertEqual(fixture.calls.first?.limit, RoomProfileCardState.roomsShown, "only what the card lists")
            XCTAssertEqual(model.state.sharedRoomsTotal, 12, target.senderId)
            XCTAssertEqual(model.state.sharedRoomsHeader, "Rooms you share · 12")
            XCTAssertEqual(model.state.sharedRoomLines, ["Room 12", "Room 11", "Room 10", "Room 9"], "the newest first")
            XCTAssertTrue(model.state.canSeeAllRooms, "See all lists the other 8")
        }
    }

    func test_see_all_lists_every_shared_room_newest_first_a_page_at_a_time() async {
        let fixture = SharedRoomsFixture(count: 12)
        let list = RoomSharedRoomsModel(principal: "review-agent", name: "review-agent", reader: fixture)
        await list.loadMore()
        XCTAssertEqual(list.state.rows.count, min(12, RoomSharedRoomsModel.pageSize))
        while list.state.canLoadMore, fixture.calls.count < 10 { await list.loadMore() }
        XCTAssertEqual(list.state.rows.map(\.title), (1...12).reversed().map { "Room \($0)" }, "all 12, newest first, once")
        XCTAssertEqual(list.state.total, 12)
        XCTAssertEqual(list.state.title, "Rooms you share with review-agent · 12")
        XCTAssertEqual(list.state.phase, .idle)
        XCTAssertFalse(list.state.canLoadMore, "the last page")
        XCTAssertEqual(list.state.rows.first?.lastActive, ParsedSessionTimestamp("2026-11-06T05:42:00Z").date)

        // Five at a time, it pages on with the server's cursor until the last page.
        let small = SharedRoomsFixture(count: 12)
        let paged = RoomSharedRoomsModel(principal: "human-alex", name: "alex", reader: PagedBy(5, small))
        while paged.state.canLoadMore, small.calls.count < 10 { await paged.loadMore() }
        XCTAssertEqual(small.calls.map(\.cursor), [nil, "c-5", "c-10"])
        XCTAssertEqual(paged.state.rows.map(\.id), (1...12).reversed().map { "room-\($0)" })
    }

    /// An API without the read (404), a server that does not answer it yet (503), or any other failure: the card keeps the room
    /// you are in, with no count and no See all. So does an answer with no rooms.
    func test_when_the_server_cannot_say_the_card_keeps_the_room_you_are_in_with_no_count() async {
        let failures: [Error] = [SessionTransportError.service(statusCode: 404), SessionTransportError.service(statusCode: 503),
                                 SessionTransportError.invalidData, SessionTransportError.rateLimited(retryAfterSeconds: nil)]
        for failure in failures {
            let model = card(Self.agent)
            let answered = await model.loadSharedRooms(SharedRoomsFixture(count: 12, failure: failure))
            XCTAssertFalse(answered, "\(failure)")
            XCTAssertEqual(model.state.sharedRooms, ["Design review"], "\(failure)")
            XCTAssertNil(model.state.sharedRoomsTotal, "\(failure)")
            XCTAssertEqual(model.state.sharedRoomsHeader, "Room you share")
            XCTAssertFalse(model.state.canSeeAllRooms)
        }
        let none = card(Self.person)
        let answered = await none.loadSharedRooms(SharedRoomsFixture(count: 0))
        XCTAssertFalse(answered)
        XCTAssertEqual(none.state.sharedRooms, ["Design review"])
        XCTAssertNil(none.state.sharedRoomsTotal)
    }

    /// A public room's stand-in name names no account: nothing is asked for it.
    func test_nothing_is_asked_for_a_stand_in_name() async {
        let fixture = SharedRoomsFixture(count: 12)
        let model = card(RoomProfileTarget(senderId: "human-public.9f2c", name: "Visitor", isAgent: false))
        let answered = await model.loadSharedRooms(fixture)
        XCTAssertFalse(answered)
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertEqual(model.state.sharedRooms, ["Design review"])
    }
}

/// Serves `inner` at most `size` rooms a page, whatever the caller asks for.
private struct PagedBy: SharedRoomsReading {
    let size: Int
    let inner: SharedRoomsFixture
    init(_ size: Int, _ inner: SharedRoomsFixture) {
        self.size = size
        self.inner = inner
    }

    func sharedRooms(with principal: String, cursor: String?, limit: Int) async throws -> SharedRoomsPage {
        try await inner.sharedRooms(with: principal, cursor: cursor, limit: min(limit, size))
    }
}
