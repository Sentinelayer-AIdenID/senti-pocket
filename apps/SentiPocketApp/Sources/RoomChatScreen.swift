import SwiftUI
import PocketSyncClient
import PocketUI

/// Navigation value for an open room.
struct RoomRoute: Hashable {
    let sessionId: String
    let title: String
}

/// Hosts one room's live chat. The room streams while it is on screen and the app is active, and pauses (keeping
/// what it loaded) when it is closed or the app goes to the background; returning catches up before going live.
struct RoomChatScreen: View {
    @StateObject private var coordinator: RoomChatCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(
        route: RoomRoute,
        transport: any RoomTransport,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        _coordinator = StateObject(wrappedValue: RoomChatCoordinator(
            sessionId: route.sessionId,
            title: route.title,
            transport: transport,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        RoomChatView(state: coordinator.state) { intent in
            coordinator.send(intent)
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
