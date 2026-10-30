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
    /// Every call read this session, so a call opened from a detail still opens after a refresh replaced the list.
    private var known: [String: SentiCall] = [:]
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
            let read = try await transport.calls(limit: 50, cursor: cursor)
            // The signal model's name never shows, here or read aloud (warden, #272).
            let page = SentiCallLogPage(calls: read.calls.map(Self.hidden), nextCursor: read.nextCursor)
            let next = page.nextCursor
            for call in page.calls { known[call.id] = call }
            if cursor == nil {
                calls = page.calls
            } else {
                calls += page.calls.filter { call in !calls.contains { $0.id == call.id && $0.kind == call.kind } }
            }
            nextCursor = next
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

    /// The call in its room, at its card: the room folds a closed call onto the message that started it, so the end
    /// message has no row of its own to land on (warden, #272).
    func link(for id: String) -> SentiLink? {
        guard let call = known[id] else { return nil }
        return SentiLink(sessionId: call.sessionId, messageSequence: call.startSequenceId ?? call.endSequenceId)
    }

    /// Something the call log has to say once (Listen could not start).
    func show(notice: String) {
        state.notice = notice
    }

    /// The call's summaries as one text to read aloud, with its title and room.
    func readable(_ id: String) -> (title: String, markdown: String, sessionId: String)? {
        guard let row = state.rows.first(where: { $0.id == id }), !row.summaries.isEmpty,
              let call = calls.first(where: { $0.id == id }) else { return nil }
        let text = row.summaries.map { "\($0.author): \($0.text)" }.joined(separator: "\n\n")
        return ("Call with \(row.title)", text, call.sessionId)
    }

    static func hidden(_ call: SentiCall) -> SentiCall {
        let hide = TicketSignal.hideModelName
        return SentiCall(kind: call.kind, id: call.id, sessionId: call.sessionId, roomTitle: hide(call.roomTitle),
                         status: call.status, startedAt: call.startedAt, endedAt: call.endedAt, with: call.with,
                         isMeeting: call.isMeeting, durationText: call.durationText, turns: call.turns,
                         timingsText: call.timingsText, transcriptAttachmentId: call.transcriptAttachmentId,
                         summaries: call.summaries.map { SentiCall.Summary(author: $0.author, text: hide($0.text),
                                                                           createdAt: $0.createdAt) },
                         startSequenceId: call.startSequenceId, endSequenceId: call.endSequenceId,
                         direction: call.direction, callerName: call.callerName, calleeName: call.calleeName,
                         reason: call.reason.map(hide))
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
