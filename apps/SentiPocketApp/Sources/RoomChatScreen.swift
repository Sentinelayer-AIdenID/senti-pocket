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
}

/// Hosts one room's live chat. The room streams while it is on screen and the app is active, and pauses (keeping
/// what it loaded) when it is closed or the app goes to the background; returning catches up before going live.
struct RoomChatScreen: View {
    @StateObject private var coordinator: RoomChatCoordinator
    @Environment(\.scenePhase) private var scenePhase
    private let route: RoomRoute
    private let ticketsTransport: (any RoomTicketsTransport)?
    private let onReauthenticationRequired: @MainActor () -> Void

    init(
        route: RoomRoute,
        transport: any RoomTransport,
        sender: (any RoomMessageSending)? = nil,
        actionSender: (any RoomActionSending)? = nil,
        identity: (any AccountIdentityProviding)? = nil,
        ticketsTransport: (any RoomTicketsTransport)? = nil,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.route = route
        self.ticketsTransport = ticketsTransport
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

    var body: some View {
        RoomChatView(state: coordinator.state) { intent in
            coordinator.send(intent)
        }
        .toolbar {
            if let ticketsTransport {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        RoomTicketsScreen(
                            sessionId: route.sessionId,
                            transport: ticketsTransport,
                            onReauthenticationRequired: onReauthenticationRequired
                        )
                    } label: {
                        Label("Tickets", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("pocket.room.tickets")
                }
            }
        }
        .onAppear { coordinator.resume() }
        .onDisappear { coordinator.pause() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: coordinator.resume()
            case .background: coordinator.pause()
            default: break
            }
        }
    }
}
