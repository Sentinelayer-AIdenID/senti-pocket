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

/// Where a reading's bar shows, at the top of what it reads over. It watches the reader and where the reading came from
/// itself, so a reading draws this bar and never the screen under it: the root, the room, a thread (Carter, #62471: the
/// page read from never goes away). `place` names it for the hosted tests.
struct ReadAloudBarSlot: View {
    @ObservedObject var reader: MessageReader
    @ObservedObject private var source = ReadAloudSource.shared
    let place: String
    /// Which readings this place shows, by the room they came from.
    let shows: (_ sourceSessionId: String?) -> Bool
    let onShowMessage: () -> Void

    var body: some View {
        #if DEBUG
        let _ = RootPreview.meter.readAloudSlotBodyRan(place)
        #endif
        Group {
            if let playback = reader.playback, shows(source.sessionId) {
                ReadAloudPlayer(reader: reader, playback: playback, onShowMessage: onShowMessage)
                    .padding(.vertical, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    #if DEBUG
                    .onPreferenceChange(ReadAloudBarFrames.self) { frames in
                        RootPreview.meter.readAloudBarLaidOut(place, frames)
                    }
                    #endif
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: reader.playback == nil)
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
            case .close: reader.stop()
            case .showMessage: onShowMessage()
            }
        }
    }
}

/// Draws `content` again whenever the reader changes, for a view that shows what is being read while its owner keeps the
/// reader without watching it (the root).
struct ReaderWatch<Content: View>: View {
    @ObservedObject var reader: MessageReader
    @ViewBuilder let content: (MessageReader) -> Content

    var body: some View {
        content(reader)
    }
}
