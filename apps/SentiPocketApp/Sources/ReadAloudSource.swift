import Foundation
import PocketSyncClient
import PocketUI
import PocketVoice
import SwiftUI

/// Which room the message being read aloud belongs to (Carter, 10-30: "Even if I go to another room my voice player
/// needs to stay until I click another voice thing"). The room's own player shows while you are in that room; anywhere
/// else, the app keeps a player on screen whose title takes you back to that room, at the message.
@MainActor
final class ReadAloudSource: ObservableObject {
    static let shared = ReadAloudSource()

    @Published private(set) var sessionId: String?

    func reading(in sessionId: String) {
        self.sessionId = sessionId
    }

    /// The link back to what is being read: the message, a reply, or the room (its summary).
    static func link(readingId: String, sessionId: String) -> SentiLink {
        if readingId.hasPrefix("msg:"), let sequence = Int64(readingId.dropFirst("msg:".count)) {
            return SentiLink(sessionId: sessionId, messageSequence: sequence)
        }
        if readingId.hasPrefix("reply:") {
            return SentiLink(sessionId: sessionId, replyId: String(readingId.dropFirst("reply:".count)))
        }
        return SentiLink(sessionId: sessionId)
    }
}

/// The read-aloud player, the same controls wherever it shows.
struct ReadAloudPlayer: View {
    @ObservedObject var reader: MessageReader
    let playback: ReadAloudPlayback
    let onShowMessage: () -> Void

    var body: some View {
        ReadAloudBar(state: ReadAloudBarState(
            title: playback.title,
            isPaused: playback.isPaused,
            elapsedBefore: playback.elapsedBefore,
            sentenceStartedAt: playback.sentenceStartedAt,
            sentenceLength: playback.sentenceLength,
            total: playback.total,
            hasGoodVoice: playback.hasGoodVoice
        )) { action in
            switch action {
            case .togglePause: if playback.isPaused { reader.resume() } else { reader.pause() }
            case .skip(let seconds): reader.skip(by: seconds)
            case .close: reader.stop()
            case .showMessage: onShowMessage()
            }
        }
    }
}
