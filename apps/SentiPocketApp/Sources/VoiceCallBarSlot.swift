import Combine
import PocketUI
import SwiftUI

/// What a minimized voice room's bar shows, kept up with the call, and the call's Mute and End. It holds the call
/// weakly: the call belongs to the room that started it, and ends when that room goes (its screen hangs up as it
/// leaves), so the bar never outlives it.
@MainActor
final class VoiceCallBarModel: ObservableObject {
    @Published private(set) var state: VoiceCallBarState
    private let perform: @MainActor (VoiceRoomIntent) -> Void
    private var watch: AnyCancellable?

    init(_ room: VoiceRoomCoordinator) {
        state = VoiceCallBarState(room.state)
        perform = { [weak room] intent in room?.send(intent) }
        // Only what the bar shows: the words heard and read as the call goes draw nothing here.
        watch = room.$state
            .map { VoiceCallBarState($0) }
            .removeDuplicates()
            .sink { [weak self] state in self?.state = state }
    }

    func send(_ intent: VoiceRoomIntent) {
        perform(intent)
    }

    #if DEBUG
    /// A bar with no voice room behind it, for the hosted tests and the root preview: `perform` is what its Mute and
    /// End ask (DEBUG only).
    init(state: VoiceCallBarState, perform: @escaping @MainActor (VoiceRoomIntent) -> Void) {
        self.state = state
        self.perform = perform
    }

    /// Shows `state`, as a call's change would (DEBUG only).
    func show(_ state: VoiceCallBarState) {
        self.state = state
    }
    #endif
}

/// Where a minimized call's bar shows: over the top of the room, just under the navigation bar, from the moment the
/// call is minimized until a tap brings its screen back or the call ends. It floats over the list and is never part of
/// its insets: a list whose top inset changed as a bar came and went kept laying itself out (#360). It watches the call
/// window and the call itself, so the call draws this bar and never the root or the room under it.
struct VoiceCallBarSlot: View {
    @ObservedObject private var calls = VoiceCallWindow.shared

    var body: some View {
        Group {
            if let call = calls.minimized {
                VoiceCallBarWatch(call: call)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // VoiceOver reaches it before the room's messages under it.
                    .accessibilitySortPriority(1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: calls.minimized == nil)
    }
}

/// The bar of one minimized call, drawn again as that call changes.
private struct VoiceCallBarWatch: View {
    @ObservedObject var call: VoiceCallBarModel

    var body: some View {
        VoiceCallBar(state: call.state) { action in
            if action == .open {
                VoiceCallWindow.shared.restore()
            } else if let intent = call.state.intent(for: action) {
                call.send(intent)
            }
        }
    }
}
