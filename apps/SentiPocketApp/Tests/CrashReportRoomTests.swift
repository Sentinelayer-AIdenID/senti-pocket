import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

/// A scripted Senti API for the reports room: rooms by id with their members and invitations, rooms that are gone, and
/// every call in order. Ids are made up.
private final class ScriptedReportRooms: ReportRoomAPI, @unchecked Sendable {
    enum Call: Equatable {
        case create(sessionId: String, title: String, maxMembers: Int)
        case membership(String)
        case send(sessionId: String, clientId: String)
        case add(sessionId: String, login: String)
    }

    private let lock = NSLock()
    private var log: [Call] = []
    /// Each room's membership as the API would list it.
    private var rooms: [String: RoomMembershipSnapshot] = [:]
    /// Rooms deleted, or that this account no longer belongs to: their reads are refused.
    private var gone: Set<String> = []
    private var readFailure: Error?
    private var sendFailure: Error?
    private let viewer: String
    let supportUserId = "00000000-0000-4000-8000-00000000005a"

    init(viewer: String) {
        self.viewer = viewer
    }

    var calls: [Call] { lock.withLock { log } }
    var sends: [String] {
        calls.compactMap { if case .send(let id, _) = $0 { return id } else { return nil } }
    }
    var creates: Int {
        calls.filter { if case .create = $0 { return true } else { return false } }.count
    }
    var adds: [Call] {
        calls.filter { if case .add = $0 { return true } else { return false } }
    }

    func setRoom(_ id: String, _ membership: RoomMembershipSnapshot) { lock.withLock { rooms[id] = membership } }
    func setGone(_ id: String) { lock.withLock { _ = gone.insert(id) } }
    func failReads(with error: Error?) { lock.withLock { readFailure = error } }
    func failSends(with error: Error?) { lock.withLock { sendFailure = error } }

    func createReportRoom(title: String, maxMembers: Int, sessionId: String, idempotencyKey: String) async throws -> String {
        lock.withLock {
            log.append(.create(sessionId: sessionId, title: title, maxMembers: maxMembers))
            rooms[sessionId] = RoomMembershipSnapshot(visibility: "private", memberUserIds: [viewer])
        }
        return sessionId
    }

    func reportRoomMembership(sessionId: String) async throws -> RoomMembershipSnapshot {
        try lock.withLock {
            log.append(.membership(sessionId))
            if let readFailure { throw readFailure }
            guard !gone.contains(sessionId), let membership = rooms[sessionId] else {
                throw SessionTransportError.accessDenied
            }
            return membership
        }
    }

    func sendReport(sessionId: String, text: String, clientId: String) async throws {
        try lock.withLock {
            log.append(.send(sessionId: sessionId, clientId: clientId))
            if let sendFailure { throw sendFailure }
        }
    }

    func addReportRoomMember(sessionId: String, login: String) async throws -> String? {
        lock.withLock {
            log.append(.add(sessionId: sessionId, login: login))
            if let room = rooms[sessionId] {
                rooms[sessionId] = RoomMembershipSnapshot(visibility: room.visibility,
                                                          memberUserIds: room.memberUserIds + [supportUserId],
                                                          pendingInvitationCount: room.pendingInvitationCount)
            }
        }
        return supportUserId
    }
}

/// Room ids handed out in order, across every delivery in a test, as the app makes them.
private final class RoomIds {
    private var next: [String]

    init(_ ids: [String]) {
        next = ids
    }

    func take() -> String {
        next.isEmpty ? UUID().uuidString.lowercased() : next.removeFirst()
    }
}

/// A calendar link keeper with nothing in it, for the sign-out test.
private struct NoCalendarLinks: CalendarLinkKeeping {
    func link(for person: String) -> URL? { nil }
    func keep(_ link: URL, for person: String) {}
    func forgetAll() {}
}

/// Carter, 11-06: a crash report the phone offered "in the next room you open" went into a room with other people in
/// it. Reports now go only to the person's own reports room, made for them, and never to a room anyone else is in.
@MainActor
final class CrashReportRoomTests: XCTestCase {
    private let viewer = "00000000-0000-4000-8000-0000000000a1"
    private let otherAccount = "00000000-0000-4000-8000-0000000000b2"
    private let someoneElse = "00000000-0000-4000-8000-0000000000c3"
    private var suite = ""
    private var defaults: UserDefaults!
    private var ids: [String] = []
    private var roomIds: RoomIds!

    override func setUp() {
        super.setUp()
        suite = "crash-report-room-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        ids = (1...6).map { String(format: "00000000-0000-4000-8000-0000000001%02d", $0) }
        roomIds = RoomIds(ids)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var store: ReportRoomStore { ReportRoomStore(defaults: defaults) }

    private func delivery(_ api: ScriptedReportRooms, support: String? = nil) -> CrashReportDelivery {
        let source = roomIds!
        return CrashReportDelivery(api: api, rooms: store, supportLogin: support, makeId: { source.take() },
                                   note: { _ in })
    }

    func test_the_first_report_makes_a_private_room_of_yours_and_goes_there() async {
        let api = ScriptedReportRooms(viewer: viewer)
        let outcome = await delivery(api).deliver("report", clientId: "crash-1", person: viewer)
        XCTAssertEqual(outcome, .sent(sessionId: ids[0]))
        XCTAssertEqual(api.calls, [
            .create(sessionId: ids[0], title: "Pocket reports", maxMembers: 2),
            .membership(ids[0]),
            .send(sessionId: ids[0], clientId: "crash-1")
        ], "made for you, read before the post, and nobody asked in without a team account")
        XCTAssertEqual(store.room(for: viewer), ReportRoom(sessionId: ids[0], supportUserId: nil))
    }

    func test_the_next_report_goes_to_the_same_room() async {
        let api = ScriptedReportRooms(viewer: viewer)
        _ = await delivery(api).deliver("first", clientId: "crash-1", person: viewer)
        let outcome = await delivery(api).deliver("second", clientId: "crash-2", person: viewer)
        XCTAssertEqual(outcome, .sent(sessionId: ids[0]))
        XCTAssertEqual(api.creates, 1, "the kept room is used again")
        XCTAssertEqual(api.sends, [ids[0], ids[0]])
    }

    /// A room that was deleted, or that you left (the API answers 404 or 403 alike, as `accessDenied`), is made again.
    func test_a_deleted_or_left_room_is_made_again() async {
        let api = ScriptedReportRooms(viewer: viewer)
        _ = await delivery(api).deliver("first", clientId: "crash-1", person: viewer)
        api.setGone(ids[0])
        let outcome = await delivery(api).deliver("second", clientId: "crash-2", person: viewer)
        XCTAssertEqual(outcome, .sent(sessionId: ids[1]))
        XCTAssertEqual(api.sends, [ids[0], ids[1]], "never posted in the room that is gone")
        XCTAssertEqual(store.room(for: viewer)?.sessionId, ids[1], "the new room is kept")
    }

    func test_a_room_whose_people_cannot_be_read_is_never_posted_in() async {
        let refused = ScriptedReportRooms(viewer: viewer)
        refused.failReads(with: SessionTransportError.accessDenied)
        let outcome = await delivery(refused).deliver("report", clientId: "crash-1", person: viewer)
        XCTAssertEqual(outcome, .notSent)
        XCTAssertTrue(refused.sends.isEmpty, "never posted where the people in the room could not be read")
        XCTAssertEqual(refused.creates, 3, "three rooms at most, not made again and again")
        XCTAssertNil(store.room(for: viewer), "and none of them is kept")

        roomIds = RoomIds(ids)
        let offline = ScriptedReportRooms(viewer: viewer)
        store.keep(ReportRoom(sessionId: "kept-room", supportUserId: nil), for: viewer)
        offline.failReads(with: SessionTransportError.network)
        let later = await delivery(offline).deliver("report", clientId: "crash-1", person: viewer)
        XCTAssertEqual(later, .notSent)
        XCTAssertEqual(offline.calls, [.membership("kept-room")], "not posted, and no room made, while offline")
        XCTAssertEqual(store.room(for: viewer)?.sessionId, "kept-room", "kept for the next time")
    }

    func test_a_report_never_goes_to_a_room_anyone_else_is_in() async {
        let cases: [(String, RoomMembershipSnapshot)] = [
            ("another person in it", RoomMembershipSnapshot(visibility: "private", memberUserIds: [viewer, someoneElse])),
            ("a member with no user id", RoomMembershipSnapshot(visibility: "private", memberUserIds: [viewer, ""])),
            ("an open invitation", RoomMembershipSnapshot(visibility: "private", memberUserIds: [viewer],
                                                          pendingInvitationCount: 1)),
            ("a public room", RoomMembershipSnapshot(visibility: "public", memberUserIds: [viewer]))
        ]
        for (name, shared) in cases {
            store.forgetAll()
            roomIds = RoomIds(ids)
            let api = ScriptedReportRooms(viewer: viewer)
            store.keep(ReportRoom(sessionId: "shared-room", supportUserId: nil), for: viewer)
            api.setRoom("shared-room", shared)
            let outcome = await delivery(api).deliver("report", clientId: "crash-1", person: viewer)
            XCTAssertEqual(outcome, .sent(sessionId: ids[0]), name)
            XCTAssertFalse(api.sends.contains("shared-room"), "\(name): nothing is posted where anyone else would read it")
            XCTAssertEqual(api.sends, [ids[0]], "\(name): it goes to a new room of yours alone")
            XCTAssertEqual(store.room(for: viewer)?.sessionId, ids[0], name)
        }
    }

    func test_the_teams_account_is_asked_in_once_and_is_not_someone_else() async {
        let api = ScriptedReportRooms(viewer: viewer)
        _ = await delivery(api, support: "Team-Account").deliver("first", clientId: "crash-1", person: viewer)
        XCTAssertEqual(api.calls, [
            .create(sessionId: ids[0], title: "Pocket reports", maxMembers: 2),
            .membership(ids[0]),
            .send(sessionId: ids[0], clientId: "crash-1"),
            .add(sessionId: ids[0], login: "team-account")
        ], "asked in after the report is in the room, as the login the build names")
        XCTAssertEqual(store.room(for: viewer)?.supportUserId, api.supportUserId)
        let outcome = await delivery(api, support: "Team-Account").deliver("second", clientId: "crash-2", person: viewer)
        XCTAssertEqual(outcome, .sent(sessionId: ids[0]), "the team's account in the room is not someone else")
        XCTAssertEqual(api.adds.count, 1, "asked in once")
        XCTAssertEqual(api.creates, 1)
    }

    func test_with_no_team_account_in_the_build_nobody_is_asked_in() async {
        let api = ScriptedReportRooms(viewer: viewer)
        for (index, support) in [nil, "", "$(SENTI_SUPPORT_MEMBER)", "team@example.invalid"].enumerated() {
            _ = await delivery(api, support: support).deliver("report", clientId: "crash-\(index)", person: viewer)
        }
        XCTAssertEqual(api.sends, [ids[0], ids[0], ids[0], ids[0]])
        XCTAssertTrue(api.adds.isEmpty, "the report stays in your own room, and nobody is asked in")
    }

    func test_a_report_that_did_not_get_there_is_not_sent() async {
        let api = ScriptedReportRooms(viewer: viewer)
        api.failSends(with: RoomSendError.retryable(retryAfterSeconds: nil))
        let outcome = await delivery(api, support: "team-account").deliver("report", clientId: "crash-1", person: viewer)
        XCTAssertEqual(outcome, .notSent, "so the reports stay on the phone, to offer again")
        XCTAssertTrue(api.adds.isEmpty, "nobody is asked into a room the report is not in")
        let unknown = await delivery(api).deliver("report", clientId: "crash-1", person: nil)
        XCTAssertEqual(unknown, .notSent, "without the account the room cannot be told apart from anyone else's")
    }

    /// Carter, 11-06: the room is kept under the signed-in account's id, and goes with a sign-out, a refused credential
    /// or the account's deletion, so a second account on the same phone never uses the first account's room.
    func test_the_room_belongs_to_the_account_that_made_it_and_goes_with_its_sign_out() async {
        store.keep(ReportRoom(sessionId: "kept-room", supportUserId: nil), for: viewer.uppercased())
        XCTAssertEqual(store.room(for: viewer)?.sessionId, "kept-room", "kept under the account id, whatever its case")
        XCTAssertNil(store.room(for: otherAccount), "another account is never given it")
        XCTAssertNil(store.room(for: viewer), "and it is dropped, not kept for later")

        let first = ScriptedReportRooms(viewer: viewer)
        _ = await delivery(first).deliver("first", clientId: "crash-1", person: viewer)
        XCTAssertEqual(store.room(for: viewer)?.sessionId, ids[0])
        let second = ScriptedReportRooms(viewer: otherAccount)
        let outcome = await delivery(second).deliver("theirs", clientId: "crash-2", person: otherAccount)
        XCTAssertEqual(outcome, .sent(sessionId: ids[1]), "the second account gets a room of its own")
        XCTAssertFalse(second.calls.contains(.membership(ids[0])), "the first account's room is not even read")
        XCTAssertEqual(store.room(for: otherAccount)?.sessionId, ids[1])

        SignInCoordinator.clearPersonalState(calendarLinks: NoCalendarLinks(), reportRooms: store)
        XCTAssertNil(defaults.data(forKey: ReportRoomStore.key), "sign-out, a refused credential and deletion clear it")
    }

    func test_the_team_account_is_read_from_the_build_as_a_github_login_only() {
        XCTAssertEqual(SupportMember.login("Team-Account"), "team-account")
        for bad in [nil, "", "  ", "$(SENTI_SUPPORT_MEMBER)", "team@example.invalid", "-team", "team-", "team--account",
                    String(repeating: "a", count: 40)] {
            XCTAssertNil(SupportMember.login(bad), String(describing: bad))
        }
        XCTAssertNil(SupportMember.configured(infoDictionary: [:]), "no key: none")
        XCTAssertEqual(SupportMember.configured(infoDictionary: ["SENTI_SUPPORT_MEMBER": "team-account"]), "team-account")
    }

    func test_one_message_id_per_set_of_reports() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        func report(_ id: String) -> CrashReport {
            CrashReport(id: id, kind: .crash, at: start, build: "2026110601", system: "iOS 26.0", device: "iPhone17,2",
                        reason: "EXC_BREAKPOINT / SIGTRAP")
        }
        let one = CrashReportText.clientId(for: [report("a"), report("b")])
        XCTAssertEqual(one, CrashReportText.clientId(for: [report("b"), report("a")]), "whatever their order")
        XCTAssertNotEqual(one, CrashReportText.clientId(for: [report("a")]))
        XCTAssertTrue(one.hasPrefix("crash-") && one.count <= 120, one)
    }

    func test_the_offer_says_where_the_report_goes() {
        XCTAssertTrue(CrashReportOffer.message.contains("private room of yours"))
        XCTAssertFalse(CrashReportOffer.message.contains("this room"))
    }
}
