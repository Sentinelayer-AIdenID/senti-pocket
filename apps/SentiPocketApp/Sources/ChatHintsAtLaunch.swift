import PocketUI
import SwiftUI

/// Loaded rooms and folders are not yet visible under the launch screen. Keep their first tips available until
/// the splash has actually gone, even when restoring a room removes the initial list underneath it.
@MainActor
struct ChatHintsAtLaunch: ViewModifier {
    let hints: ChatHints
    let isReady: Bool
    private let skipsSplash: Bool
    private let urgency: LaunchUrgency
    @State private var splashGone: Bool

    init(hints: ChatHints, isReady: Bool, skipsSplash: Bool = CrashReporter.isTestRun,
         urgency: LaunchUrgency? = nil) {
        self.hints = hints
        self.isReady = isReady
        self.skipsSplash = skipsSplash
        self.urgency = urgency ?? .shared
        _splashGone = State(initialValue: skipsSplash)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.chatHints, hints)
            .environment(\.chatHintsVisible, splashGone)
            .overlay {
                LaunchSplash(isReady: isReady, skipsSplash: skipsSplash, urgency: urgency) {
                    splashGone = true
                }
            }
    }
}
