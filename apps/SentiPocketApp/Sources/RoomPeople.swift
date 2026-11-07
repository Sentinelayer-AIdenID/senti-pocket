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
                        .background(PocketPalette.danger, in: Capsule())
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
        #if DEBUG
        .onAppear { RootPreview.meter.peopleRequestsTitle[sessionId] = title }
        .onChange(of: title) { RootPreview.meter.peopleRequestsTitle[sessionId] = $0 }
        #endif
    }

    var title: String { "Agent requests (\(requests.state.pending.count))" }
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

/// Invite people, at the top of People: share an invite link at once, or invite someone by email or GitHub username;
/// and, where the room offers it, the agents you work with, each added in one tap.
struct RoomInviteRows: View {
    let sessionId: String
    let roomTitle: String
    let inviter: any RoomInviting
    let aiConsent: AIConsent?
    /// The agents you work with, where the room's read says so (`features.addAgents`); nil hides them.
    let agents: AgentContactsModel?

    @State private var sharing: RoomShareItem?
    @State private var making = false
    @State private var problem: String?
    @State private var consentHeld: AIConsentHeld?

    var body: some View {
        Group {
            Button {
                afterConsent { Task { await shareLink() } }
            } label: {
                Label(making ? "Making the link…" : "Share invite link", systemImage: "square.and.arrow.up")
            }
            .disabled(making)
            .accessibilityIdentifier("pocket.room.people.shareLink")
            NavigationLink {
                RoomInviteForm(sessionId: sessionId, roomTitle: roomTitle, inviter: inviter, aiConsent: aiConsent)
            } label: {
                Label("Invite by email or GitHub username", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("pocket.room.people.inviteByName")
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            if let agents {
                RoomAgentContactRows(model: agents, afterConsent: afterConsent)
            }
        }
        .sheet(item: $sharing) { item in RoomShareSheet(items: [item.url]) }
        .aiConsentPrompt($consentHeld) { aiConsent?.grant() }
        #if DEBUG
        .onAppear { RootPreview.meter.peopleAgentsShown[sessionId] = agents != nil }
        #endif
    }

    /// An invite writes to the room: the first write asks this account's OK to share with AI.
    private func afterConsent(_ action: @escaping () -> Void) {
        guard let aiConsent, aiConsent.asks else {
            action()
            return
        }
        consentHeld = AIConsentHeld(action)
    }

    /// A link anyone signed in joins with, as a contributor, then the system's share sheet.
    private func shareLink() async {
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

// MARK: - Agents you work with (contract draft 2: GET /api/v1/me/contacts?kind=agent, POST /sessions/{id}/agents)

/// An agent you work with (`GET /api/v1/me/contacts?kind=agent`).
struct AgentContact: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let lastActiveAt: Date?
    let sharedRooms: Int
    /// Your own account runs it: you may add it to a room. Anyone else's shows as in your rooms, with no button.
    let canAdd: Bool
}

/// The answer to adding an agent: approved to join, or joined already.
struct AddedAgent: Equatable, Sendable {
    let agentId: String
    let status: String
    let addedAt: Date?
}

enum AddAgentError: Error, Equatable {
    /// 403: only the room's owner or an admin adds agents.
    case notAllowed
    /// 404: no agent of yours by that id.
    case unknown
    /// 409: it is in the room already.
    case alreadyInTheRoom
    case failed
}

protocol AgentContactsServing: Sendable {
    func agentContacts() async throws -> [AgentContact]
    func addAgent(_ agentId: String, to sessionId: String) async throws -> AddedAgent
}

/// One agent's row: Add, in your rooms (not yours to add), added and joining, or in the room.
enum AgentContactRowState: Equatable {
    case add
    case inYourRooms
    case joining
    case inTheRoom

    static func of(_ contact: AgentContact, added: Bool, present: Bool) -> AgentContactRowState {
        if present { return .inTheRoom }
        if added { return .joining }
        return contact.canAdd ? .add : .inYourRooms
    }
}

/// The agents you work with, read when People shows them, and the ones you added from here.
@MainActor
final class AgentContactsModel: ObservableObject {
    @Published private(set) var contacts: [AgentContact] = []
    @Published private(set) var added: Set<String> = []
    @Published private(set) var adding: Set<String> = []
    @Published private(set) var problem: String?
    /// Who is in the room now, by id (lowercased): an agent added shows as in the room once it is here.
    @Published var presentIds: Set<String> = []
    let sessionId: String
    private let service: any AgentContactsServing
    private var loaded = false

    init(sessionId: String, service: any AgentContactsServing) {
        self.sessionId = sessionId
        self.service = service
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            contacts = try await service.agentContacts()
        } catch {
            loaded = false
            problem = "Your agents couldn't be read. Try again in a moment."
        }
    }

    func add(_ contact: AgentContact) async {
        guard contact.canAdd, !adding.contains(contact.id), !added.contains(contact.id) else { return }
        adding.insert(contact.id)
        problem = nil
        defer { adding.remove(contact.id) }
        do {
            _ = try await service.addAgent(contact.id, to: sessionId)
            added.insert(contact.id)
        } catch AddAgentError.alreadyInTheRoom {
            added.insert(contact.id)
        } catch AddAgentError.notAllowed {
            problem = "Only the room's owner or an admin can add agents."
        } catch {
            problem = "\(contact.displayName) couldn't be added. Try again."
        }
    }

    func state(of contact: AgentContact) -> AgentContactRowState {
        AgentContactRowState.of(contact, added: added.contains(contact.id), present: presentIds.contains(contact.id.lowercased()))
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
                .foregroundStyle(PocketPalette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.contacts) { contact in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName).lineLimit(1)
                        if let last = contact.lastActiveAt {
                            Text("Last active \(Self.ago(last))")
                                .font(.caption)
                                .foregroundStyle(PocketPalette.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(contact, state: model.state(of: contact))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pocket.room.people.agent.\(contact.id)")
            }
            if let problem = model.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
        .task { await model.load() }
        #if DEBUG
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
            Text("In your rooms").font(.caption).foregroundStyle(PocketPalette.textSecondary)
        case .joining:
            Text("Added, joining…").font(.caption).foregroundStyle(PocketPalette.textSecondary)
        case .inTheRoom:
            Text("In the room").font(.caption.weight(.semibold)).foregroundStyle(PocketPalette.verified)
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

    func agentContacts() async throws -> [AgentContact] {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let token = tokenProvider(), !token.isEmpty else { throw AddAgentError.failed }
        components.percentEncodedPath = "/api/v1/me/contacts"
        components.queryItems = [URLQueryItem(name: "kind", value: "agent"), URLQueryItem(name: "limit", value: "50")]
        guard let url = components.url else { throw AddAgentError.failed }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw AddAgentError.failed
        }
        return Self.contacts(from: data)
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
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
            return AddedAgent(agentId: json?["agentId"]?.stringValue ?? agentId,
                              status: json?["status"]?.stringValue ?? "approved",
                              addedAt: json?["addedAt"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date })
        case 403: throw AddAgentError.notAllowed
        case 404: throw AddAgentError.unknown
        case 409: throw AddAgentError.alreadyInTheRoom
        default: throw AddAgentError.failed
        }
    }
}
