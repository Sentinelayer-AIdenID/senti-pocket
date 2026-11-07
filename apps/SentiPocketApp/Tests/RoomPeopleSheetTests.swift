import PocketSyncClient
import PocketUI
import SwiftUI
import XCTest
@testable import SentiPocketApp

/// Carter, #62868: he hunted for Invite in a room, and the top bar's icon that looked like it opened agent requests. One
/// People button and one sheet: Invite people first, then who is in the room, then the agent requests with their count,
/// each shown only to whom the server allows it. On the signed-in root as the app hosts it (scripted rooms).
@MainActor
final class RoomPeopleSheetTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        RootPreview.meter.forgetPeople()
    }

    override func tearDown() {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        pump(0.4)
        super.tearDown()
    }

    func test_an_owner_sees_invite_first_then_who_is_here_then_the_counted_requests() throws {
        let room = RootPreviewAPI.midRoom
        try open(room, agentRequests: 2)
        let meter = RootPreview.meter
        wait("the People button counts the requests", seconds: 15) { meter.peopleBadge[room] == 2 }
        RootPreview.requestPeople()
        wait("People is up", seconds: 10) { meter.peopleSections[room] != nil }
        XCTAssertEqual(meter.peopleSections[room], ["invite", "members", "requests"],
                       "Invite people first, then who is here, then the agent requests")
        wait("the requests row counts them", seconds: 10) { meter.peopleRequestsTitle[room] == "Agent requests (2)" }
        XCTAssertEqual(meter.peopleRequestsTitle[room], "Agent requests (2)")
        XCTAssertEqual(meter.peopleBadge[room], 2)
        XCTAssertEqual(meter.peopleAgentsShown[room], false,
                       "the agents you work with stay hidden while the room's read does not offer them")
    }

    func test_a_member_sees_who_is_here_and_nothing_only_an_owner_or_admin_may_do() throws {
        let room = "room-000"
        try open(room, agentRequests: 2)
        let meter = RootPreview.meter
        RootPreview.requestPeople()
        wait("People is up", seconds: 10) { meter.peopleSections[room] != nil }
        pump(2)
        XCTAssertEqual(meter.peopleSections[room], ["members"], "no Invite people, no agent requests")
        XCTAssertNil(meter.peopleRequestsTitle[room], "the requests are not read or shown")
        XCTAssertNil(meter.peopleBadge[room], "the People button has no count")
        XCTAssertNil(meter.peopleAgentsShown[room], "Invite people is not there")
    }

    func test_the_agents_you_work_with_show_where_the_room_offers_them() throws {
        // The other room you own: the owner's test leaves its root on room-mid, where the agents are not offered, and
        // a request for People reaches every root, so each test reads what its own room's People showed.
        let room = RootPreviewAPI.longRoom
        try open(room, agentRequests: 0, addsAgents: true)
        let meter = RootPreview.meter
        // The room's read and who is here come with the room; People is opened once they have.
        pump(3)
        RootPreview.requestPeople()
        let expected: [String: AgentContactRowState] = [
            "plan-agent": .inThisChat, "night-agent": .add, "helper-of-someone": .inYourRooms
        ]
        wait("the agents are listed", seconds: 15) { meter.peopleAgentStates[room] == expected }
        XCTAssertEqual(meter.peopleAgentsShown[room], true)
        XCTAssertEqual(meter.peopleAgentStates[room], expected, "here already, yours to add, and someone else's")
    }

    /// Review (#369): Invite people's share sheet and AI-sharing question are presented from one view behind People's
    /// list, never from its rows, where each row would get a presenter of its own for the same sheet: one would show and
    /// the others fail. Share invite link asks once, and the share sheet follows OK. (room-long, with the agents' rows: no
    /// earlier test here leaves a root there.)
    func test_share_invite_link_asks_once_and_the_share_sheet_follows_ok() throws {
        Self.forgetAIConsent()
        defer { Self.forgetAIConsent() }
        let room = RootPreviewAPI.longRoom
        try open(room, agentRequests: 0, addsAgents: true)
        let meter = RootPreview.meter
        pump(2)
        RootPreview.requestPeople()
        wait("People is up", seconds: 10) { meter.peopleSections[room] != nil }
        pump(1)
        XCTAssertEqual(meter.invitePresenters[room], 1, "one presenter for Invite people's sheets, never one per row")

        RootPreview.requestShareLink()
        var asked = Set<ObjectIdentifier>()
        func watch(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                pump(0.1)
                consentSheets().forEach { asked.insert($0) }
            }
        }
        watch(3)
        XCTAssertEqual(asked.count, 1, "Share invite link asks once")
        let ok = try XCTUnwrap(element("pocket.aiConsent.ok"), "the question's Agree")
        XCTAssertTrue(ok.accessibilityActivate(), "Agree is a button")
        wait("the share sheet follows Agree", seconds: 10) { self.showsShareSheet }
        watch(2)
        XCTAssertEqual(asked.count, 1, "and it is never asked again")
        print("BGAUDIT invite share: presenters \(String(describing: meter.invitePresenters[room])), questions \(asked.count), "
              + "share sheet \(showsShareSheet), presented "
              + presented.map { shown in "\(type(of: shown))\(shown.children.map { child in "\(type(of: child))" })" }
                .joined(separator: " > "))
        presented.last?.dismiss(animated: false)
        pump(0.5)
    }

    /// The account's answer to the AI-sharing question, forgotten, so it is asked.
    private static func forgetAIConsent() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("pocket.aiConsent.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The system share sheet is up: presented over the root, or held inside what is (a SwiftUI sheet hosts it as a child).
    private var showsShareSheet: Bool {
        func holds(_ controller: UIViewController) -> Bool {
            controller is UIActivityViewController || controller.children.contains(where: holds)
        }
        return presented.contains(where: holds)
    }

    /// What is presented over the root, from the bottom up.
    private var presented: [UIViewController] {
        var chain: [UIViewController] = []
        var next = window?.rootViewController?.presentedViewController
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        return chain
    }

    /// The AI-sharing questions on screen: each presented sheet holding its Agree.
    private func consentSheets() -> [ObjectIdentifier] {
        presented.filter { controller in
            !controller.isBeingDismissed && Self.elements(in: controller.view).contains {
                HostedSummary.identifier(of: $0) == "pocket.aiConsent.ok"
            }
        }.map(ObjectIdentifier.init)
    }

    private func element(_ wanted: String) -> NSObject? {
        for controller in presented.reversed() {
            if let found = Self.elements(in: controller.view).first(where: { HostedSummary.identifier(of: $0) == wanted }) {
                return found
            }
        }
        return nil
    }

    /// Every accessibility element under a view: its subviews, and the elements they hold.
    private static func elements(in view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [Any] = [view]
        var seen = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            guard let object = queue.removeFirst() as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            found.append(object)
            if let view = object as? UIView { queue.append(contentsOf: view.subviews) }
            if let children = object.accessibilityElements { queue.append(contentsOf: children) }
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { queue.append(child) }
                }
            }
        }
        return found
    }

    private func open(_ roomId: String, agentRequests: Int, addsAgents: Bool = false) throws {
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: roomId, agentRequests: agentRequests,
                                 addsAgents: addsAgents)
        UserDefaults.standard.set(roomId, forKey: "pocket.lastRoomId")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: IncomingLinkInbox(),
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        wait("the room's first reads", seconds: 30) { ["rooms", "history"].allSatisfy { api.callCount($0) > 0 } }
        pump(1)
    }

    private func wait(_ what: String, seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { pump(0.1) }
        XCTAssertTrue(done(), what)
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}

/// The agents you work with, as People shows them (contract draft 2): Add for your own, "In your rooms" for anyone
/// else's, "Added, joining…" once added, "In the room" once it is here.
@MainActor
final class AgentContactsTests: XCTestCase {
    private final class Service: AgentContactsServing, @unchecked Sendable {
        private let lock = NSLock()
        /// The Add answer; nil answers with what was asked, approved.
        var answer: Result<AddedAgent, AddAgentError>?
        /// The pages, by the cursor that asks for each (nil: the first).
        var pages: [String?: AgentContactsPage] = [nil: AgentContactsPage(contacts: [
            AgentContact(id: "mine", displayName: "mine", lastActiveAt: nil, sharedRooms: 2, canAdd: true),
            AgentContact(id: "theirs", displayName: "theirs", lastActiveAt: nil, sharedRooms: 1, canAdd: false)
        ], nextCursor: nil)]
        private var calls: [String] = []
        private var cursors: [String?] = []
        var added: [String] { lock.withLock { calls } }
        var asked: [String?] { lock.withLock { cursors } }

        func agentContacts(cursor: String?) async throws -> AgentContactsPage {
            lock.withLock { cursors.append(cursor) }
            guard let page = pages[cursor] else { throw AddAgentError.failed }
            return page
        }

        func addAgent(_ agentId: String, to sessionId: String) async throws -> AddedAgent {
            lock.withLock { calls.append("\(agentId) to \(sessionId)") }
            return try answer?.get() ?? AddedAgent(agentId: agentId, status: "approved", addedAt: nil)
        }
    }

    func test_only_your_own_agents_can_be_added() async {
        let service = Service()
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        XCTAssertEqual(model.contacts.map { model.state(of: $0) }, [.add, .inYourRooms])
        await model.add(model.contacts[1])
        XCTAssertTrue(service.added.isEmpty, "someone else's agent is never added from here")
    }

    func test_an_added_agent_is_joining_until_it_is_here() async {
        let service = Service()
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        let mine = model.contacts[0]
        await model.add(mine)
        XCTAssertEqual(service.added, ["mine to room-1"])
        XCTAssertEqual(model.state(of: mine), .joining, "Added, joining… until it is in the room's roster")
        model.memberIds = ["mine"]
        XCTAssertEqual(model.state(of: mine), .inThisChat)
        await model.add(mine)
        XCTAssertEqual(service.added.count, 1, "added once")
    }

    /// The API's 409 means the agent is already a member of this chat: it says so, and waits for nothing.
    func test_an_agent_already_a_member_shows_already_in_this_chat() async {
        let service = Service()
        service.answer = .failure(.alreadyMember)
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        await model.add(model.contacts[0])
        XCTAssertEqual(model.state(of: model.contacts[0]), .inThisChat, "in this chat, never joining")
        XCTAssertNil(model.problem)
        await model.add(model.contacts[0])
        XCTAssertEqual(service.added.count, 1, "not asked again")
    }

    /// Added only as the answer says: this agent, approved. Any other answer is no add, and says so.
    func test_the_add_answers_status_decides_the_row() async {
        let cases: [(AddedAgent, AgentContactRowState)] = [
            (AddedAgent(agentId: "mine", status: "approved", addedAt: nil), .joining),
            (AddedAgent(agentId: "mine", status: "pending", addedAt: nil), .add),
            (AddedAgent(agentId: "someone-else", status: "approved", addedAt: nil), .add)
        ]
        for (answer, expected) in cases {
            let service = Service()
            service.answer = .success(answer)
            let model = AgentContactsModel(sessionId: "room-1", service: service)
            await model.load()
            await model.add(model.contacts[0])
            XCTAssertEqual(model.state(of: model.contacts[0]), expected, "\(answer)")
            XCTAssertEqual(model.problem == nil, expected == .joining, "a refused answer says it was not added (\(answer))")
        }
    }

    /// The audit: an agent of yours past the first 50 is reached. The list reads the next page from `nextCursor`
    /// (passed back unchanged) at its end, finds the agent there and adds it; it stops at the cap and says so.
    func test_an_addable_agent_on_the_second_page_is_found_and_added() async {
        let service = Service()
        let others = (1...50).map { AgentContact(id: "theirs-\($0)", displayName: "Theirs \($0)", lastActiveAt: nil,
                                                 sharedRooms: 1, canAdd: false) }
        let mine = AgentContact(id: "mine-on-page-2", displayName: "Mine", lastActiveAt: nil, sharedRooms: 1, canAdd: true)
        service.pages = [nil: AgentContactsPage(contacts: others, nextCursor: "aa1.page-2"),
                         "aa1.page-2": AgentContactsPage(contacts: [others[49], mine], nextCursor: nil)]
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        XCTAssertFalse(model.contacts.contains(mine), "not on the first page")
        XCTAssertTrue(model.hasMore, "the list ends with a row for more")
        await model.loadMore()
        XCTAssertEqual(service.asked, [nil, "aa1.page-2"], "the next page from the cursor, passed back unchanged")
        XCTAssertEqual(model.contacts.count, 51, "an agent already listed is not listed again")
        let found = model.contacts.first { $0.id == "mine-on-page-2" }
        XCTAssertEqual(found, mine, "found on page 2")
        guard let found else { return }
        XCTAssertEqual(model.state(of: found), .add)
        await model.add(found)
        XCTAssertEqual(service.added, ["mine-on-page-2 to room-1"])
        XCTAssertEqual(model.state(of: found), .joining)
        XCTAssertFalse(model.hasMore, "the last page read")
    }

    func test_contacts_stop_at_the_cap_and_say_so() async {
        let service = Service()
        var pages: [String?: AgentContactsPage] = [:]
        for index in 0..<15 {
            let contact = AgentContact(id: "a\(index)", displayName: "A\(index)", lastActiveAt: nil, sharedRooms: 1, canAdd: true)
            pages[index == 0 ? nil : "c\(index)"] = AgentContactsPage(contacts: [contact], nextCursor: "c\(index + 1)")
        }
        service.pages = pages
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        for _ in 0..<20 { await model.loadMore() }
        XCTAssertEqual(service.asked.count, AgentContactsModel.pageCap, "no more pages than the cap")
        XCTAssertFalse(model.hasMore)
        XCTAssertTrue(model.reachedCap, "the list says it shows the first ones")
    }

    /// The transport reads the Add answer as the API gives it, never assuming one: no agentId or no status is no add.
    func test_the_add_answer_is_read_as_the_api_gives_it() throws {
        let answer = try XCTUnwrap(HTTPAgentContacts.added(from: Data(
            #"{"agentId": "forge", "status": "approved", "addedAt": "2026-11-07T12:00:00Z"}"#.utf8)))
        XCTAssertEqual(answer.agentId, "forge")
        XCTAssertEqual(answer.status, "approved")
        XCTAssertTrue(answer.isApproved)
        XCTAssertNotNil(answer.addedAt)
        XCTAssertNil(HTTPAgentContacts.added(from: Data(#"{"agentId": "forge"}"#.utf8)), "no status: no add")
        XCTAssertNil(HTTPAgentContacts.added(from: Data(#"{"status": "approved"}"#.utf8)), "no agentId: no add")
        XCTAssertNil(HTTPAgentContacts.added(from: Data("".utf8)), "no body: no add")
        XCTAssertFalse(try XCTUnwrap(HTTPAgentContacts.added(from: Data(#"{"agentId": "forge", "status": "pending"}"#.utf8)))
            .isApproved)
    }

    func test_a_contacts_page_carries_its_next_cursor() throws {
        let first = try XCTUnwrap(HTTPAgentContacts.page(from: Data("""
        {"contacts": [{"id": "forge", "kind": "agent", "displayName": "forge", "sharedRooms": 2, "canAdd": true}],
         "nextCursor": "aa1.next"}
        """.utf8)))
        XCTAssertEqual(first.contacts.map(\.id), ["forge"])
        XCTAssertEqual(first.nextCursor, "aa1.next")
        XCTAssertNil(try XCTUnwrap(HTTPAgentContacts.page(from: Data(#"{"contacts": [], "nextCursor": null}"#.utf8)))
            .nextCursor, "null: the last page")
    }

    /// A 200 whose body can't be read is an error, never an empty last page that hides the rest.
    func test_an_unreadable_contacts_answer_is_an_error_not_an_empty_page() {
        XCTAssertNil(HTTPAgentContacts.page(from: Data("not json".utf8)))
        XCTAssertNil(HTTPAgentContacts.page(from: Data("".utf8)))
        XCTAssertNil(HTTPAgentContacts.page(from: Data(#"{"error": "busy"}"#.utf8)), "no list of contacts in it")
        XCTAssertNotNil(HTTPAgentContacts.page(from: Data(#"{"contacts": []}"#.utf8)), "an empty list is a page")
    }

    /// The review: an agent already in this chat (the room's roster) shows "In this chat" with no Add, online or not, so
    /// nothing asks the AI-sharing OK or writes for it; and an agent added that then goes offline stays in this chat.
    func test_an_agent_in_the_rooms_roster_shows_in_this_chat_and_is_never_added() async {
        let service = Service()
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        model.memberIds = ["mine"]
        let mine = model.contacts[0]
        XCTAssertEqual(model.state(of: mine), .inThisChat, "a member, whatever its presence")
        await model.add(mine)
        XCTAssertTrue(service.added.isEmpty, "never added again: no write, no 409")
    }

    func test_an_added_agent_stays_in_this_chat_once_it_has_joined() async {
        let service = Service()
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        let mine = model.contacts[0]
        await model.add(mine)
        XCTAssertEqual(model.state(of: mine), .joining)
        model.memberIds = ["mine"]
        XCTAssertEqual(model.state(of: mine), .inThisChat, "joined: in this chat, online or not")
    }

    /// A page that failed says so; the next page read clears it.
    func test_a_later_page_clears_the_paging_error() async {
        let service = Service()
        let mine = AgentContact(id: "mine", displayName: "mine", lastActiveAt: nil, sharedRooms: 1, canAdd: true)
        let more = AgentContact(id: "more", displayName: "more", lastActiveAt: nil, sharedRooms: 1, canAdd: true)
        service.pages = [nil: AgentContactsPage(contacts: [mine], nextCursor: "c2")]
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        await model.loadMore()
        XCTAssertEqual(model.problem, AgentContactsModel.moreFailed, "the page failed")
        service.pages["c2"] = AgentContactsPage(contacts: [more], nextCursor: nil)
        await model.loadMore()
        XCTAssertNil(model.problem, "read on: the error goes")
        XCTAssertEqual(model.contacts.map(\.id), ["mine", "more"])
    }

    func test_the_contacts_page_keeps_agents_with_a_name() {
        let page = Data("""
        {"items": [
          {"id": "build-helper", "kind": "agent", "displayName": "Build helper", "lastActiveAt": "2026-11-06T20:00:00Z",
           "sharedRooms": 4, "canAdd": true},
          {"id": "human-someone", "kind": "person", "displayName": "Someone", "sharedRooms": 2},
          {"id": "no-name", "kind": "agent", "sharedRooms": 1},
          {"id": "other", "kind": "agent", "displayName": "Other helper", "sharedRooms": 1}
        ]}
        """.utf8)
        let contacts = HTTPAgentContacts.contacts(from: page)
        XCTAssertEqual(contacts.map(\.id), ["build-helper", "other"], "agents with a name only")
        XCTAssertEqual(contacts.map(\.canAdd), [true, false], "Add only where the server says so")
        XCTAssertNotNil(contacts[0].lastActiveAt)
    }

    /// Before People, the room asked the AI-sharing OK before its invite sheet opened. People asks it before the link,
    /// the invite or the agent added, once, until it is given; never again after.
    func test_inviting_or_adding_an_agent_asks_the_ai_sharing_ok_until_it_is_given() throws {
        let suite = "people-consent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = AIConsent(account: "sub:someone", defaults: defaults)
        var ran = 0
        var asked: AIConsentHeld?
        AIConsentGate.run({ ran += 1 }, consent: consent) { asked = $0 }
        XCTAssertEqual(ran, 0, "nothing goes to the room before the OK")
        let question = try XCTUnwrap(asked, "the OK is asked first")
        consent.grant()
        question.proceed()
        XCTAssertEqual(ran, 1, "OK runs it")
        asked = nil
        AIConsentGate.run({ ran += 1 }, consent: consent) { asked = $0 }
        XCTAssertNil(asked, "asked once: never again after the OK")
        XCTAssertEqual(ran, 2)
    }

    func test_the_room_offers_agents_only_when_its_read_says_so() throws {
        func features(_ json: String) throws -> RoomFeatures {
            try JSONDecoder().decode(RoomFeatures.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try features(#"{"features": {"addAgents": true}}"#).addAgents)
        XCTAssertFalse(try features(#"{"features": {"addAgents": false}}"#).addAgents)
        XCTAssertFalse(try features(#"{"features": {"addAgents": "true"}}"#).addAgents)
        XCTAssertFalse(try features(#"{"features": {}}"#).addAgents)
        XCTAssertFalse(try features(#"{}"#).addAgents)
    }
}
