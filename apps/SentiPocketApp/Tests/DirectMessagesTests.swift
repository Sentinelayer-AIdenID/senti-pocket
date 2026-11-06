import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The server's direct messages as a fake of the pinned phase-1 contract (2026-11-04): a 404 for everything when the
/// flag is off, and one 404 for every refusal.
private final class FakeDirectMessages: DirectMessaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _on = true
    private var _settingsFails = false
    private var _settingsInvalid = false
    private var _refuses = false
    private var _patchFails: DirectMessageError?
    private var _allowance: DirectMessagesAllowance? = .sharedRooms
    private var _shares: [DirectMemoryShare] = []
    private var _calls: [String] = []
    private var _opened: [(String, String)] = []
    private var _patches: [(String, String, Bool)] = []

    var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
    var settingsFails: Bool { get { lock.withLock { _settingsFails } } set { lock.withLock { _settingsFails = newValue } } }
    var settingsInvalid: Bool { get { lock.withLock { _settingsInvalid } } set { lock.withLock { _settingsInvalid = newValue } } }
    var refuses: Bool { get { lock.withLock { _refuses } } set { lock.withLock { _refuses = newValue } } }
    var patchFails: DirectMessageError? { get { lock.withLock { _patchFails } } set { lock.withLock { _patchFails = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    var opened: [(String, String)] { lock.withLock { _opened } }
    var patches: [(String, String, Bool)] { lock.withLock { _patches } }

    static func dm(_ shares: [DirectMemoryShare] = [], origin: DirectRoomReference? = DirectRoomReference(sessionId: "room-1", title: "Design review")) -> DirectMessage {
        DirectMessage(sessionId: "dm-1",
                      counterpart: SessionCounterpart(senderId: "review-agent", kind: "agent", displayName: "review-agent"),
                      originRoom: origin,
                      mutualRooms: [DirectRoomReference(sessionId: "room-1", title: "Design review"),
                                    DirectRoomReference(sessionId: "room-2", title: "Release train")],
                      memoryShare: shares, created: true)
    }

    private func note(_ call: String) throws {
        lock.withLock { _calls.append(call) }
        guard on else { throw DirectMessageError.unavailable }
    }

    func openDirectMessage(with targetSenderId: String, from contextRoomId: String) async throws -> DirectMessage {
        try note("open")
        lock.withLock { _opened.append((targetSenderId, contextRoomId)) }
        if refuses { throw DirectMessageError.unavailable }
        return Self.dm(lock.withLock { _shares })
    }

    func directMessage(_ sessionId: String) async throws -> DirectMessage {
        try note("get")
        return Self.dm(lock.withLock { _shares })
    }

    func setMemoryShare(_ sessionId: String, roomId: String, enabled: Bool) async throws -> [DirectMemoryShare] {
        try note("patch")
        lock.withLock { _patches.append((sessionId, roomId, enabled)) }
        if let patchFails { throw patchFails }
        return lock.withLock {
            _shares = _shares.filter { $0.roomId != roomId } + [DirectMemoryShare(roomId: roomId, enabled: enabled)]
            return _shares
        }
    }

    func directMessageSettings() async throws -> DirectMessagesAllowance? {
        try note("settings")
        if settingsFails { throw DirectMessageError.retryable }
        if settingsInvalid { throw DirectMessageError.invalidData }
        return lock.withLock { _allowance }
    }

    func setDirectMessageSettings(_ allowance: DirectMessagesAllowance) async throws -> DirectMessagesAllowance? {
        try note("set-settings")
        if settingsFails { throw DirectMessageError.retryable }
        lock.withLock { _allowance = allowance }
        return allowance
    }
}

@MainActor
final class DirectMessagesTests: XCTestCase {
    private func context(_ fake: FakeDirectMessages, existing: String? = nil,
                         opened: @escaping (DirectMessage) -> Void = { _ in }) -> RoomDirectContext {
        RoomDirectContext(center: DirectMessagesCenter(client: fake), existing: { _ in existing }, open: opened)
    }

    // MARK: - On or off

    func test_direct_messages_stay_hidden_until_the_server_answers_and_a_404_hides_them_again() async {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        XCTAssertFalse(center.isAvailable, "nothing shows before the server has said")
        await center.refresh()
        XCTAssertTrue(center.isAvailable)
        XCTAssertEqual(center.allowance, .sharedRooms)
        fake.on = false
        await center.refresh()
        XCTAssertFalse(center.isAvailable, "the flag off: every route 404s, and every affordance hides")
        XCTAssertNil(center.allowance)
    }

    func test_a_room_screen_gets_direct_messages_only_while_the_server_says_they_are_on() async {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        XCTAssertNil(RoomDirectContext.ifAvailable(center, existing: { _ in nil }, open: { _ in }))
        await center.refresh()
        XCTAssertNotNil(RoomDirectContext.ifAvailable(center, existing: { _ in nil }, open: { _ in }))
        fake.on = false
        await center.refresh()
        XCTAssertNil(RoomDirectContext.ifAvailable(center, existing: { _ in nil }, open: { _ in }),
                     "a 404 takes the cards, the switch and the header's server parts away")
    }

    func test_a_failure_that_says_nothing_keeps_what_is_shown() async {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        await center.refresh()
        fake.settingsFails = true
        await center.refresh()
        XCTAssertTrue(center.isAvailable)
        XCTAssertEqual(center.allowance, .sharedRooms)
    }

    func test_who_can_message_me_saves_and_a_failure_puts_it_back() async {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        await center.refresh()
        await center.setAllowance(.nobody)
        XCTAssertEqual(center.allowance, .nobody)
        XCTAssertNil(center.allowanceNotice)
        fake.settingsFails = true
        await center.setAllowance(.sharedRooms)
        XCTAssertEqual(center.allowance, .nobody, "the server did not take it, so it is shown as the server has it")
        XCTAssertNotNil(center.allowanceNotice)
    }

    // MARK: - The profile card

    func test_message_opens_from_the_room_you_are_in_and_hands_over_the_servers_dm() async {
        let fake = FakeDirectMessages()
        let model = RoomProfileModel(target: RoomProfileTarget(senderId: "review-agent", name: "review-agent", isAgent: true),
                                     sharedRoom: "Design review", canMessage: true, canBlock: false)
        let dm = await model.message(context(fake), from: "room-1")
        XCTAssertEqual(dm?.sessionId, "dm-1")
        XCTAssertEqual(fake.opened.map { $0.0 }, ["review-agent"])
        XCTAssertEqual(fake.opened.map { $0.1 }, ["room-1"], "the current room goes as contextRoomId")
        XCTAssertEqual(model.state.phase, .idle)
    }

    func test_a_refusal_reads_the_same_whatever_it_was_and_checks_whether_dms_went_off() async throws {
        let fake = FakeDirectMessages()
        fake.refuses = true
        let model = RoomProfileModel(target: RoomProfileTarget(senderId: "human-sam", name: "Sam", isAgent: false),
                                     sharedRoom: "Design review", canMessage: true, canBlock: false)
        let ctx = context(fake)
        let dm = await model.message(ctx, from: "room-1")
        XCTAssertNil(dm)
        XCTAssertEqual(model.state.phase, .notice("You can't message Sam right now."))
        for _ in 0..<50 where !fake.calls.contains("settings") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(fake.calls.contains("settings"), "a 404 also asks whether direct messages are still on")
    }

    func test_the_card_names_this_room_until_a_dm_lists_the_rooms_you_share() async {
        let fake = FakeDirectMessages()
        let target = RoomProfileTarget(senderId: "review-agent", name: "review-agent", isAgent: true)
        let fresh = RoomProfileModel(target: target, sharedRoom: "Design review", canMessage: true, canBlock: false)
        await fresh.loadSharedRooms(context(fake))
        XCTAssertEqual(fresh.state.sharedRooms, ["Design review"])
        XCTAssertFalse(fake.calls.contains("get"), "no direct message yet: nothing to read")

        let known = RoomProfileModel(target: target, sharedRoom: "Design review", canMessage: true, canBlock: false)
        await known.loadSharedRooms(context(fake, existing: "dm-1"))
        XCTAssertEqual(known.state.sharedRooms, ["Design review", "Release train"])
        XCTAssertFalse(known.state.canBlock, "no block flow in this build: no Block button")
    }

    // MARK: - The memory switch

    func test_the_switch_is_the_servers_value_off_by_default_and_never_set_by_the_app() async {
        let fake = FakeDirectMessages()
        let model = DirectRoomModel(sessionId: "dm-1")
        await model.load(fake)
        XCTAssertEqual(model.dm?.memoryShare, [])
        XCTAssertFalse(model.dm?.sharesMemory(in: "room-1") ?? true)
        XCTAssertTrue(fake.patches.isEmpty, "opening a direct message changes nothing on the server")
    }

    func test_the_switch_sends_its_room_and_shows_what_the_server_answers() async {
        let fake = FakeDirectMessages()
        let model = DirectRoomModel(sessionId: "dm-1")
        await model.load(fake)
        await model.setMemory(true, roomId: "room-1", client: fake)
        XCTAssertEqual(fake.patches.map { $0.0 }, ["dm-1"])
        XCTAssertEqual(fake.patches.map { $0.1 }, ["room-1"], "the switch names the room it is for")
        XCTAssertEqual(fake.patches.map { $0.2 }, [true])
        XCTAssertTrue(model.dm?.sharesMemory(in: "room-1") ?? false)
        XCTAssertFalse(model.isSaving)
    }

    func test_a_switch_the_server_did_not_take_keeps_the_servers_value() async {
        let fake = FakeDirectMessages()
        let model = DirectRoomModel(sessionId: "dm-1")
        await model.load(fake)
        fake.patchFails = .retryable
        await model.setMemory(true, roomId: "room-1", client: fake)
        XCTAssertFalse(model.dm?.sharesMemory(in: "room-1") ?? true)
        XCTAssertNotNil(model.notice)
    }

    func test_with_dms_off_the_header_has_no_switch() async {
        let fake = FakeDirectMessages()
        fake.on = false
        let model = DirectRoomModel(sessionId: "dm-1")
        await model.load(fake)
        XCTAssertNil(model.dm)
        let info = DirectRoomInfo(FakeDirectMessages.dm())
        let header = DirectRoomHeaderState.make(name: info.counterpart.displayName, isAgent: true,
                                                origin: (id: "room-1", title: "Design review"), mutual: [],
                                                memoryShare: model.dm.map { _ in [:] }, isSaving: false)
        XCTAssertNil(header.memory)
        XCTAssertNil(header.memoryPill)
    }

    /// Carter picks the header; the pick is one constant, and the build ships the compact one until he says otherwise.
    func test_the_header_choice_is_one_constant_and_compact() {
        XCTAssertEqual(DirectRoomHeaderChoice.pick, .compact)
        XCTAssertEqual(DirectRoomHeaderChoice.current, .compact, "no launch argument in the test host")
    }

    func test_a_200_without_the_settings_does_not_turn_dms_on() async {
        let fake = FakeDirectMessages()
        fake.settingsInvalid = true
        let center = DirectMessagesCenter(client: fake)
        await center.refresh()
        XCTAssertFalse(center.isAvailable, "only the settings themselves (allowDms) turn direct messages on")
        XCTAssertNil(RoomDirectContext.ifAvailable(center, existing: { _ in nil }, open: { _ in }))
    }

    // MARK: - Opening a direct message the room list has not loaded

    func test_a_direct_message_the_list_has_not_loaded_is_asked_for_before_it_opens() async {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        let info = await center.directInfo(for: "dm-1", row: nil, rows: [])
        XCTAssertEqual(info?.counterpart.senderId, "review-agent", "it opens as the direct message it is, with its header")
        XCTAssertEqual(info?.originRoomId, "room-1")
        XCTAssertEqual(fake.calls, ["settings", "get"], "whether DMs are on is read first, then the direct message")
    }

    func test_a_room_the_list_has_loaded_opens_from_the_list_without_asking() async throws {
        let fake = FakeDirectMessages()
        let center = DirectMessagesCenter(client: fake)
        await center.refresh()
        let rows = try rows()
        let fromList = await center.directInfo(for: "dm-1", row: rows[1], rows: rows)
        XCTAssertEqual(fromList?.originTitle, "Design review")
        let room = await center.directInfo(for: "room-1", row: rows[0], rows: rows)
        XCTAssertNil(room)
        XCTAssertEqual(fake.calls, ["settings"], "nothing asked for a room the list knows")
    }

    func test_with_dms_off_a_room_the_list_has_not_loaded_opens_as_a_room() async {
        let fake = FakeDirectMessages()
        fake.on = false
        let center = DirectMessagesCenter(client: fake)
        let info = await center.directInfo(for: "room-9", row: nil, rows: [])
        XCTAssertNil(info)
        XCTAssertFalse(fake.calls.contains("get"), "direct messages off: no direct message is asked for")
    }

    // MARK: - Room-only controls

    /// New agent, Invite, Rename and agent requests are a room's: never a direct message's (the API refuses them there).
    func test_a_direct_message_has_none_of_a_rooms_controls() {
        let info = DirectRoomInfo(FakeDirectMessages.dm())
        let room = RoomRoute(sessionId: "room-1", title: "Design review", membershipRole: "owner")
        let direct = RoomRoute(sessionId: "dm-1", title: "review-agent", membershipRole: "owner", direct: info)
        XCTAssertTrue(room.hasRoomControls)
        XCTAssertTrue(room.canRename)
        XCTAssertTrue(room.canInvite)
        XCTAssertTrue(room.cardsOfferMessage)
        XCTAssertFalse(direct.hasRoomControls)
        XCTAssertFalse(direct.canRename, "an owner of a direct message cannot rename it")
        XCTAssertFalse(direct.canInvite, "nor invite anyone into it")
        XCTAssertFalse(direct.cardsOfferMessage, "a card inside a direct message never offers Message from it")
        XCTAssertTrue(NewAgentOffer.admits(role: "owner", isBreakout: false))
        XCTAssertFalse(NewAgentOffer.admits(role: "owner", isBreakout: false, isDirect: true), "no New agent there")
        let admin = RoomRoute(sessionId: "dm-1", title: "review-agent", membershipRole: "admin", direct: info)
        XCTAssertFalse(admin.canInvite)
    }

    // MARK: - Opening one: from the list, and from its push

    private func rows() throws -> [SessionRowPresentation] {
        let page = try JSONDecoder().decode(SessionListPage.self, from: Data("""
        {"sessions":[
          {"sessionId":"room-1","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"Design review","agentCount":2,"eventCount":9,"totalCostUsd":0,"kind":"room"},
          {"sessionId":"dm-1","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"contributor",
           "title":null,"agentCount":1,"eventCount":2,"totalCostUsd":0,"kind":"direct",
           "counterpart":{"senderId":"review-agent","kind":"agent","displayName":"review-agent"},"originRoomId":"room-1"},
          {"sessionId":"dm-2","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"contributor",
           "title":null,"agentCount":0,"eventCount":2,"totalCostUsd":0,"kind":"direct",
           "counterpart":{"senderId":"human-sam","kind":"human","displayName":"Sam"},"originRoomId":null}
        ],"count":3,"include_archived":false,"next_cursor":null,"has_more":false}
        """.utf8))
        return SessionListPresentationState(page: page, provenance: .fixture).rows
    }

    func test_a_direct_row_opens_as_a_direct_message_with_its_room() throws {
        let rows = try rows()
        XCTAssertNil(DirectRoomInfo(row: rows[0], rows: rows), "a room opens as a room")
        let info = try XCTUnwrap(DirectRoomInfo(row: rows[1], rows: rows))
        XCTAssertEqual(info.counterpart.senderId, "review-agent")
        XCTAssertEqual(info.originRoomId, "room-1")
        XCTAssertEqual(info.originTitle, "Design review")
        let orphan = try XCTUnwrap(DirectRoomInfo(row: rows[2], rows: rows))
        XCTAssertNil(orphan.originRoomId)
        XCTAssertNil(orphan.originTitle)
    }

    /// A direct room pushes every message: its push carries the direct message's session id (and APNs groups it by the
    /// server's `thread-id`, the session id, one thread per direct message), and opening it opens the direct message.
    func test_a_direct_messages_push_opens_the_direct_message() throws {
        let rows = try rows()
        let payload: [AnyHashable: Any] = ["aps": ["thread-id": "dm-1", "alert": ["title": "review-agent", "body": "Done"]],
                                           "sessionId": "dm-1", "sequenceId": NSNumber(value: 42)]
        let link = try XCTUnwrap(PushRoute.link(from: payload))
        XCTAssertEqual(link.sessionId, "dm-1")
        XCTAssertEqual(link.messageSequence, 42)
        let row = rows.first { $0.sessionId == link.sessionId }
        XCTAssertNotNil(DirectRoomInfo(row: row, rows: rows), "the room opened from the push is the direct message")
        XCTAssertEqual(row?.title, "review-agent")
        XCTAssertEqual(ForegroundPush.presentation(sessionId: "dm-1", roomOnScreen: "dm-1", bannerHosted: true), .quiet,
                       "the direct message on screen gets no banner")
    }

    func test_a_new_dm_opens_with_the_servers_origin() {
        let info = DirectRoomInfo(FakeDirectMessages.dm())
        XCTAssertEqual(info.originRoomId, "room-1")
        XCTAssertEqual(info.originTitle, "Design review")
        XCTAssertNil(DirectRoomInfo(FakeDirectMessages.dm(origin: nil)).originRoomId)
    }
}
