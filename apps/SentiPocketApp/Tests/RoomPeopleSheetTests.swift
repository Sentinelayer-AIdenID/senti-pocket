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
            "plan-agent": .inTheRoom, "ops-agent": .add, "helper-of-someone": .inYourRooms
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
        var answer: Result<AddedAgent, AddAgentError> = .success(AddedAgent(agentId: "", status: "approved", addedAt: nil))
        private var calls: [String] = []
        var added: [String] { lock.withLock { calls } }

        func agentContacts() async throws -> [AgentContact] {
            [AgentContact(id: "mine", displayName: "mine", lastActiveAt: nil, sharedRooms: 2, canAdd: true),
             AgentContact(id: "theirs", displayName: "theirs", lastActiveAt: nil, sharedRooms: 1, canAdd: false)]
        }

        func addAgent(_ agentId: String, to sessionId: String) async throws -> AddedAgent {
            lock.withLock { calls.append("\(agentId) to \(sessionId)") }
            return try answer.get()
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
        XCTAssertEqual(model.state(of: mine), .joining, "Added, joining… until its presence shows")
        model.presentIds = ["mine"]
        XCTAssertEqual(model.state(of: mine), .inTheRoom)
        await model.add(mine)
        XCTAssertEqual(service.added.count, 1, "added once")
    }

    func test_an_agent_already_in_the_room_counts_as_added() async {
        let service = Service()
        service.answer = .failure(.alreadyInTheRoom)
        let model = AgentContactsModel(sessionId: "room-1", service: service)
        await model.load()
        await model.add(model.contacts[0])
        XCTAssertEqual(model.state(of: model.contacts[0]), .joining)
        XCTAssertNil(model.problem)
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
