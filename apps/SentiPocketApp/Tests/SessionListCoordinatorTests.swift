import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private enum SessionListMockResponse: Sendable {
    case page(SessionListPage)
    case failure(SessionTransportError)
}

private actor SessionListMockTransport: SessionTransport {
    private var responses: [SessionListMockResponse]

    init(_ responses: [SessionListMockResponse]) {
        self.responses = responses
    }

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        guard !responses.isEmpty else { throw SessionTransportError.service(statusCode: 599) }
        switch responses.removeFirst() {
        case .page(let page): return page
        case .failure(let error): throw error
        }
    }

    func listEvents(
        sessionId: String,
        after: String?,
        fromSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventForwardPage {
        throw SessionTransportError.invalidRequest
    }

    func listEventsBefore(
        sessionId: String,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventBeforePage {
        throw SessionTransportError.invalidRequest
    }

    func listActions(
        sessionId: String,
        targetSequenceId: Int64?,
        targetActionId: String?,
        limit: Int
    ) async throws -> SessionActionPage {
        throw SessionTransportError.invalidRequest
    }

    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage {
        throw SessionTransportError.invalidRequest
    }
}

@MainActor
final class SessionListCoordinatorTests: XCTestCase {
    func test_refresh_projects_network_rows_and_allows_only_a_visible_selection() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-2", "room-1"], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "forged-room"))
        XCTAssertNil(coordinator.selectedSessionId)
        coordinator.send(.selectSession(sessionId: "room-1"))

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2", "room-1"])
        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertNil(coordinator.state.failure)
        guard case .network = coordinator.state.provenance else {
            return XCTFail("a successful repository refresh must be labeled network")
        }
    }

    func test_load_more_uses_repository_snapshot_and_preserves_order() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-2"], nextCursor: "cursor-1", hasMore: true)),
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        await coordinator.loadMoreSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2", "room-1"])
        XCTAssertFalse(coordinator.state.hasMore)
    }

    func test_network_failure_after_success_keeps_rows_but_labels_cache() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.network)
        ])

        await coordinator.start()?.value
        await coordinator.refreshSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        XCTAssertEqual(coordinator.state.failure, .network)
        guard case .cache(_, let authenticationExpired) = coordinator.state.provenance else {
            return XCTFail("stale rows after a network failure must be labeled cache")
        }
        XCTAssertFalse(authenticationExpired)
    }

    func test_initial_network_failure_has_no_cache_and_no_protected_rows() async {
        let coordinator = makeCoordinator([.failure(.network)])

        await coordinator.start()?.value

        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertEqual(coordinator.state.failure, .offlineNoCache)
        XCTAssertNil(coordinator.selectedSessionId)
        guard case .unavailable = coordinator.state.provenance else {
            return XCTFail("there is no cache until one authorized refresh succeeds")
        }
    }

    func test_refresh_revokes_selection_when_session_leaves_authorized_rows() async throws {
        let selection = SessionSelectionProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .page(try page(ids: ["room-2"], nextCursor: nil, hasMore: false))
        ], onSelectionChanged: { selection.values.append($0) })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "room-1"))
        XCTAssertEqual(coordinator.selectedSessionId, "room-1")

        await coordinator.refreshSessions().value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2"])
        XCTAssertEqual(selection.values, ["room-1", nil],
                       "dial registration must be revoked when the authorized row disappears")
    }

    func test_non_ascii_session_identity_is_rejected_before_selection() async throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: ordinary String comparison is canonical")
        let coordinator = makeCoordinator([
            .page(try page(ids: [composed], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: decomposed))

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertEqual(coordinator.state.failure, .invalidData)
        guard case .unavailable = coordinator.state.provenance else {
            return XCTFail("a non-ASCII wire session identity must fail closed before presentation")
        }
    }

    func test_refresh_replacing_selection_with_distinct_valid_identifier_revokes_authority() async throws {
        let original = "room-Case"
        let replacement = "room-case"
        XCTAssertNotEqual(original, replacement)
        let selection = SessionSelectionProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: [original], nextCursor: nil, hasMore: false)),
            .page(try page(ids: [replacement], nextCursor: nil, hasMore: false)),
        ], onSelectionChanged: { selection.values.append($0) })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: original))
        await coordinator.refreshSessions().value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(selection.values, [original, nil])
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), [replacement])
    }

    func test_service_failure_after_success_keeps_rows_but_revokes_live_provenance() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.service(statusCode: 503))
        ])

        await coordinator.start()?.value
        await coordinator.refreshSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        XCTAssertEqual(coordinator.state.failure, .service)
        guard case .cache = coordinator.state.provenance else {
            return XCTFail("a failed refresh must never leave stale rows labeled as live network data")
        }
    }

    func test_401_clears_rows_selection_and_notifies_authentication_gate() async throws {
        let probe = ReauthenticationProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.reauthenticationRequired)
        ], onReauthenticationRequired: {
            probe.count += 1
        })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "room-1"))
        await coordinator.refreshSessions().value

        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(coordinator.state.failure, .reauthenticationRequired)
        XCTAssertEqual(probe.count, 1)
        guard case .unavailable = coordinator.state.provenance else {
            return XCTFail("protected rows must be unavailable after a 401")
        }
    }

    /// Review of #311: the open panel's re-read never starts over one still going, so a slow link still lands one.
    func test_a_quiet_refresh_never_starts_over_a_read_still_going() async throws {
        let coordinator = makeCoordinator([.page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false))])
        let first = coordinator.refreshSessions()
        let second = coordinator.refreshSessions(quietly: true)
        XCTAssertEqual(first, second, "the read already going is the answer")
        await second.value
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        XCTAssertNil(coordinator.state.failure, "no second request (the transport had one answer)")
    }

    /// Review of #311: a malformed answer to the panel's re-read keeps the room you are in; one you asked for does not.
    func test_a_quiet_refresh_with_a_malformed_answer_keeps_the_room_you_are_in() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.invalidResponse),
            .failure(.invalidResponse)
        ])
        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "room-1"))
        await coordinator.refreshSessions(quietly: true).value
        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        await coordinator.refreshSessions().value
        XCTAssertNil(coordinator.selectedSessionId, "an asked-for refresh still clears it, as before")
    }

    /// Review of #325: the panel's quiet re-read writes nothing when nothing changed, but every change still shows: a new
    /// room, a renamed one, one that left.
    func test_a_quiet_refresh_that_finds_a_change_shows_it() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .page(try page(ids: ["room-2", "room-1"], nextCursor: nil, hasMore: false)),
            .page(try page(ids: ["room-2", "room-1"], titles: ["room-1": "Renamed"], nextCursor: nil, hasMore: false)),
            .page(try page(ids: ["room-2", "room-1"], titles: ["room-1": "Renamed"], unread: ["room-1": 3], nextCursor: nil,
                           hasMore: false)),
            .page(try page(ids: ["room-1"], titles: ["room-1": "Renamed"], unread: ["room-1": 3], nextCursor: nil, hasMore: false))
        ])
        await coordinator.refreshSessions().value
        await coordinator.refreshSessions(quietly: true).value
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2", "room-1"], "a new room shows")
        await coordinator.refreshSessions(quietly: true).value
        XCTAssertEqual(coordinator.state.rows.last?.title, "Renamed", "a new title shows")
        await coordinator.refreshSessions(quietly: true).value
        XCTAssertEqual(coordinator.state.rows.last?.activity.unread, 3, "a new unread count shows")
        await coordinator.refreshSessions(quietly: true).value
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"], "a room that left goes")
    }

    /// Review of #311: the panel re-reads only while it is open and the app is in front.
    func test_the_open_panel_reads_its_rooms_only_with_the_app_in_front() {
        XCTAssertTrue(DrawerPoll(open: true, active: true).runs)
        XCTAssertFalse(DrawerPoll(open: true, active: false).runs, "background audio or a call: no reads")
        XCTAssertFalse(DrawerPoll(open: false, active: true).runs)
        XCTAssertNotEqual(DrawerPoll(open: true, active: true), DrawerPoll(open: true, active: false),
                          "a change of either restarts the loop")
    }

    private func makeCoordinator(
        _ responses: [SessionListMockResponse],
        onReauthenticationRequired: @escaping @MainActor () -> Void = {},
        onSelectionChanged: @escaping @MainActor (String?) -> Void = { _ in }
    ) -> SessionListCoordinator {
        let repository = SessionRepository(
            transport: SessionListMockTransport(responses),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        return SessionListCoordinator(
            repository: repository,
            onReauthenticationRequired: onReauthenticationRequired,
            onSelectionChanged: onSelectionChanged
        )
    }

    private func page(ids: [String], titles: [String: String] = [:], unread: [String: Int] = [:], nextCursor: String?,
                      hasMore: Bool) throws -> SessionListPage {
        let sessions = ids.map { id in
            """
            {"sessionId":"\(id)","status":"active","archiveStatus":"active","visibility":"private",
            "membershipRole":"owner","title":"\(titles[id] ?? id)","summaryText":null,"summaryGeneratedAt":null,
            "summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,"createdAt":null,
            "lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,
            "codebasePath":null,"s3ArchivePath":null\(unread[id].map { #","unread":{"count":\#($0),"firstUnreadSequenceId":100}"# } ?? "")}
            """
        }.joined(separator: ",")
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"sessions":[\(sessions)],"count":\(ids.count),"include_archived":false,
        "next_cursor":\(cursor),"has_more":\(hasMore)}
        """
        return try JSONDecoder().decode(SessionListPage.self, from: Data(json.utf8))
    }
}

@MainActor
private final class ReauthenticationProbe {
    var count = 0
}

@MainActor
private final class SessionSelectionProbe {
    var values: [String?] = []
}
