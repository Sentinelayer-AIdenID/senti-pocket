import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class FakeMint: MintStarting, @unchecked Sendable {
    private let lock = NSLock()
    let models: [MintModel]
    let failure: MintError?
    private var requests: [MintUpRequest] = []

    init(models: [MintModel], failure: MintError? = nil) {
        self.models = models
        self.failure = failure
    }

    func models() async throws -> [MintModel] { models }

    func startAgent(_ request: MintUpRequest) async throws -> MintUpResponse {
        lock.withLock { requests.append(request) }
        if let failure { throw failure }
        return MintUpResponse(lifeId: "life-1", agentName: request.agentName ?? "mint-auto", sessionId: request.sessionId,
                              phase: "booting", consoleURL: nil)
    }

    var sent: [MintUpRequest] { lock.withLock { requests } }
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
        let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: mint) { assigned.append($0) }
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
            let model = TicketAgentModel(ticket: ticket, sessionId: "room-1", mint: FakeMint(models: models, failure: failure)) { _ in
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
