import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI

// The room's People (Carter, #62868: he hunted for Invite, and the top bar's icon that looked like it opened agent
// requests). One button, one sheet: Invite people first, then who is in the room, then the agent requests for the
// room's owner or an admin. The sheet itself is PocketUI's; what it shows from the app is here.

/// The room's People button: who is in the room, with a count while agent requests wait for an owner's or an admin's
/// answer (`requests` is nil for anyone else).
struct RoomPeopleButton: View {
    let sessionId: String
    let requests: AdmissionsCoordinator?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            if let requests {
                RoomPeopleIcon(sessionId: sessionId, requests: requests)
            } else {
                Image(systemName: "person.2")
                    .accessibilityLabel("People")
            }
        }
        .accessibilityIdentifier("pocket.room.people.open")
    }
}

/// The icon, with the waiting requests' count: it watches the requests itself, so a new one draws the icon alone.
private struct RoomPeopleIcon: View {
    let sessionId: String
    @ObservedObject var requests: AdmissionsCoordinator

    var body: some View {
        let waiting = requests.state.pending.count
        Image(systemName: "person.2")
            .overlay(alignment: .topTrailing) {
                if waiting > 0 {
                    Text(waiting > 9 ? "9+" : "\(waiting)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.red, in: Capsule())
                        .offset(x: 9, y: -8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("People")
            .accessibilityValue(waiting == 0 ? "" : "\(waiting) agent \(waiting == 1 ? "request" : "requests") waiting")
            #if DEBUG
            .onAppear { RootPreview.meter.peopleBadge[sessionId] = waiting }
            .onChange(of: waiting) { RootPreview.meter.peopleBadge[sessionId] = $0 }
            #endif
    }
}

/// The agent requests row's words, with how many wait.
enum RoomRequestsTitle {
    static func text(count: Int) -> String { "Agent requests (\(count))" }
}

/// Agent requests, at the foot of People: the count on its row, and the same requests screen as before.
struct RoomRequestsRow<Destination: View>: View {
    let sessionId: String
    @ObservedObject var requests: AdmissionsCoordinator
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            Label(title, systemImage: "person.badge.shield.checkmark")
        }
        .accessibilityIdentifier("pocket.room.people.requests.open")
    }

    var title: String { RoomRequestsTitle.text(count: requests.state.pending.count) }
}

/// The agent requests screen as it was in its own sheet, now inside People: read every 10 seconds while on screen.
struct RoomRequestsPage: View {
    @ObservedObject var requests: AdmissionsCoordinator

    var body: some View {
        AdmissionsView(state: requests.state) { requests.send($0) }
            .onAppear { requests.start() }
            .onDisappear { requests.stop() }
    }
}

/// The AI-sharing OK (App Store guideline 5.1.2(i)) before something from People writes to the room: an invite link, an
/// invite, an agent added. Asked first while this account has not said OK, as the room asked before opening its invite
/// sheet before People (`afterAIConsent { showsInvite = true }`); `ask` shows the question, and OK runs the action.
enum AIConsentGate {
    @MainActor
    static func run(_ action: @escaping () -> Void, consent: AIConsent?, ask: (AIConsentHeld) -> Void) {
        guard let consent, consent.asks else {
            action()
            return
        }
        ask(AIConsentHeld(action))
    }
}

/// What Invite people shows besides its rows: the link being made, what went wrong, the share sheet and the AI-sharing
/// question. One per room screen, kept there; the rows read it, and its sheets are presented from one place only
/// (`RoomInvitePresenters`, behind People's list), never from a row: in a list each row would get a presenter of its
/// own for the same sheet, one would show and the others fail.
@MainActor
final class RoomInviteSharing: ObservableObject {
    let sessionId: String
    let inviter: any RoomInviting
    let aiConsent: AIConsent?
    @Published var sharing: RoomShareItem?
    @Published private(set) var making = false
    @Published private(set) var problem: String?
    @Published var consentHeld: AIConsentHeld?

    init(sessionId: String, inviter: any RoomInviting, aiConsent: AIConsent?) {
        self.sessionId = sessionId
        self.inviter = inviter
        self.aiConsent = aiConsent
    }

    /// An invite writes to the room: the first write asks this account's OK to share with AI.
    func afterConsent(_ action: @escaping () -> Void) {
        AIConsentGate.run(action, consent: aiConsent) { [weak self] held in self?.consentHeld = held }
    }

    /// Share invite link: once it may, a link anyone signed in joins with, as a contributor, then the share sheet.
    func shareLink() {
        afterConsent { [weak self] in Task { await self?.makeLink() } }
    }

    private func makeLink() async {
        making = true
        problem = nil
        defer { making = false }
        do {
            sharing = RoomShareItem(url: try await inviter.createInviteLink(sessionId: sessionId, role: .contributor))
        } catch let error as RoomInviteError {
            problem = error.message
        } catch RoomSendError.reauthenticationRequired {
            problem = "Sign in again to invite people."
        } catch {
            problem = "The link couldn't be made. Check your connection and try again."
        }
    }
}

/// Invite people's share sheet and AI-sharing question, presented from this one view behind People's list.
struct RoomInvitePresenters: View {
    @ObservedObject var sharing: RoomInviteSharing

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .sheet(item: $sharing.sharing) { item in RoomShareSheet(items: [item.url]) }
            .aiConsentPrompt($sharing.consentHeld) { sharing.aiConsent?.grant() }
            #if DEBUG
            // How many presenters Invite people has on screen, for the hosted test: one.
            .onAppear { RootPreview.meter.invitePresenters[sharing.sessionId, default: 0] += 1 }
            .onDisappear { RootPreview.meter.invitePresenters[sharing.sessionId, default: 0] -= 1 }
            .onReceive(RootPreview.shareLinkRequests) { sharing.shareLink() }
            #endif
    }
}

/// Invite people, at the top of People: share an invite link at once, or invite someone by email or GitHub username;
/// and, where the room offers it, the agents you work with, each added in one tap. Rows only: what they open is
/// presented by `RoomInvitePresenters`.
struct RoomInviteRows: View {
    let roomTitle: String
    @ObservedObject var sharing: RoomInviteSharing
    /// The agents you work with, where the room's read says so (`features.addAgents`); nil hides them.
    let agents: AgentContactsModel?

    var body: some View {
        Group {
            Button {
                sharing.shareLink()
            } label: {
                Label(sharing.making ? "Making the link…" : "Share invite link", systemImage: "square.and.arrow.up")
            }
            .disabled(sharing.making)
            .accessibilityIdentifier("pocket.room.people.shareLink")
            NavigationLink {
                RoomInviteForm(sessionId: sharing.sessionId, roomTitle: roomTitle, inviter: sharing.inviter,
                               aiConsent: sharing.aiConsent)
            } label: {
                Label("Invite by email or GitHub username", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("pocket.room.people.inviteByName")
            if let problem = sharing.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if let agents {
                RoomAgentContactRows(model: agents, afterConsent: sharing.afterConsent)
            }
        }
        #if DEBUG
        .onAppear { if agents == nil { RootPreview.meter.peopleAgentsShown[sharing.sessionId] = false } }
        #endif
    }
}

// MARK: - Agents you work with (GET /api/v1/me/contacts?kind=agent, a page at a time; POST /sessions/{id}/agents)

/// An agent you work with (`GET /api/v1/me/contacts?kind=agent`).
struct AgentContact: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let lastActiveAt: Date?
    let sharedRooms: Int
    /// Your own account runs it: you may add it to a room. Anyone else's shows as in your rooms, with no button.
    let canAdd: Bool
}

/// One page of the agents you work with, and where the next starts (`nextCursor`; nil: this was the last).
struct AgentContactsPage: Equatable, Sendable {
    let contacts: [AgentContact]
    let nextCursor: String?
}

/// The answer to adding an agent, as the API gives it: `{"agentId", "status", "addedAt"}`. Only "approved" (a one-use
/// approval for it to join) counts as added.
struct AddedAgent: Equatable, Sendable {
    let agentId: String
    let status: String
    let addedAt: Date?

    var isApproved: Bool { status == "approved" }
}

enum AddAgentError: Error, Equatable {
    /// 403: only the room's owner or an admin adds agents.
    case notAllowed
    /// 404: no agent of yours by that id.
    case unknown
    /// 409: the agent is already a member of this chat.
    case alreadyMember
    case failed
}

protocol AgentContactsServing: Sendable {
    /// A page of the agents you work with: the first with `cursor` nil, then each `nextCursor` unchanged.
    func agentContacts(cursor: String?) async throws -> AgentContactsPage
    func addAgent(_ agentId: String, to sessionId: String) async throws -> AddedAgent
}

/// One agent's row: Add, in your rooms (not yours to add), added and joining, or in this chat (a member: in the room's
/// roster, or the API said so with a 409), whatever its presence.
enum AgentContactRowState: Equatable {
    case add
    case inYourRooms
    case joining
    case inThisChat

    static func of(_ contact: AgentContact, added: Bool, member: Bool) -> AgentContactRowState {
        if member { return .inThisChat }
        if added { return .joining }
        return contact.canAdd ? .add : .inYourRooms
    }
}

/// The agents you work with, read when People shows them, and the ones you added from here.
@MainActor
final class AgentContactsModel: ObservableObject {
    @Published private(set) var contacts: [AgentContact] = []
    @Published private(set) var added: Set<String> = []
    /// Agents the API said are already members of this chat (409).
    @Published private(set) var members: Set<String> = []
    /// Where the next page starts; nil once the last page is read.
    @Published private(set) var nextCursor: String?
    @Published private(set) var loadingMore = false
    @Published private(set) var adding: Set<String> = []
    @Published private(set) var problem: String?
    /// The agents in this chat, from the room's roster, by id (lowercased): a member shows as in this chat with no Add,
    /// online or not, and an agent added shows so once it has joined.
    @Published var memberIds: Set<String> = []
    let sessionId: String
    private let service: any AgentContactsServing
    private var loaded = false
    private var pages = 0
    /// At most this many pages of 50 are read (500 agents); past it the list says so.
    static let pageCap = 10

    init(sessionId: String, service: any AgentContactsServing) {
        self.sessionId = sessionId
        self.service = service
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let page = try await service.agentContacts(cursor: nil)
            contacts = page.contacts
            nextCursor = page.nextCursor
            pages = 1
            problem = nil
        } catch {
            loaded = false
            problem = "Your agents couldn't be read. Try again in a moment."
        }
    }

    static let moreFailed = "More of your agents couldn't be read. Try again."

    /// More pages remain, within the cap: the list ends with a row that reads the next.
    var hasMore: Bool { nextCursor != nil && pages < Self.pageCap }
    /// More pages remain past the cap: the list says it shows the first ones.
    var reachedCap: Bool { nextCursor != nil && pages >= Self.pageCap }

    /// The next page, from where the last one ended, added to the list (an agent already listed is not listed again).
    func loadMore() async {
        guard let cursor = nextCursor, hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await service.agentContacts(cursor: cursor)
            let known = Set(contacts.map(\.id))
            contacts += page.contacts.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            pages += 1
            // A page read after one that failed: its error goes.
            if problem == Self.moreFailed { problem = nil }
        } catch {
            problem = Self.moreFailed
        }
    }

    func add(_ contact: AgentContact) async {
        // Never asked again once added, or once the API said it is already a member of this chat.
        guard contact.canAdd, !adding.contains(contact.id), !added.contains(contact.id),
              !isMember(contact) else { return }
        adding.insert(contact.id)
        problem = nil
        defer { adding.remove(contact.id) }
        do {
            let answer = try await service.addAgent(contact.id, to: sessionId)
            // Added only as the answer says: this agent, approved to join.
            guard answer.agentId == contact.id, answer.isApproved else {
                problem = "\(contact.displayName) couldn't be added. Try again."
                return
            }
            added.insert(contact.id)
        } catch AddAgentError.alreadyMember {
            members.insert(contact.id)
        } catch AddAgentError.notAllowed {
            problem = "Only the room's owner or an admin can add agents."
        } catch {
            problem = "\(contact.displayName) couldn't be added. Try again."
        }
    }

    func state(of contact: AgentContact) -> AgentContactRowState {
        AgentContactRowState.of(contact, added: added.contains(contact.id), member: isMember(contact))
    }

    /// In this chat: in the room's roster, or the API said so (409).
    private func isMember(_ contact: AgentContact) -> Bool {
        members.contains(contact.id) || memberIds.contains(contact.id.lowercased())
    }
}

/// The agents you work with, under Invite people: name, when last active, and Add for your own.
private struct RoomAgentContactRows: View {
    @ObservedObject var model: AgentContactsModel
    let afterConsent: (@escaping () -> Void) -> Void

    var body: some View {
        Group {
            Text("Agents you work with")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.contacts) { contact in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName).lineLimit(1)
                        if let last = contact.lastActiveAt {
                            Text("Last active \(Self.ago(last))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(contact, state: model.state(of: contact))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pocket.room.people.agent.\(contact.id)")
            }
            // More of your agents, a page at a time, read as the list's end comes into view (or on a tap).
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Label(model.loadingMore ? "Loading more agents…" : "Show more agents",
                          systemImage: "ellipsis.circle")
                }
                .disabled(model.loadingMore)
                .onAppear { Task { await model.loadMore() } }
                .accessibilityIdentifier("pocket.room.people.agents.more")
            } else if model.reachedCap {
                Text("Showing your first \(AgentContactsModel.pageCap * 50) agents.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
        .task { await model.load() }
        #if DEBUG
        .onAppear { RootPreview.meter.peopleAgentsShown[model.sessionId] = true }
        .onChange(of: model.contacts.map { model.state(of: $0) }) { states in
            RootPreview.meter.peopleAgentStates[model.sessionId] = Dictionary(uniqueKeysWithValues: zip(model.contacts.map(\.id),
                                                                                                    states))
        }
        #endif
    }

    @ViewBuilder
    private func trailing(_ contact: AgentContact, state: AgentContactRowState) -> some View {
        switch state {
        case .add:
            Button(model.adding.contains(contact.id) ? "Adding…" : "Add") {
                afterConsent { Task { await model.add(contact) } }
            }
            .buttonStyle(.borderless)
            .disabled(model.adding.contains(contact.id))
            .accessibilityLabel("Add \(contact.displayName)")
        case .inYourRooms:
            Text("In your rooms").font(.caption).foregroundStyle(.secondary)
        case .joining:
            Text("Added, joining…").font(.caption).foregroundStyle(.secondary)
        case .inThisChat:
            Text("In this chat").font(.caption.weight(.semibold)).foregroundStyle(.green)
        }
    }

    private static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The agents you work with, from the API: `GET /api/v1/me/contacts?kind=agent` with your bearer, and
/// `POST /api/v1/sessions/{id}/agents` as a room write.
struct HTTPAgentContacts: AgentContactsServing, @unchecked Sendable {
    let apiBaseURL: URL?
    let sender: HTTPRoomMessageSender
    var urlSession: URLSession = SentiHTTPTransportPolicy.protectedReadSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    func agentContacts(cursor: String?) async throws -> AgentContactsPage {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let token = tokenProvider(), !token.isEmpty else { throw AddAgentError.failed }
        components.percentEncodedPath = "/api/v1/me/contacts"
        // The next page: the last one's `nextCursor`, passed back unchanged.
        components.queryItems = [URLQueryItem(name: "kind", value: "agent"), URLQueryItem(name: "limit", value: "50")]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        guard let url = components.url else { throw AddAgentError.failed }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw AddAgentError.failed
        }
        // A 200 whose body can't be read is an error, never an empty last page.
        guard let page = Self.page(from: data) else { throw AddAgentError.failed }
        return page
    }

    /// A contacts page: its agents, and `nextCursor` (null on the last page). Nil when the body is not one: no JSON, or
    /// no list of contacts in it.
    static func page(from data: Data) -> AgentContactsPage? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              json["contacts"]?.arrayValue != nil || json["items"]?.arrayValue != nil || json.arrayValue != nil else {
            return nil
        }
        let cursor = json["nextCursor"]?.stringValue
        return AgentContactsPage(contacts: contacts(from: data), nextCursor: (cursor?.isEmpty ?? true) ? nil : cursor)
    }

    /// The Add answer, read as the API gives it: an agentId and a status are both needed, never assumed.
    static func added(from data: Data) -> AddedAgent? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let agentId = json["agentId"]?.stringValue, !agentId.isEmpty,
              let status = json["status"]?.stringValue, !status.isEmpty else { return nil }
        return AddedAgent(agentId: agentId, status: status,
                          addedAt: json["addedAt"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date })
    }

    /// The agent items of a contacts page: `items` (or a bare list), each with an id and a name to show; an item that
    /// is not an agent, or has neither, is left out.
    static func contacts(from data: Data) -> [AgentContact] {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let items = json?["items"]?.arrayValue ?? json?["contacts"]?.arrayValue ?? json?.arrayValue ?? []
        return items.compactMap { item in
            guard item["kind"]?.stringValue == "agent", let id = item["id"]?.stringValue, !id.isEmpty,
                  let name = item["displayName"]?.stringValue, !name.isEmpty else { return nil }
            return AgentContact(id: id, displayName: name,
                                lastActiveAt: item["lastActiveAt"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date },
                                sharedRooms: Int(item["sharedRooms"]?.intValue ?? 0),
                                canAdd: item["canAdd"]?.boolValue == true)
        }
    }

    func addAgent(_ agentId: String, to sessionId: String) async throws -> AddedAgent {
        let (data, http) = try await sender.sessionMutation(
            sessionId: sessionId, path: "agents", routeTemplate: "POST /api/v1/sessions/{session_id}/agents",
            keyPrefix: "add-agent", body: ["agentId": agentId]
        )
        switch http.statusCode {
        case 200..<300:
            guard let added = Self.added(from: data) else { throw AddAgentError.failed }
            return added
        case 403: throw AddAgentError.notAllowed
        case 404: throw AddAgentError.unknown
        // The API's 409: the agent is already a member of this chat.
        case 409: throw AddAgentError.alreadyMember
        default: throw AddAgentError.failed
        }
    }
}
