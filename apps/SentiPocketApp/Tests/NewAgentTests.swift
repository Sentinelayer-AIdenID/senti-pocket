import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// What both fakes saw, in order: a chat is made before the agent is sent to it.
private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func note(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private final class ScriptedMint: MintStarting, @unchecked Sendable {
    private let lock = NSLock()
    private let offered: [MintModel]
    private let modelsFailure: MintError?
    /// Answers for the starts in turn (a failure, or nil to start); after them, a start.
    private var script: [MintError?]
    private var requests: [MintUpRequest] = []
    private var modelReads = 0
    private let journal: Journal?

    init(models: [MintModel], modelsFailure: MintError? = nil, script: [MintError?] = [], journal: Journal? = nil) {
        self.offered = models
        self.modelsFailure = modelsFailure
        self.script = script
        self.journal = journal
    }

    func models() async throws -> [MintModel] {
        lock.withLock { modelReads += 1 }
        if let modelsFailure { throw modelsFailure }
        return offered
    }

    func startAgent(_ request: MintUpRequest) async throws -> MintUpResponse {
        journal?.note("mint \(request.sessionId)")
        let answer = lock.withLock { () -> MintError? in
            requests.append(request)
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let answer { throw answer }
        return MintUpResponse(lifeId: "life-1", agentName: request.agentName ?? "mint-auto", sessionId: request.sessionId,
                              phase: "booting", consoleURL: nil)
    }

    var sent: [MintUpRequest] { lock.withLock { requests } }
    var reads: Int { lock.withLock { modelReads } }
}

/// The API's room create as a New agent's chat meets it: one room per id for its owner, however often it is sent.
private final class FakeChats: AgentChatCreating, @unchecked Sendable {
    struct Try: Equatable {
        let sessionId: String
        let title: String
        let key: String
    }

    enum Outcome {
        case make
        /// Made, but the answer never came back.
        case makeButLoseAnswer
        case refuse(RoomSendError)
    }

    private let lock = NSLock()
    private var script: [Outcome]
    private var attempts: [Try] = []
    private var made: Set<String> = []
    private let journal: Journal?

    init(script: [Outcome] = [], journal: Journal? = nil) {
        self.script = script
        self.journal = journal
    }

    func createAgentChat(sessionId: String, title: String, idempotencyKey: String) async throws {
        journal?.note("chat \(sessionId)")
        let outcome = lock.withLock { () -> Outcome in
            attempts.append(Try(sessionId: sessionId, title: title, key: idempotencyKey))
            let next = script.isEmpty ? .make : script.removeFirst()
            if case .refuse = next { return next }
            made.insert(sessionId)
            return next
        }
        switch outcome {
        case .make: return
        case .makeButLoseAnswer: throw RoomSendError.retryable(retryAfterSeconds: nil)
        case .refuse(let error): throw error
        }
    }

    var tries: [Try] { lock.withLock { attempts } }
    var rooms: Set<String> { lock.withLock { made } }
}

/// Carter: "I don't think I see a new agent button on mobile, put that." The room's New agent, as on the web: a start in
/// this chat or in a new private chat, kept on the phone before it is sent, like a ticket's agent.
@MainActor
final class NewAgentTests: XCTestCase {
    private let models = [
        MintModel(id: "model-a", label: "Model A", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        MintModel(id: "model-b", label: "Model B")
    ]
    private let account = "sub:carter"

    private func temporaryLedger() -> MintStartLedger {
        MintStartLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("mint-starts-\(UUID().uuidString).json"))
    }

    private func newAgent(_ mint: ScriptedMint, chats: FakeChats?, ledger: MintStartLedger?,
                          onStarted: @escaping @MainActor (MintUpResponse) -> Void = { _ in }) -> AgentStartModel {
        AgentStartModel(newAgentIn: "room-1", mint: mint, chats: chats, ledger: ledger, account: account, onStarted: onStarted)
    }

    func test_a_plain_start_goes_to_this_room_with_no_ticket_under_its_own_key() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats()
        var started: [MintUpResponse] = []
        let model = newAgent(mint, chats: chats, ledger: ledger) { started.append($0) }
        XCTAssertEqual(model.agentName, "", "the mint names it when no name is given")
        XCTAssertEqual(model.job, "", "the job starts empty")

        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.place, .thisChat, "this chat, as the web preselects")
        XCTAssertEqual(model.effort, "medium")
        XCTAssertFalse(model.canStart, "no job, no start")
        await model.start()
        XCTAssertTrue(mint.sent.isEmpty)

        model.job = "  Review the onboarding PR.  "
        await model.start()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        let sent = try XCTUnwrap(mint.sent.first)
        XCTAssertEqual(mint.sent.count, 1)
        XCTAssertEqual(sent.sessionId, "room-1")
        XCTAssertEqual(sent.jobDescription, "Review the onboarding PR.")
        XCTAssertNil(sent.agentName)
        XCTAssertNil(sent.ticketId)
        XCTAssertNil(sent.body["ticket"], "no ticket goes with it")
        XCTAssertEqual(sent.effort, "medium")
        XCTAssertTrue(sent.idempotencyKey?.hasPrefix("pocket-") == true)
        XCTAssertTrue(chats.tries.isEmpty, "no chat is made for a start in this chat")
        XCTAssertNil(model.startedChat)
        XCTAssertEqual(started.map(\.agentName), ["mint-auto"])
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil), "forgotten once started")
    }

    func test_a_start_in_a_new_chat_makes_the_chat_first_and_sends_the_agent_there() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let journal = Journal()
        let mint = ScriptedMint(models: models, journal: journal)
        let chats = FakeChats(journal: journal)
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        XCTAssertTrue(model.offersNewChat)
        model.agentName = "reviewer"
        model.job = "Review the onboarding PR and report in the room."
        model.place = .newChat
        await model.start()

        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        let chat = try XCTUnwrap(chats.tries.first)
        XCTAssertEqual(chats.tries.count, 1)
        XCTAssertNotEqual(chat.sessionId, "room-1")
        XCTAssertEqual(chat.title, "reviewer · Review the onboarding PR and report in the room.")
        XCTAssertTrue(chat.key.hasPrefix("create-"))
        XCTAssertEqual(mint.sent.map(\.sessionId), [chat.sessionId], "the agent goes to the new chat")
        XCTAssertEqual(journal.all, ["chat \(chat.sessionId)", "mint \(chat.sessionId)"], "the chat is made first")
        XCTAssertEqual(model.startedChat?.sessionId, chat.sessionId)
        XCTAssertEqual(model.startedChat?.title, chat.title)
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil), "forgotten once started")

        // The same start in this chat makes no chat.
        let here = newAgent(ScriptedMint(models: models), chats: chats, ledger: ledger)
        await here.load()
        here.job = "Stay here."
        await here.start()
        XCTAssertEqual(chats.tries.count, 1)
    }

    /// Only the room's New agent offers a new chat, and only with a way to make one.
    func test_a_new_chat_is_offered_only_where_one_can_be_made() async {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = ScriptedMint(models: models)
        let model = newAgent(mint, chats: nil, ledger: ledger)
        await model.load()
        XCTAssertFalse(model.offersNewChat)
        model.place = .newChat
        model.job = "Do it."
        await model.start()
        XCTAssertEqual(mint.sent.first?.sessionId, "room-1", "without a way to make chats, it starts here")

        let ticket = AgentStartModel(
            ticket: RoomTicketsCoordinator.AgentTicket(id: "t1", title: "T", status: "open", body: "b"),
            sessionId: "room-1", mint: mint, ledger: ledger, account: account
        ) { _ in }
        XCTAssertFalse(ticket.offersNewChat, "a ticket's agent works in the ticket's room")
    }

    /// The web: "The new chat was created, but the agent was not minted ... Minting again uses that chat." Refused, the
    /// start is forgotten like a ticket's (its key never started anything), but its chat is kept: trying again, from this
    /// sheet or a reopened one, sends the agent there, and no second chat is made.
    func test_a_new_chat_is_made_once_when_the_mint_refuses_and_the_start_is_tried_again() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = ScriptedMint(models: models, script: [.capacity, .refused("busy"), nil])
        let chats = FakeChats()
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.agentName = "reviewer"
        model.job = "Review it."
        model.place = .newChat
        await model.start()

        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure: \(model.phase)") }
        XCTAssertTrue(message.contains("No machine is free"), message)
        XCTAssertTrue(message.contains("The new chat is made; starting again uses it."), message)
        let chat = try XCTUnwrap(chats.tries.first)
        let kept = try XCTUnwrap(ledger.entry(account: account, sessionId: "room-1", ticketId: nil))
        XCTAssertNil(kept.request, "nothing started under the refused key")
        XCTAssertEqual(kept.chat?.sessionId, chat.sessionId)
        XCTAssertEqual(kept.chat?.made, true)
        XCTAssertEqual(model.keptChat?.sessionId, chat.sessionId)

        model.edit()
        model.job = "Review it, then report."
        await model.start()
        guard case .failed = model.phase else { return XCTFail("expected a failure: \(model.phase)") }

        // Closed and opened again (or after a kill): the kept chat is still the one.
        let reopened = newAgent(mint, chats: chats, ledger: ledger)
        await reopened.load()
        XCTAssertEqual(reopened.phase, .ready)
        XCTAssertEqual(reopened.keptChat?.sessionId, chat.sessionId)
        reopened.job = "Review it."
        reopened.place = .newChat
        await reopened.start()

        guard case .started = reopened.phase else { return XCTFail("not started: \(reopened.phase)") }
        XCTAssertEqual(chats.tries.count, 1, "never a second chat")
        XCTAssertEqual(mint.sent.map(\.sessionId), Array(repeating: chat.sessionId, count: 3))
        XCTAssertEqual(Set(mint.sent.compactMap(\.idempotencyKey)).count, 3, "a refused start's key is not sent again")
        XCTAssertEqual(reopened.startedChat?.sessionId, chat.sessionId)
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil))
    }

    /// The create's answer was lost: the chat may exist. The mint is never asked first, and the next try sends the very
    /// same create (id, title, key), which the API answers for the same chat.
    func test_a_chat_whose_answer_was_lost_is_made_again_under_the_same_id_and_key() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats(script: [.makeButLoseAnswer])
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()

        XCTAssertEqual(model.phase, .failed(AgentStartModel.chatMessage(RoomSendError.retryable(retryAfterSeconds: nil))))
        XCTAssertTrue(mint.sent.isEmpty, "no agent before its chat is made")
        let kept = try XCTUnwrap(ledger.entry(account: account, sessionId: "room-1", ticketId: nil))
        XCTAssertNil(kept.request)
        XCTAssertEqual(kept.chat?.made, false)

        model.edit()
        model.agentName = "a-new-name"
        await model.start()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        let chat = try XCTUnwrap(chats.tries.first)
        XCTAssertEqual(chats.tries, [chat, chat], "the same create again: id, title and key")
        XCTAssertEqual(chats.rooms, [chat.sessionId], "one chat")
        XCTAssertEqual(mint.sent.map(\.sessionId), [chat.sessionId])
    }

    /// Killed after the start and its chat were kept, before the chat was made: the start comes back unconfirmed, and
    /// checking it again makes that chat, under its kept id and key, then sends the kept start.
    func test_a_start_killed_before_its_chat_was_made_makes_that_chat_once_and_sends_the_kept_start() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let chat = MintStartLedger.NewChat(sessionId: "chat-kept", title: "reviewer · Kept job", createKey: "create-kept", made: false)
        let kept = MintUpRequest(model: "model-b", jobDescription: "Kept job", sessionId: "chat-kept", agentName: "reviewer",
                                 idempotencyKey: "pocket-kept-00000000000")
        try ledger.keep(kept, chat: chat, account: account, sessionId: "room-1", ticketId: nil)

        let mint = ScriptedMint(models: models)
        let chats = FakeChats()
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        XCTAssertEqual(model.phase, .unconfirmed)
        XCTAssertEqual(model.place, .newChat, "it shows where it was sent")
        XCTAssertEqual(model.modelId, "model-b")
        XCTAssertEqual(model.job, "Kept job")
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertTrue(chats.tries.isEmpty && mint.sent.isEmpty, "Start does nothing while unconfirmed")

        await model.checkAgain()
        XCTAssertEqual(chats.tries, [FakeChats.Try(sessionId: "chat-kept", title: "reviewer · Kept job", key: "create-kept")])
        XCTAssertEqual(mint.sent, [kept])
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
    }

    /// The answer to a start in a new chat was lost: checking again, even after a kill, sends the same start under the
    /// same key to the same chat, and makes no chat again.
    func test_an_unconfirmed_start_in_a_new_chat_is_checked_again_without_another_chat() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let mint = ScriptedMint(models: models, script: [.notConfirmed, .notConfirmed])
        let chats = FakeChats()
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()
        XCTAssertEqual(model.phase, .unconfirmed)
        await model.checkAgain()
        XCTAssertEqual(model.phase, .unconfirmed)

        let reopened = newAgent(mint, chats: chats, ledger: ledger)
        await reopened.load()
        XCTAssertEqual(reopened.phase, .unconfirmed)
        await reopened.checkAgain()
        guard case .started = reopened.phase else { return XCTFail("not started: \(reopened.phase)") }
        let chat = try XCTUnwrap(chats.tries.first)
        XCTAssertEqual(chats.tries.count, 1, "made once")
        XCTAssertEqual(mint.sent.count, 3)
        XCTAssertEqual(Set(mint.sent.compactMap(\.idempotencyKey)).count, 1, "one key for the one start")
        XCTAssertEqual(Set(mint.sent.map(\.sessionId)), [chat.sessionId])
        XCTAssertEqual(reopened.startedChat?.sessionId, chat.sessionId)
    }

    /// A start the phone cannot keep is never sent, and no chat is made for it.
    func test_a_new_chat_start_the_phone_cannot_keep_makes_no_chat_and_sends_nothing() async {
        for (name, ledger, account) in [("no record on this phone", nil, "sub:carter"), ("no signed-in account", temporaryLedger(), nil)]
            as [(String, MintStartLedger?, String?)] {
            let mint = ScriptedMint(models: models)
            let chats = FakeChats()
            let model = AgentStartModel(newAgentIn: "room-1", mint: mint, chats: chats, ledger: ledger, account: account)
            await model.load()
            model.job = "Review it."
            model.place = .newChat
            await model.start()
            XCTAssertEqual(model.phase, .failed(AgentStartModel.notKeptMessage), name)
            XCTAssertTrue(chats.tries.isEmpty, "\(name): no chat")
            XCTAssertTrue(mint.sent.isEmpty, "\(name): not sent")
        }
    }

    /// The web shows New agent to admins only. Here: the room's owners and admins, outside a breakout, once the mint lists
    /// models for the account; anyone else never asks the mint.
    func test_new_agent_is_offered_only_to_owners_and_admins_the_mint_admits() async {
        for role in ["owner", "admin", "Owner", "ADMIN"] {
            let mint = ScriptedMint(models: models)
            let offer = NewAgentOffer(role: role, isBreakout: false, mint: mint)
            XCTAssertFalse(offer.isOffered, "\(role): not before the mint answers")
            await offer.check()
            XCTAssertTrue(offer.isOffered, role)
            await offer.check()
            XCTAssertEqual(mint.reads, 1, "\(role): asked once")
        }
        for (role, breakout) in [("contributor", false), ("viewer", false), ("", false), ("member", false), ("owner", true),
                                 ("admin", true)] {
            let mint = ScriptedMint(models: models)
            let offer = NewAgentOffer(role: role, isBreakout: breakout, mint: mint)
            await offer.check()
            XCTAssertFalse(offer.isOffered, "\(role), breakout \(breakout)")
            XCTAssertEqual(mint.reads, 0, "\(role), breakout \(breakout): never asks the mint")
        }
        for (name, mint) in [("no models", ScriptedMint(models: [])), ("not admitted", ScriptedMint(models: models, modelsFailure: .forbidden)),
                             ("unreachable", ScriptedMint(models: models, modelsFailure: .unavailable))] {
            let offer = NewAgentOffer(role: "owner", isBreakout: false, mint: mint)
            await offer.check()
            XCTAssertFalse(offer.isOffered, name)
        }
        let noMint = NewAgentOffer(role: "owner", isBreakout: false, mint: nil)
        await noMint.check()
        XCTAssertFalse(noMint.isOffered, "a build without a mint offers no agents")
    }

    /// A ticket's start and the room's New agent are kept apart: an unconfirmed one does not hold up the other.
    func test_a_ticket_start_and_the_rooms_new_agent_are_kept_apart() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let ticket = RoomTicketsCoordinator.AgentTicket(id: "t1", title: "T", status: "open", body: "b")
        let ticketMint = ScriptedMint(models: models, script: [.notConfirmed])
        let forTicket = AgentStartModel(ticket: ticket, sessionId: "room-1", mint: ticketMint, ledger: ledger, account: account) { _ in }
        await forTicket.load()
        await forTicket.start()
        XCTAssertEqual(forTicket.phase, .unconfirmed)

        let roomMint = ScriptedMint(models: models)
        let model = newAgent(roomMint, chats: FakeChats(), ledger: ledger)
        await model.load()
        XCTAssertEqual(model.phase, .ready, "the ticket's start is not taken up here")
        model.job = "Something else."
        await model.start()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertNil(roomMint.sent.first?.ticketId)
        XCTAssertEqual(ledger.pending(account: account, sessionId: "room-1", ticketId: "t1"), ticketMint.sent.first,
                       "the ticket's start is still kept")
    }

    /// A ticket's start kept on the phone by the version before New agent (no chat in its record) is still found and
    /// checked again under its key: the ticket path's record and its slot are unchanged.
    func test_a_ticket_start_kept_before_new_agent_is_still_taken_up() async throws {
        let ledger = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: ledger.url) }
        let ticket = RoomTicketsCoordinator.AgentTicket(id: "36d92287-aaaa-bbbb-cccc-000000000000", title: "T", status: "open", body: "b")
        let old = MintUpRequest(model: "model-a", jobDescription: "Kept job", sessionId: "room-1", agentName: "mint-36d92287",
                                ticketId: ticket.id, ticketTitle: "T", idempotencyKey: "pocket-old-000000000000")
        struct OldEntry: Encodable {
            let request: MintUpRequest
            let createdAt: Date
        }
        try JSONEncoder().encode(["\(account)|room-1|\(ticket.id)": OldEntry(request: old, createdAt: Date())]).write(to: ledger.url)

        let mint = ScriptedMint(models: models)
        let model = AgentStartModel(ticket: ticket, sessionId: "room-1", mint: mint, ledger: ledger, account: account) { _ in }
        await model.load()
        XCTAssertEqual(model.phase, .unconfirmed)
        await model.checkAgain()
        XCTAssertEqual(mint.sent, [old])
    }

    func test_the_new_chat_is_titled_for_the_agent_as_on_the_web() {
        XCTAssertEqual(NewAgentChat.title(agentName: "reviewer", job: "Fix\nthe   paste\tbug"), "reviewer · Fix the paste bug")
        XCTAssertEqual(NewAgentChat.title(agentName: "", job: ""), "New agent")
        XCTAssertEqual(NewAgentChat.title(agentName: "  ", job: "Do it"), "New agent · Do it")
        XCTAssertEqual(NewAgentChat.title(agentName: "rev\u{7}iewer", job: ""), "rev iewer", "control characters out")
        XCTAssertEqual(NewAgentChat.title(agentName: "r", job: String(repeating: "a", count: 100)),
                       "r · " + String(repeating: "a", count: 60), "the job's first 60 characters")
        XCTAssertEqual(NewAgentChat.title(agentName: String(repeating: "n", count: 90), job: "x").count, 80, "the room-title cap")
        XCTAssertEqual(NewAgentChat.title(agentName: "- bullet", job: "Do it"), "New agent · Do it",
                       "a name the API would refuse as a title is left out")
        XCTAssertNotNil(RoomTitle.cleaned(NewAgentChat.title(agentName: "reviewer", job: String(repeating: "é ", count: 50))))
    }
}
