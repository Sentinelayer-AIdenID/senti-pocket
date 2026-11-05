#if DEBUG
import PocketUI
import SwiftUI
import UIKit

/// DEBUG-only call screen over the preview room, for its UI tests and screenshots. With `-PocketRoomPreview`:
/// `-PocketCallScreenPreview` puts a call on screen the moment the room's box brings up the keyboard, as a call answered
/// while you write does; `-PocketCallScreenNow` puts it up at once. The call is scripted: the reviewer is answering,
/// its face talks with a word every 220 ms, and Speaker and Mute change only the screen. Never compiled into Release.
@MainActor
enum CallScreenPreview {
    static var isRequested: Bool { arguments.contains("-PocketCallScreenPreview") || isImmediate }
    private static var isImmediate: Bool { arguments.contains("-PocketCallScreenNow") }
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    private static var keyboardWatch: NSObjectProtocol?
    private static var call: PreviewCall?

    /// The preview room is on screen.
    static func start() {
        guard isRequested, call == nil, keyboardWatch == nil else { return }
        if isImmediate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { CallScreenPreview.show() }
            }
            return
        }
        keyboardWatch = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification,
                                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let watch = CallScreenPreview.keyboardWatch { NotificationCenter.default.removeObserver(watch) }
                CallScreenPreview.keyboardWatch = nil
                CallScreenPreview.show()
            }
        }
    }

    private static func show() {
        guard call == nil else { return }
        let made = PreviewCall()
        call = made
        VoiceCallWindow.shared.show(PreviewCallScreen(call: made))
        made.talk()
    }
}

/// The scripted call: two agents, the reviewer answering your question and speaking.
@MainActor
private final class PreviewCall: ObservableObject {
    @Published private(set) var state: VoiceRoomState
    let meter = VoiceLevelMeter()
    private var words: Timer?
    private var spoken = 0

    init() {
        let asked = Date().addingTimeInterval(-6)
        var state = VoiceRoomState(
            phase: .speaking(speaker: "review-agent (voice)"),
            with: ["review-agent", "build-agent"],
            turns: [
                VoiceRoomTurn(id: "you-1", speaker: "alex", isYou: true, text: "What went out tonight?", at: asked),
                VoiceRoomTurn(id: "line-1", speaker: "review-agent (voice)", isYou: false,
                              text: "Build 320 is up, and the retry fix is in it.",
                              at: asked.addingTimeInterval(2))
            ],
            startedAt: Date().addingTimeInterval(-95)
        )
        state.joined = ["review-agent", "build-agent"]
        state.ringStopped = true
        state.answering = VoiceRoomAnswering(turnId: "preview-turn", agentId: "review-agent", name: "Reviewer",
                                             isSpeaking: true)
        self.state = state
    }

    /// A word every 220 ms, of the lengths a short sentence has.
    func talk() {
        let lengths = [3, 7, 2, 9, 5, 4, 8, 3, 6]
        words = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spoken += 1
                self.meter.hear(VoiceLevelMeter.level(wordLength: lengths[self.spoken % lengths.count]), from: .agent)
            }
        }
    }

    func send(_ intent: VoiceRoomIntent) {
        switch intent {
        case .setSpeaker(let on): state.isSpeakerOn = on
        case .setMuted(let on): state.isMuted = on
        case .hangUp:
            words?.invalidate()
            words = nil
            meter.reset()
            VoiceCallWindow.shared.hide()
        default: break
        }
    }
}

private struct PreviewCallScreen: View {
    @ObservedObject var call: PreviewCall

    var body: some View {
        VoiceRoomPanel(state: call.state, meter: call.meter, partnerLab: nil, send: { call.send($0) })
    }
}
#endif
