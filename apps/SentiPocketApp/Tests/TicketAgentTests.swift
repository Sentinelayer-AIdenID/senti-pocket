import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class FakeMint: MintStarting, @unchecked Sendable {
    private let lock = NSLock()
    let models: [MintModel]
    let failure: MintError?
    /// Answers for the starts in turn (a failure, or nil to start); after them, `failure` or a start.
    private var script: [MintError?]
    private var requests: [MintUpRequest] = []

    init(models: [MintModel], failure: MintError? = nil, script: [MintError?] = []) {
        self.models = models
        self.failure = failure
        self.script = script
    }

    func models() async throws -> [MintModel] { models }

    func startAgent(_ request: MintUpRequest) async throws -> MintUpResponse {
        let answer = lock.withLock { () -> MintError? in
            requests.append(request)
            return script.isEmpty ? failure : script.removeFirst()
        }
        if let answer { throw answer }
        return MintUpResponse(lifeId: "life-1", agentName: request.agentName ?? "mint-auto", sessionId: request.sessionId,
                              phase: "booting", consoleURL: nil)
    }

    var sent: [MintUpRequest] { lock.withLock { requests } }
}

/// A clock the test moves.
private final class MintClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private final class OneTicket: RoomTicketsTransport, @unchecked Sendable {
    let ticket: RoomTicket
    init(_ ticket: RoomTicket) { self.ticket = ticket }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [ticket], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

private struct NoWrites: RoomTicketWriting {
    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult {
        throw RoomTicketsCoordinatorTestError.unused
    }
}

private enum RoomTicketsCoordinatorTestError: Error { case unused }

/// Writing tickets needs a signed-in account.
private struct SignedIn: AccountIdentityProviding {
    func currentAccount() async -> SignedInAccount? {
        SignedInAccount(githubUsername: "mrrcarter", accountId: "5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f")
    }
}

/// Carter: custom agents for tickets, as on the web.
@MainActor
final class TicketAgentTests: XCTestCase {
    private let ticket = RoomTicketsCoordinator.AgentTicket(
        id: "36d92287-aaaa-bbbb-cccc-000000000000", title: "Breakouts API fix", status: "open", body: "Fix the fixture."
    )
    private let models = [
        MintModel(id: "model-a", label: "Model A", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        MintModel(id: "model-b", label: "Model B")
    ]

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func test_the_form_starts_from_the_ticket_and_starts_an_agent_assigned_to_it() async {
        let mint = FakeMint(models: models)
        var assigned: [String] = []
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: temporaryLedger(),
                                     account: "sub:carter") { assigned.append($0) }
        XCTAssertEqual(model.agentName, "mint-36d92287", "named from the ticket's id, as on the web")
        XCTAssertTrue(model.job.hasPrefix("Ticket: 36d92287-aaaa-bbbb-cccc-000000000000\nTitle: Breakouts API fix"))
        XCTAssertTrue(model.job.contains("Closes-Ticket: 36d92287"))

        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.modelId, "model-a", "the first model")
        XCTAssertEqual(model.effort, "medium", "at its default effort")
        model.select("model-b")
        XCTAssertNil(model.effort, "a model without efforts takes none")
        model.select("model-a")

        await model.start()
        guard case .started(let started) = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(started.agentName, "mint-36d92287")
        XCTAssertEqual(assigned, ["mint-36d92287"], "the ticket is assigned to the agent that started")
        XCTAssertEqual(mint.sent.first?.ticketId, ticket.id)
        XCTAssertEqual(mint.sent.first?.sessionId, "room-1")
        XCTAssertEqual(mint.sent.first?.effort, "medium")
    }

    func test_a_refusal_says_why_and_the_form_can_be_changed_and_sent_again() async {
        for (failure, words) in [(MintError.capacity, "No machine is free"), (.forbidden, "cannot start agents"),
                                 (.refused("agentName taken"), "agentName taken")] {
            let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: FakeMint(models: models, failure: failure),
                                         ledger: temporaryLedger(), account: "sub:carter") { _ in
                XCTFail("nothing is assigned when nothing started")
            }
            await model.load()
            await model.start()
            guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
            XCTAssertTrue(message.contains(words), message)
            model.edit()
            XCTAssertEqual(model.phase, .ready)
        }
    }

    private func temporaryLedger(_ clock: MintClock? = nil) -> MintStartLedger {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mint-starts-\(UUID().uuidString).json")
        guard let clock else { return MintStartLedger(url: url) }
        return MintStartLedger(url: url, now: { clock.date })
    }

    /// Every start carries a key of its own; two starts never share one.
    func test_every_start_carries_its_own_key() async throws {
        let mint = FakeMint(models: models)
        for _ in 0..<2 {
            let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: temporaryLedger(),
                                         account: "sub:carter") { _ in }
            await model.load()
            await model.start()
        }
        let keys = mint.sent.compactMap(\.idempotencyKey)
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertTrue(keys.allSatisfy { $0.count >= 16 && $0.count <= 128 })
    }

    /// The answer to a start was lost: it is not confirmed, never "failed, try again". Checking again sends the very same
    /// start under the very same key, so the mint can only return that agent; once it does, the phone forgets the start.
    func test_a_lost_answer_is_not_confirmed_and_checking_again_resends_the_same_start_under_the_same_key() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = FakeMint(models: models, script: [.notConfirmed, .notConfirmed, nil])
        var assigned: [String] = []
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger,
                                     account: "sub:carter") { assigned.append($0) }
        await model.load()
        await model.start()
        XCTAssertEqual(model.phase, .unconfirmed)
        XCTAssertFalse(model.canStart, "no fresh start while one is unconfirmed")
        XCTAssertTrue(assigned.isEmpty)
        await model.start()
        XCTAssertEqual(mint.sent.count, 1, "Start does nothing while unconfirmed")
        XCTAssertEqual(ledger.pending(account: "sub:carter", sessionId: "room-1", ticketId: ticket.id), mint.sent.first)

        await model.checkAgain()
        XCTAssertEqual(model.phase, .unconfirmed, "still not confirmed")
        await model.checkAgain()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(mint.sent.count, 3)
        XCTAssertEqual(Set(mint.sent.map(\.idempotencyKey)).count, 1, "one key for the one start")
        XCTAssertEqual(mint.sent[2], mint.sent[0], "the same start, exactly")
        XCTAssertEqual(assigned, ["mint-36d92287"])
        XCTAssertNil(ledger.pending(account: "sub:carter", sessionId: "room-1", ticketId: ticket.id), "forgotten once started")
    }

    /// The sheet closed (or the app was killed) on an unconfirmed start: reopening it brings that start back, as it was
    /// sent, to check again; another account on the phone never sees it.
    func test_reopening_brings_the_unconfirmed_start_back_and_another_account_never_sees_it() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let first = FakeMint(models: models, script: [.notConfirmed])
        let closed = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: first, ledger: ledger, account: "sub:carter") { _ in }
        await closed.load()
        closed.select("model-b")
        closed.job = "Edited job"
        await closed.start()
        XCTAssertEqual(closed.phase, .unconfirmed)
        let sentKey = try XCTUnwrap(first.sent.first?.idempotencyKey)

        let second = FakeMint(models: models)
        let reopened = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: second, ledger: ledger, account: "sub:carter") { _ in }
        await reopened.load()
        XCTAssertEqual(reopened.phase, .unconfirmed)
        XCTAssertEqual(reopened.modelId, "model-b")
        XCTAssertEqual(reopened.job, "Edited job")
        await reopened.checkAgain()
        XCTAssertEqual(second.sent.first?.idempotencyKey, sentKey)
        XCTAssertEqual(second.sent.first, first.sent.first)

        let stranger = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: FakeMint(models: models), ledger: ledger,
                                        account: "sub:someone-else") { _ in }
        try? FileManager.default.removeItem(at: ledger.url)
        let again = FakeMint(models: models, script: [.notConfirmed])
        let carter = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: again, ledger: ledger, account: "sub:carter") { _ in }
        await carter.load()
        await carter.start()
        await stranger.load()
        XCTAssertEqual(stranger.phase, .ready, "another account's unconfirmed start is not shown")
    }

    /// A start the phone cannot keep (no record on this phone, no signed-in account, or a write that fails) is never
    /// sent: after a kill its key would be lost (#298 review). Nothing starts, and the person is told so.
    func test_a_start_the_phone_cannot_keep_is_never_sent() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("mint-starts-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let cases: [(String, MintStartLedger?, String?)] = [
            ("no record on this phone", nil, "sub:carter"),
            ("no signed-in account", temporaryLedger(), nil),
            ("the write fails", MintStartLedger(url: blocked), "sub:carter"),
        ]
        for (name, ledger, account) in cases {
            let mint = FakeMint(models: models)
            let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: account) { _ in
                XCTFail("\(name): nothing starts")
            }
            await model.load()
            await model.start()
            XCTAssertTrue(mint.sent.isEmpty, "\(name): not sent")
            XCTAssertEqual(model.phase, .failed(TicketAgentModel.notKeptMessage), name)
        }
    }

    /// #298 review: the mint keeps a key 24 h from its first use and a replay does not extend it. Checks at 10 h and
    /// 23 h never move the start's time; from 23 h it is never sent again (an hour inside the mint's day), and after a
    /// day it is forgotten.
    func test_checking_again_never_outlives_the_mints_key() async throws {
        let clock = MintClock(Date(timeIntervalSince1970: 1_800_000_000))
        let start = clock.date
        let ledger = temporaryLedger(clock)
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = FakeMint(models: models, script: [.notConfirmed, .notConfirmed, .notConfirmed])
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        await model.load()
        await model.start()
        XCTAssertEqual(model.phase, .unconfirmed)

        clock.date = start.addingTimeInterval(10 * 3600)
        await model.checkAgain()
        XCTAssertEqual(mint.sent.count, 2)
        XCTAssertEqual(ledger.entry(account: "sub:carter", sessionId: "room-1", ticketId: ticket.id)?.createdAt, start,
                       "a check never moves the start's time")

        clock.date = start.addingTimeInterval(23 * 3600)
        await model.checkAgain()
        XCTAssertEqual(mint.sent.count, 2, "never sent again within an hour of the mint forgetting its key")
        XCTAssertEqual(model.phase, .unconfirmedTooOld)

        clock.date = start.addingTimeInterval(23.5 * 3600)
        let reopened = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        await reopened.load()
        XCTAssertEqual(reopened.phase, .unconfirmedTooOld)
        await reopened.checkAgain()
        await reopened.start()
        XCTAssertEqual(mint.sent.count, 2, "neither checked nor started again")

        clock.date = start.addingTimeInterval(24 * 3600 + 1)
        let dayLater = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        await dayLater.load()
        XCTAssertEqual(dayLater.phase, .ready, "forgotten after a day")
    }

    /// #298 review: the SAME open sheet, left unconfirmed, checked again only after the record was pruned (a day and a
    /// second later), deleted, or made unreadable. With no record of this very start inside the horizon, it is never
    /// sent: the mint may have forgotten its key.
    func test_an_open_sheet_never_resends_a_start_whose_record_is_gone() async throws {
        for gone in ["pruned after a day", "deleted", "unreadable"] {
            let clock = MintClock(Date(timeIntervalSince1970: 1_800_000_000))
            let ledger = temporaryLedger(clock)
            defer { try? FileManager.default.removeItem(at: ledger.url) }
            let mint = FakeMint(models: models, script: [.notConfirmed])
            let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
            await model.load()
            await model.start()
            XCTAssertEqual(model.phase, .unconfirmed, gone)
            switch gone {
            case "pruned after a day": clock.date = clock.date.addingTimeInterval(24 * 3600 + 1)
            case "deleted": try FileManager.default.removeItem(at: ledger.url)
            default: try Data("not json".utf8).write(to: ledger.url)
            }
            await model.checkAgain()
            XCTAssertEqual(mint.sent.count, 1, "\(gone): never sent again")
            XCTAssertEqual(model.phase, .unconfirmedTooOld, gone)
            XCTAssertNil(ledger.entry(account: "sub:carter", sessionId: "room-1", ticketId: ticket.id),
                         "\(gone): the start is not written back with a new time")
        }
    }

    /// #298 review: two sheets for one ticket. While one start is unresolved, a start from the other sheet takes that
    /// one up instead of making a second; the record refuses to replace it.
    func test_a_second_sheet_takes_up_the_unconfirmed_start_instead_of_making_another() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = FakeMint(models: models, script: [.notConfirmed, .notConfirmed])
        let first = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        let second = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        await first.load()
        await second.load()
        XCTAssertEqual(second.phase, .ready)
        await first.start()
        second.job = "A different job"
        await second.start()
        XCTAssertEqual(mint.sent.count, 1, "no second start")
        XCTAssertEqual(second.phase, .unconfirmed)
        XCTAssertEqual(second.job, mint.sent.first?.jobDescription, "the sheet shows the start it took up")
        await second.checkAgain()
        XCTAssertEqual(mint.sent.map(\.idempotencyKey), [mint.sent[0].idempotencyKey, mint.sent[0].idempotencyKey])

        let other = MintUpRequest(model: "model-a", jobDescription: "Other", sessionId: "room-1", ticketId: ticket.id,
                                  idempotencyKey: "pocket-other-0000000000")
        XCTAssertThrowsError(try ledger.keep(other, account: "sub:carter", sessionId: "room-1", ticketId: ticket.id)) {
            XCTAssertEqual($0 as? MintStartLedger.Refusal, .anotherStartPending)
        }
    }

    /// Killed after the start was kept but before it was sent: it comes back unconfirmed, and checking it again sends it
    /// once, under its own key.
    func test_a_start_kept_but_never_sent_is_sent_once_under_its_key() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let kept = MintUpRequest(model: "model-a", jobDescription: "Kept job", sessionId: "room-1", agentName: "mint-36d92287",
                                 ticketId: ticket.id, ticketTitle: "Breakouts API fix", idempotencyKey: "pocket-kept-00000000000")
        try ledger.keep(kept, account: "sub:carter", sessionId: "room-1", ticketId: ticket.id)
        let mint = FakeMint(models: models)
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: "sub:carter") { _ in }
        await model.load()
        XCTAssertEqual(model.phase, .unconfirmed)
        await model.checkAgain()
        XCTAssertEqual(mint.sent, [kept])
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
    }

    /// A refusal means nothing started under the key: the phone forgets the start.
    func test_a_refusal_forgets_the_start() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: FakeMint(models: models, failure: .capacity),
                                     ledger: ledger, account: "sub:carter") { _ in }
        await model.load()
        await model.start()
        guard case .failed = model.phase else { return XCTFail("expected a failure") }
        XCTAssertNil(ledger.pending(account: "sub:carter", sessionId: "room-1", ticketId: ticket.id))
    }

    func test_the_tickets_offer_starting_agents_only_when_the_mint_admits_the_account() async {
        let roomTicket = RoomTicket(id: "t1", title: "T", body: "b", status: "open", version: 1)
        let admitted = RoomTicketsCoordinator(
            sessionId: "room_1", transport: OneTicket(roomTicket), writer: NoWrites(), identity: SignedIn(),
            canWriteTickets: true, mint: FakeMint(models: models),
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }, onReauthenticationRequired: {}
        )
        admitted.start()
        await admitted.refresh()
        await waitUntil { admitted.state.canStartAgents }
        XCTAssertTrue(admitted.state.canStartAgents)
        admitted.send(.startAgent(ticketId: "t1"))
        XCTAssertEqual(admitted.agentTicket?.id, "t1")
        admitted.stop()

        let refused = RoomTicketsCoordinator(
            sessionId: "room_1", transport: OneTicket(roomTicket), writer: NoWrites(), identity: SignedIn(),
            canWriteTickets: true, mint: FakeMint(models: []),
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }, onReauthenticationRequired: {}
        )
        refused.start()
        await refused.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(refused.state.canStartAgents, "a mint with nothing to offer offers nothing")
        refused.send(.startAgent(ticketId: "t1"))
        XCTAssertNil(refused.agentTicket)
        refused.stop()
    }
}
