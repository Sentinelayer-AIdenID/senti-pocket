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
    /// Answers for the model lists in turn (a failure, or nil for the list); after them, `modelsFailure` or the list.
    private var modelsScript: [MintError?]
    /// Answers for the starts in turn (a failure, or nil to start); after them, a start.
    private var script: [MintError?]
    private var requests: [MintUpRequest] = []
    private var modelReads = 0
    private let journal: Journal?

    init(models: [MintModel], modelsFailure: MintError? = nil, modelsScript: [MintError?] = [], script: [MintError?] = [],
         journal: Journal? = nil) {
        self.offered = models
        self.modelsFailure = modelsFailure
        self.modelsScript = modelsScript
        self.script = script
        self.journal = journal
    }

    func models() async throws -> [MintModel] {
        let answer = lock.withLock { () -> MintError? in
            modelReads += 1
            return modelsScript.isEmpty ? modelsFailure : modelsScript.removeFirst()
        }
        if let answer { throw answer }
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
    /// Runs inside the next create, before it answers.
    private var during: (@Sendable () -> Void)?

    init(script: [Outcome] = [], journal: Journal? = nil) {
        self.script = script
        self.journal = journal
    }

    func onNextCreate(_ run: @escaping @Sendable () -> Void) { lock.withLock { during = run } }

    func createAgentChat(sessionId: String, title: String, idempotencyKey: String) async throws {
        journal?.note("chat \(sessionId)")
        let run = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { during = nil }
            return during
        }
        run?()
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

    /// Renames asked for, in order, and whether they are refused.
    private var renames: [Try] = []
    private var refuses = false

    func refuseRenames() { lock.withLock { refuses = true } }

    func nameAgentChat(sessionId: String, title: String) async throws {
        let refused = lock.withLock { () -> Bool in
            renames.append(Try(sessionId: sessionId, title: title, key: ""))
            return refuses
        }
        if refused { throw RoomSendError.notAllowed }
    }

    var named: [Try] { lock.withLock { renames } }
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

    /// The starts and the new chats.
    private func remove(_ ledger: MintStartLedger) {
        try? FileManager.default.removeItem(at: ledger.url)
        try? FileManager.default.removeItem(at: ledger.chatsURL)
    }

    /// No waiting between asks.
    private func makeOffer(_ role: String, breakout: Bool = false, mint: ScriptedMint?) -> NewAgentOffer {
        NewAgentOffer(role: role, isBreakout: breakout, mint: mint, sleep: { _ in })
    }

    private func newAgent(_ mint: ScriptedMint, chats: FakeChats?, ledger: MintStartLedger?,
                          onStarted: @escaping @MainActor (MintUpResponse) -> Void = { _ in }) -> AgentStartModel {
        AgentStartModel(newAgentIn: "room-1", mint: mint, chats: chats, ledger: ledger, account: account, onStarted: onStarted)
    }

    /// The check under New agent and Start agent: without the signed-in account's consent to share with AI the mint is
    /// never asked.
    func test_an_agent_is_never_started_without_the_ai_consent() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let suite = "consent-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let consent = AIConsent(account: "sub:consent-test", defaults: UserDefaults(suiteName: suite)!)
        AIConsentAsker.shared.consent = consent
        defer { AIConsentAsker.shared.consent = nil }
        let mint = ScriptedMint(models: models)
        let model = newAgent(mint, chats: FakeChats(), ledger: ledger) { _ in }
        await model.load()
        model.job = "Review the onboarding PR."
        await model.start()
        XCTAssertTrue(mint.sent.isEmpty, "not agreed: nothing goes to the mint")
        XCTAssertEqual(model.phase, .failed(AgentStartModel.consentMessage))

        consent.grant()
        let agreed = newAgent(mint, chats: FakeChats(), ledger: ledger) { _ in }
        await agreed.load()
        agreed.job = "Review the onboarding PR."
        await agreed.start()
        XCTAssertEqual(mint.sent.count, 1, "agreed: it starts")
    }

    func test_a_plain_start_goes_to_this_room_with_no_ticket_under_its_own_key() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
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
        defer { remove(ledger) }
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
        XCTAssertEqual(NewAgentSheet.chatToOpen(model.phase, startedChat: model.startedChat),
                       RoomRoute(sessionId: chat.sessionId, title: chat.title, membershipRole: "owner"),
                       "Pocket goes to the new chat by itself, as its owner")
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil), "forgotten once started")

        // The same start in this chat makes no chat.
        let here = newAgent(ScriptedMint(models: models), chats: chats, ledger: ledger)
        await here.load()
        here.job = "Stay here."
        XCTAssertNil(NewAgentSheet.chatToOpen(here.phase, startedChat: here.startedChat), "nothing to open before a start")
        await here.start()
        XCTAssertEqual(chats.tries.count, 1)
        XCTAssertNil(NewAgentSheet.chatToOpen(here.phase, startedChat: here.startedChat), "a start in this chat stays here")
    }

    /// Only the room's New agent offers a new chat, and only with a way to make one.
    func test_a_new_chat_is_offered_only_where_one_can_be_made() async {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
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
        defer { remove(ledger) }
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
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil), "nothing started under the refused key")
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1")?.sessionId, chat.sessionId)
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1")?.made, true)
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
        XCTAssertNil(ledger.chat(account: account, sessionId: "room-1"), "forgotten once an agent started in it")
    }

    /// The create's answer was lost: the chat may exist. The mint is never asked first, and the next try sends the very
    /// same create (id, title, key), which the API answers for the same chat.
    func test_a_chat_whose_answer_was_lost_is_made_again_under_the_same_id_and_key() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats(script: [.makeButLoseAnswer])
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()

        XCTAssertEqual(model.phase, .failed(AgentStartModel.chatMessage(RoomSendError.retryable(retryAfterSeconds: nil))))
        XCTAssertTrue(mint.sent.isEmpty, "no agent before its chat is made")
        XCTAssertNil(ledger.entry(account: account, sessionId: "room-1", ticketId: nil), "the mint was never asked")
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1")?.made, false)

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
        defer { remove(ledger) }
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
        defer { remove(ledger) }
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
    /// Review (R13): a check again whose new chat's record is gone sends nothing. Whether that chat was made is not
    /// known, so the start is never sent again.
    func test_a_check_again_whose_new_chat_record_is_gone_sends_nothing() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let mint = ScriptedMint(models: models, script: [.notConfirmed])
        let model = newAgent(mint, chats: FakeChats(), ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()
        XCTAssertEqual(model.phase, .unconfirmed)
        XCTAssertEqual(mint.sent.count, 1)

        try FileManager.default.removeItem(at: ledger.chatsURL)
        await model.checkAgain()
        XCTAssertEqual(model.phase, .unconfirmedTooOld)
        XCTAssertEqual(mint.sent.count, 1, "the start is not sent again")
    }

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
            let offer = makeOffer(role, mint: mint)
            XCTAssertFalse(offer.isOffered, "\(role): not before the mint answers")
            await offer.check()
            XCTAssertTrue(offer.isOffered, role)
            await offer.check()
            XCTAssertEqual(mint.reads, 1, "\(role): asked once")
        }
        for (role, breakout) in [("contributor", false), ("viewer", false), ("", false), ("member", false), ("owner", true),
                                 ("admin", true)] {
            let mint = ScriptedMint(models: models)
            let offer = makeOffer(role, breakout: breakout, mint: mint)
            await offer.check()
            XCTAssertFalse(offer.isOffered, "\(role), breakout \(breakout)")
            XCTAssertEqual(mint.reads, 0, "\(role), breakout \(breakout): never asks the mint")
        }
        for (name, mint) in [("no models", ScriptedMint(models: [])), ("not admitted", ScriptedMint(models: models, modelsFailure: .forbidden)),
                             ("unreachable", ScriptedMint(models: models, modelsFailure: .unavailable))] {
            let offer = makeOffer("owner", mint: mint)
            await offer.check()
            XCTAssertFalse(offer.isOffered, name)
        }
        let noMint = makeOffer("owner", mint: nil)
        await noMint.check()
        XCTAssertFalse(noMint.isOffered, "a build without a mint offers no agents")
    }

    /// A ticket's start and the room's New agent are kept apart: an unconfirmed one does not hold up the other.
    func test_a_ticket_start_and_the_rooms_new_agent_are_kept_apart() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
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
        defer { remove(ledger) }
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

    /// Carter, #61655: a chat made for an agent is never called "New agent". It is the agent's name and its job, the job
    /// alone while the mint has the name to make, or the name alone.
    func test_the_new_chat_is_titled_for_the_agent_never_new_agent() throws {
        XCTAssertEqual(NewAgentChat.title(agentName: "reviewer", job: "Fix\nthe   paste\tbug"), "reviewer · Fix the paste bug")
        XCTAssertEqual(NewAgentChat.title(agentName: "  ", job: "Do it"), "Do it", "no name: the job alone")
        XCTAssertEqual(NewAgentChat.title(agentName: "", job: "Fix the build and report"), "Fix the build and report")
        XCTAssertEqual(NewAgentChat.title(agentName: "rev\u{7}iewer", job: ""), "rev iewer", "control characters out")
        XCTAssertEqual(NewAgentChat.title(agentName: "r", job: String(repeating: "a", count: 100)),
                       "r · " + String(repeating: "a", count: 60), "the job's first 60 characters")
        XCTAssertEqual(NewAgentChat.title(agentName: "", job: String(repeating: "a", count: 100)),
                       String(repeating: "a", count: 60), "the job's first 60 characters alone")
        XCTAssertEqual(NewAgentChat.title(agentName: String(repeating: "n", count: 90), job: "x")?.count, 80, "the room-title cap")
        XCTAssertEqual(NewAgentChat.title(agentName: "- bullet", job: "Do it"), "Do it",
                       "a name the API would refuse as a title is left out")
        XCTAssertEqual(NewAgentChat.title(agentName: "", job: "- fix the build\n- report"), "fix the build - report",
                       "a job written as a list loses the marks a title may not start with")
        XCTAssertEqual(NewAgentChat.title(agentName: "build-agent", job: "## Fix"), "build-agent · Fix")
        XCTAssertNil(NewAgentChat.title(agentName: "", job: ""), "neither: the mint names the chat")
        XCTAssertNil(NewAgentChat.title(agentName: " ", job: "\u{1}\u{2} #"), "neither, once marks and control characters go")
        XCTAssertNotNil(RoomTitle.cleaned(try XCTUnwrap(
            NewAgentChat.title(agentName: "reviewer", job: String(repeating: "é ", count: 50)))))
        for (name, job) in [("", "Do it"), ("reviewer", ""), ("- x", "y"), ("", "> quoted job")] {
            XCTAssertFalse(NewAgentChat.title(agentName: name, job: job)?.contains("New agent") ?? false, "\(name) / \(job)")
        }
        XCTAssertFalse(NewAgentChat.untitled.contains("New agent"))
    }

    /// No name and no words for a title: the chat is made as `untitled`, then takes the name the mint gave its agent, and
    /// Pocket opens it under that name. A rename that does not go through leaves the agent started and the chat as made.
    func test_a_chat_with_neither_name_nor_job_words_takes_the_agents_name_from_the_mint() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats()
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "#"
        model.place = .newChat
        await model.start()

        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        let chat = try XCTUnwrap(chats.tries.first)
        XCTAssertEqual(chat.title, NewAgentChat.untitled, "made before the mint names the agent")
        XCTAssertEqual(chats.named, [FakeChats.Try(sessionId: chat.sessionId, title: "mint-auto", key: "")],
                       "renamed to the name the mint gave")
        XCTAssertEqual(model.startedChat?.title, "mint-auto")
        XCTAssertEqual(NewAgentSheet.chatToOpen(model.phase, startedChat: model.startedChat)?.title, "mint-auto")

        // A named start's chat is never renamed.
        let named = newAgent(ScriptedMint(models: models), chats: chats, ledger: ledger)
        await named.load()
        named.agentName = "build-agent"
        named.job = "Fix it."
        named.place = .newChat
        await named.start()
        XCTAssertEqual(chats.named.count, 1)
        XCTAssertEqual(named.startedChat?.title, "build-agent · Fix it.")

        // Refused: the agent started all the same, in the chat as it was made.
        let refusedChats = FakeChats()
        refusedChats.refuseRenames()
        let refused = newAgent(ScriptedMint(models: models), chats: refusedChats, ledger: ledger)
        await refused.load()
        refused.job = "*"
        refused.place = .newChat
        await refused.start()
        guard case .started = refused.phase else { return XCTFail("not started: \(refused.phase)") }
        XCTAssertEqual(refusedChats.named.count, 1)
        XCTAssertEqual(refused.startedChat?.title, NewAgentChat.untitled)
    }

    /// #303 review: a check again that the mint refuses (sign-in, capacity, a refusal, not admitted) may follow a first
    /// send that did start the agent. The start stays kept as it was, Start never makes a new key, and a later check
    /// (from this sheet, or after a kill) still goes under the one key, to the one chat.
    func test_a_refused_check_again_keeps_the_start_under_its_key() async throws {
        for refusal in [MintError.reauthenticationRequired, .capacity, .refused("model gone"), .forbidden] {
            for newChat in [false, true] {
                let name = "\(refusal), new chat \(newChat)"
                let ledger = temporaryLedger()
                defer { remove(ledger) }
                let mint = ScriptedMint(models: models, script: [.notConfirmed, refusal])
                let chats = FakeChats()
                let model = newAgent(mint, chats: chats, ledger: ledger)
                await model.load()
                model.job = "Review it."
                if newChat { model.place = .newChat }
                await model.start()
                XCTAssertEqual(model.phase, .unconfirmed, name)
                await model.checkAgain()

                XCTAssertEqual(model.phase, .unconfirmed, "\(name): still not confirmed")
                XCTAssertEqual(model.checkProblem, AgentStartModel.message(refusal), name)
                XCTAssertEqual(ledger.pending(account: account, sessionId: "room-1", ticketId: nil), mint.sent.first,
                               "\(name): the start stays kept")
                model.edit()
                await model.start()
                XCTAssertEqual(mint.sent.count, 2, "\(name): Start sends nothing new")

                let reopened = newAgent(mint, chats: chats, ledger: ledger)
                await reopened.load()
                XCTAssertEqual(reopened.phase, .unconfirmed, name)
                await reopened.checkAgain()
                guard case .started = reopened.phase else {
                    XCTFail("\(name): not started: \(reopened.phase)")
                    continue
                }
                XCTAssertEqual(mint.sent.count, 3, name)
                XCTAssertTrue(mint.sent.allSatisfy { $0 == mint.sent.first }, "\(name): the one start, under its one key")
                XCTAssertEqual(chats.tries.count, newChat ? 1 : 0, "\(name): one chat at most")
            }
        }
    }

    /// A check again whose new chat cannot be made (refused, or its answer lost) keeps the start as it is: it was kept
    /// before a kill, so its first send may have gone out. The chat is asked for under its kept id and key until it is
    /// made, and only then is the start sent again.
    func test_a_check_again_whose_chat_cannot_be_made_keeps_the_start() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let chat = MintStartLedger.NewChat(sessionId: "chat-kept", title: "Kept job", createKey: "create-kept", made: false)
        let kept = MintUpRequest(model: "model-a", jobDescription: "Kept job", sessionId: "chat-kept",
                                 idempotencyKey: "pocket-kept-00000000000")
        try ledger.keep(kept, chat: chat, account: account, sessionId: "room-1", ticketId: nil)
        let mint = ScriptedMint(models: models)
        let chats = FakeChats(script: [.refuse(.rejected), .makeButLoseAnswer])
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        XCTAssertEqual(model.phase, .unconfirmed)

        for _ in 0..<2 {
            await model.checkAgain()
            XCTAssertEqual(model.phase, .unconfirmed)
            XCTAssertEqual(model.checkProblem, "The new chat could not be reached.")
            XCTAssertEqual(ledger.pending(account: account, sessionId: "room-1", ticketId: nil), kept, "the start stays kept")
        }
        XCTAssertTrue(mint.sent.isEmpty, "no agent before its chat is made")
        await model.checkAgain()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(chats.tries, Array(repeating: FakeChats.Try(sessionId: "chat-kept", title: "Kept job", key: "create-kept"),
                                          count: 3))
        XCTAssertEqual(mint.sent, [kept])
    }

    /// #303 review: the chat is made but the phone cannot record that. The agent is not sent (a hard failure); the next
    /// try asks for that same chat again, under its kept id and key, and the start goes out once, under one key.
    func test_a_made_chat_that_cannot_be_recorded_sends_nothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mint-starts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let ledger = MintStartLedger(url: folder.appendingPathComponent("mint-starts.json"))
        let mint = ScriptedMint(models: models)
        let chats = FakeChats()
        let path = folder.path
        // The phone's record stops taking writes while the chat is being made.
        chats.onNextCreate { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path) }
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()
        XCTAssertEqual(model.phase, .failed(AgentStartModel.chatNotRecordedMessage))
        XCTAssertTrue(mint.sent.isEmpty, "not sent while the made chat is not recorded")
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1")?.made, false)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        model.edit()
        await model.start()
        // The start could not be forgotten while writes failed, so it comes back unconfirmed and is checked again.
        if model.phase == .unconfirmed { await model.checkAgain() }
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(chats.tries.count, 2)
        XCTAssertEqual(chats.tries.last, chats.tries.first, "the same chat asked for again: id, title and key")
        XCTAssertEqual(mint.sent.count, 1)
        XCTAssertEqual(mint.sent.first?.sessionId, chats.tries.first?.sessionId)
    }

    /// #303 review: a kept new chat never changes the starts' record, so the release before New agent still reads every
    /// start in it (it failed to read a record holding a chat without a start, and lost them all).
    func test_a_kept_new_chat_leaves_the_starts_record_as_the_previous_release_reads_it() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let ticket = RoomTicketsCoordinator.AgentTicket(id: "t1", title: "T", status: "open", body: "b")
        let ticketMint = ScriptedMint(models: models, script: [.notConfirmed])
        let forTicket = AgentStartModel(ticket: ticket, sessionId: "room-1", mint: ticketMint, ledger: ledger, account: account) { _ in }
        await forTicket.load()
        await forTicket.start()
        let mint = ScriptedMint(models: models, script: [.capacity])
        let model = newAgent(mint, chats: FakeChats(), ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()
        XCTAssertNotNil(ledger.chat(account: account, sessionId: "room-1"), "the refused start's chat is kept")

        struct PreviousEntry: Decodable {
            let request: MintUpRequest
            let createdAt: Date
        }
        let previous = try JSONDecoder().decode([String: PreviousEntry].self, from: Data(contentsOf: ledger.url))
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(previous["\(account)|room-1|t1"]?.request, ticketMint.sent.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.chatsURL.path), "the chat has a file of its own")
    }

    /// The record keeps one new chat for the room's New agent: a start naming another is refused, and nothing of it kept.
    func test_the_record_refuses_a_start_naming_another_new_chat() throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let first = MintStartLedger.NewChat(sessionId: "chat-a", title: "A", createKey: "create-a", made: true)
        try ledger.keep(MintUpRequest(model: "model-a", jobDescription: "A", sessionId: "chat-a", idempotencyKey: "pocket-a-0000000000"),
                        chat: first, account: account, sessionId: "room-1", ticketId: nil)
        ledger.forget(account: account, sessionId: "room-1", ticketId: nil)

        let other = MintStartLedger.NewChat(sessionId: "chat-b", title: "B", createKey: "create-b", made: false)
        let second = MintUpRequest(model: "model-a", jobDescription: "B", sessionId: "chat-b", idempotencyKey: "pocket-b-0000000000")
        XCTAssertThrowsError(try ledger.keep(second, chat: other, account: account, sessionId: "room-1", ticketId: nil)) {
            XCTAssertEqual($0 as? MintStartLedger.Refusal, .anotherStartPending)
        }
        XCTAssertNil(ledger.pending(account: account, sessionId: "room-1", ticketId: nil), "nothing of it kept")
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1"), first, "the first chat stays the one")
    }

    /// A start in this chat never makes, nor reports, the new chat kept from an earlier try.
    func test_a_start_in_this_chat_never_makes_or_reports_a_kept_new_chat() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats(script: [.refuse(.rejected)])
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.job = "Review it."
        model.place = .newChat
        await model.start()
        guard case .failed = model.phase else { return XCTFail("expected a failure: \(model.phase)") }
        XCTAssertEqual(ledger.chat(account: account, sessionId: "room-1")?.made, false)

        model.edit()
        model.place = .thisChat
        await model.start()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(chats.tries.count, 1, "no chat made for a start in this chat")
        XCTAssertEqual(mint.sent.map(\.sessionId), ["room-1"])
        XCTAssertNil(model.startedChat)
    }

    /// The mint keeps a name of letters, digits, _ . and - up to 48 characters, and takes a job of up to 20,000 (UTF-16)
    /// characters. The phone says what the name will be and sends that; a job over the limit makes no chat and sends
    /// nothing.
    func test_the_name_and_the_job_follow_the_mints_limits() async throws {
        let ledger = temporaryLedger()
        defer { remove(ledger) }
        let mint = ScriptedMint(models: models)
        let chats = FakeChats()
        let model = newAgent(mint, chats: chats, ledger: ledger)
        await model.load()
        model.agentName = "Code reviewer #1 ✓"
        XCTAssertEqual(model.nameNote, "It will be named Codereviewer1: the mint keeps letters, digits, _ . and -, up to 48.")
        model.agentName = "✓✓"
        XCTAssertEqual(model.nameNote, "The mint keeps only letters, digits, _ . and -, so it will make the name.")
        model.agentName = "reviewer-1.a_b"
        XCTAssertNil(model.nameNote)
        model.agentName = String(repeating: "n", count: 60)
        XCTAssertNotNil(model.nameNote)

        model.place = .newChat
        model.job = String(repeating: "a", count: MintStartLimits.jobLength + 1)
        XCTAssertTrue(model.jobTooLong)
        XCTAssertFalse(model.canStart)
        await model.start()
        XCTAssertTrue(chats.tries.isEmpty, "no chat made for a job the mint would refuse")
        XCTAssertTrue(mint.sent.isEmpty)
        XCTAssertNil(ledger.chat(account: account, sessionId: "room-1"))
        model.job = String(repeating: "🙂", count: MintStartLimits.jobLength / 2 + 1)
        XCTAssertTrue(model.jobTooLong, "counted as the mint counts: two units each")
        model.job = String(repeating: "🙂", count: MintStartLimits.jobLength / 2)
        XCTAssertFalse(model.jobTooLong)
        XCTAssertTrue(model.canStart)

        await model.start()
        guard case .started = model.phase else { return XCTFail("not started: \(model.phase)") }
        XCTAssertEqual(mint.sent.first?.agentName, String(repeating: "n", count: 48))
        XCTAssertEqual(chats.tries.first?.title.hasPrefix(String(repeating: "n", count: 48) + " · "), true)
    }

    /// No answer from the mint (unreachable, or busy) does not hide New agent for the visit: it is asked again after a
    /// short wait, twice, and again whenever the room is shown. An answer, a list or a refusal, is not asked again.
    func test_new_agent_is_asked_again_when_the_mint_gave_no_answer() async {
        let waits = Journal()
        let mint = ScriptedMint(models: models, modelsScript: [.unavailable, .capacity])
        let offer = NewAgentOffer(role: "owner", isBreakout: false, mint: mint, sleep: { waits.note("\($0)") })
        await offer.check()
        XCTAssertTrue(offer.isOffered)
        XCTAssertEqual(mint.reads, 3)
        XCTAssertEqual(waits.all, NewAgentOffer.retryWaits.map { "\($0)" })
        await offer.check()
        XCTAssertEqual(mint.reads, 3, "answered: not asked again")

        let silent = ScriptedMint(models: models, modelsFailure: .unavailable)
        let quiet = makeOffer("owner", mint: silent)
        await quiet.check()
        XCTAssertFalse(quiet.isOffered)
        XCTAssertEqual(silent.reads, 3)
        await quiet.check()
        XCTAssertEqual(silent.reads, 6, "asked again when the room is shown again")

        let refused = ScriptedMint(models: models, modelsFailure: .forbidden)
        let no = makeOffer("owner", mint: refused)
        await no.check()
        await no.check()
        XCTAssertFalse(no.isOffered)
        XCTAssertEqual(refused.reads, 1, "a refusal is an answer")
    }
}
