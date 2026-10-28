import SwiftUI
import PocketSyncClient
import PocketUI

/// Navigation value for an open room.
struct RoomRoute: Hashable {
    let sessionId: String
    let title: String
    /// owner, admin, contributor or viewer. A viewer can read but not post.
    var membershipRole: String = ""
    /// A message to open the room at (from a notification or link).
    var focusSequenceId: Int64?
    /// A ticket to open over the room (a link's `?ticket=`, like the web's ticket drawer).
    var focusTicketId: String?
    /// Opens the room's agent requests (a link's `?admission=`), for owners and admins.
    var opensAdmissions = false
}

/// A ticket opened from a link, shown over the room.
private struct LinkedTicket: Identifiable {
    let id: String
}

/// Hosts one room's live chat. The room streams while it is on screen and the app is active, and pauses (keeping
/// what it loaded) when it is closed or the app goes to the background; returning catches up before going live.
/// Links tapped in the room stay in the app (`RoomLinkRouter`): this room's messages, tickets and agent requests open
/// here, another room opens through `openRoom`, and other web links open in the browser.
struct RoomChatScreen: View {
    @StateObject private var coordinator: RoomChatCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsTickets = false
    @State private var showsAdmissions = false
    @State private var linkedTicket: LinkedTicket?
    @State private var appliedRouteLinks = false
    private let route: RoomRoute
    private let ticketsTransport: (any RoomTicketsTransport)?
    private let admissionsTransport: (any RoomAdmissionsTransport)?
    private let admissionDecider: (any AdmissionDeciding)?
    private let ticketAnswerSender: (any RoomMessageSending)?
    private let openRoom: @MainActor (SentiLink) -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    init(
        route: RoomRoute,
        transport: any RoomTransport,
        sender: (any RoomMessageSending)? = nil,
        actionSender: (any RoomActionSending)? = nil,
        identity: (any AccountIdentityProviding)? = nil,
        ticketsTransport: (any RoomTicketsTransport)? = nil,
        admissionsTransport: (any RoomAdmissionsTransport)? = nil,
        admissionDecider: (any AdmissionDeciding)? = nil,
        openRoom: @escaping @MainActor (SentiLink) -> Void = { _ in },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.route = route
        self.ticketsTransport = ticketsTransport
        self.admissionsTransport = admissionsTransport
        self.admissionDecider = admissionDecider
        // A viewer cannot post, so cannot answer a ticket's decision either.
        self.ticketAnswerSender = route.membershipRole.lowercased() == "viewer" ? nil : sender
        self.openRoom = openRoom
        self.onReauthenticationRequired = onReauthenticationRequired
        _coordinator = StateObject(wrappedValue: RoomChatCoordinator(
            sessionId: route.sessionId,
            title: route.title,
            transport: transport,
            sender: sender,
            actionSender: actionSender,
            identity: identity,
            membershipRole: route.membershipRole,
            focusSequenceId: route.focusSequenceId,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    /// Only owners and admins decide agent requests (the API enforces it; the screen follows it).
    private var decidesAdmissions: Bool {
        admissionsTransport != nil && admissionDecider != nil
            && ["owner", "admin"].contains(route.membershipRole.lowercased())
    }

    private var linkAction: OpenURLAction {
        OpenURLAction { url in handle(url) }
    }

    var body: some View {
        RoomChatView(state: coordinator.state) { intent in
            coordinator.send(intent)
        }
        .toolbar {
            if decidesAdmissions {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsAdmissions = true
                    } label: {
                        Label("Agent requests", systemImage: "person.badge.shield.checkmark")
                    }
                    .accessibilityIdentifier("pocket.room.admissions")
                }
            }
            if ticketsTransport != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsTickets = true
                    } label: {
                        Label("Tickets", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("pocket.room.tickets")
                }
            }
        }
        .navigationDestination(isPresented: $showsAdmissions) {
            if let admissionsTransport, let admissionDecider {
                AdmissionsScreen(
                    sessionId: route.sessionId,
                    transport: admissionsTransport,
                    decider: admissionDecider,
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .navigationDestination(isPresented: $showsTickets) {
            if let ticketsTransport {
                RoomTicketsScreen(
                    sessionId: route.sessionId,
                    transport: ticketsTransport,
                    sender: ticketAnswerSender,
                    onOpenMessage: { sequence in focus(on: sequence) },
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .sheet(item: $linkedTicket) { linked in
            if let ticketsTransport {
                RoomTicketLinkScreen(
                    sessionId: route.sessionId,
                    ticketId: linked.id,
                    transport: ticketsTransport,
                    sender: ticketAnswerSender,
                    onOpenMessage: { sequence in focus(on: sequence) },
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .environment(\.openURL, linkAction)
        .onAppear {
            coordinator.resume()
            applyRouteLinksOnce()
        }
        .onDisappear { coordinator.pause() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: coordinator.resume()
            case .background: coordinator.pause()
            default: break
            }
        }
    }

    /// A link that opened this room may also name a ticket or the agent requests: open those once, over the room.
    private func applyRouteLinksOnce() {
        guard !appliedRouteLinks else { return }
        appliedRouteLinks = true
        if let ticketId = route.focusTicketId, ticketsTransport != nil {
            linkedTicket = LinkedTicket(id: ticketId)
        } else if route.opensAdmissions, decidesAdmissions {
            showsAdmissions = true
        }
    }

    /// Closes whatever covers the chat, then brings the message into view.
    private func focus(on sequence: Int64) {
        linkedTicket = nil
        showsTickets = false
        showsAdmissions = false
        coordinator.focus(on: sequence)
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch RoomLinkRouter.action(for: url, inRoom: route.sessionId) {
        case .focusMessage(let sequence):
            focus(on: sequence)
            return .handled
        case .openTicket(let ticketId):
            guard ticketsTransport != nil else { return .discarded }
            linkedTicket = LinkedTicket(id: ticketId)
            return .handled
        case .openAdmissions:
            guard decidesAdmissions else { return .discarded }
            linkedTicket = nil
            showsAdmissions = true
            return .handled
        case .openRoom(let link):
            openRoom(link)
            return .handled
        case .openInBrowser(let absolute):
            return .systemAction(absolute)
        case .ignore:
            return .discarded
        }
    }
}
