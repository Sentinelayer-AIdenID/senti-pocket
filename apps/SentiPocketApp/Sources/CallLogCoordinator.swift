import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// "Calls & briefings" (Carter, 10-30): your calls across your rooms from the server's one log (`GET /me/calls`),
/// newest first, each with what the agents said it decided, and the way back to it in its room.
@MainActor
final class CallLogCoordinator: ObservableObject {
    @Published private(set) var state = CallLogState()

    private let transport: any CallLogTransport
    private let onReauthenticationRequired: @MainActor () -> Void
    private var calls: [SentiCall] = []
    private var nextCursor: String?

    init(transport: any CallLogTransport, onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.transport = transport
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func refresh() async {
        await read(cursor: nil)
    }

    func loadMore() async {
        guard let nextCursor else { return }
        await read(cursor: nextCursor)
    }

    private func read(cursor: String?) async {
        state.isLoading = true
        do {
            let page = try await transport.calls(limit: 50, cursor: cursor)
            if cursor == nil {
                calls = page.calls
            } else {
                calls += page.calls.filter { call in !calls.contains { $0.id == call.id && $0.kind == call.kind } }
            }
            nextCursor = page.nextCursor
            state.isAvailable = true
            state.notice = nil
        } catch SessionTransportError.accessDenied {
            // An older server answers 404, which the shared fetch reads as access denied.
            state.isAvailable = false
        } catch SessionTransportError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch SessionTransportError.cancelled {
        } catch {
            state.notice = "Could not update your calls. Pull to try again."
        }
        state.isLoading = false
        publish()
    }

    /// The call in its room, at the message that ended it (or started it).
    func link(for id: String) -> SentiLink? {
        guard let call = calls.first(where: { $0.id == id }) else { return nil }
        return SentiLink(sessionId: call.sessionId, messageSequence: call.endSequenceId ?? call.startSequenceId)
    }

    /// The call's summaries as one text to read aloud, with its title and room.
    func readable(_ id: String) -> (title: String, markdown: String, sessionId: String)? {
        guard let row = state.rows.first(where: { $0.id == id }), !row.summaries.isEmpty,
              let call = calls.first(where: { $0.id == id }) else { return nil }
        let text = row.summaries.map { "\($0.author): \($0.text)" }.joined(separator: "\n\n")
        return ("Call with \(row.title)", text, call.sessionId)
    }

    private func publish() {
        state.rows = calls.map(Self.row)
        state.canLoadMore = nextCursor != nil
    }

    static func row(_ call: SentiCall) -> CallLogRow {
        let started = ParsedSessionTimestamp(call.startedAt).date
        switch call.kind {
        case .voiceRoom:
            let title: String
            if call.isMeeting {
                title = "Meeting"
            } else if call.with.count <= 1 {
                title = call.with.first ?? "Call"
            } else {
                title = call.with.dropLast().joined(separator: ", ") + " and " + (call.with.last ?? "")
            }
            var parts: [String] = []
            switch call.status {
            case "ongoing": parts.append("In progress")
            case "unfinished": parts.append("Did not close")
            default: break
            }
            if let duration = call.durationText { parts.append(duration) }
            if let turns = call.turns { parts.append("\(turns) \(turns == 1 ? "turn" : "turns")") }
            return CallLogRow(
                id: call.id,
                direction: .outgoing,
                title: title,
                roomTitle: call.roomTitle,
                startedAt: started,
                detail: parts.joined(separator: " · "),
                isOngoing: call.status == "ongoing",
                summaries: call.summaries.map { CallLogRow.Summary(author: $0.author, text: $0.text) },
                timings: call.timingsText,
                hasTranscript: call.transcriptAttachmentId != nil,
                canOpen: call.endSequenceId != nil || call.startSequenceId != nil
            )
        case .ring:
            let incoming = call.direction != "outgoing"
            let other = (incoming ? call.callerName : call.calleeName) ?? "Someone"
            let status: String
            switch call.status {
            case "missed": status = "Missed"
            case "declined": status = "Declined"
            case "ringing": status = "Ringing"
            case "answered": status = "Answered"
            default: status = "Ended"
            }
            return CallLogRow(
                id: call.id,
                direction: incoming ? .incoming : .outgoing,
                title: incoming ? "\(other) called you" : "You called \(other)",
                roomTitle: call.roomTitle,
                startedAt: started,
                detail: status,
                isMissed: incoming && call.status == "missed",
                isOngoing: call.status == "ringing",
                reason: call.reason,
                canOpen: true
            )
        }
    }
}
