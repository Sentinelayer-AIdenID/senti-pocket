import Combine
import Foundation
#if canImport(CallKit)
import CallKit
#endif

/// Whether a call is on: Pocket's call screen is up (a voice room, or an agent's call you answered) or minimized to its
/// bar, or a call rings or talks on the phone (CallKit's view of every call, Pocket's own and the phone's). An alert
/// never interrupts one: the crash report offer waits until this is false.
@MainActor
final class CallPresence: NSObject, ObservableObject {
    static let shared = CallPresence()

    @Published private(set) var isOn = false
    private var callScreenUp = false
    #if canImport(CallKit)
    private let calls = CXCallObserver()
    #endif

    override init() {
        super.init()
        #if canImport(CallKit)
        calls.setDelegate(self, queue: .main)
        #endif
        refresh()
    }

    /// Pocket's call screen went up or down (`VoiceCallWindow`).
    func callScreen(up: Bool) {
        callScreenUp = up
        refresh()
    }

    fileprivate func refresh() {
        #if canImport(CallKit)
        let phoneCall = calls.calls.contains { !$0.hasEnded }
        #else
        let phoneCall = false
        #endif
        let on = callScreenUp || phoneCall
        if on != isOn { isOn = on }
    }
}

#if canImport(CallKit)
extension CallPresence: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in self.refresh() }
    }
}
#endif
