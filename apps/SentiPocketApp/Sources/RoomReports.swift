import Foundation
import PocketUI

/// Reporting someone else's message or reply (App Store guideline 1.2). A protocol so the room is testable without a
/// network.
protocol RoomReporting: Sendable {
    func report(sessionId: String, _ request: RoomReportRequest) async throws
}

/// The report as the API takes it: `{"sequenceId", "reason", "note"}`. The note is at most 500 code points; a reply is
/// reported on its thread's message and named at the note's start (`RoomReportTarget.apiNote`).
struct RoomReportRequest: Equatable, Sendable {
    let sequenceId: Int64
    let reason: RoomReportReason
    let note: String?

    init(target: RoomReportTarget, reason: RoomReportReason, note written: String) {
        sequenceId = target.sequenceId
        self.reason = reason
        note = target.apiNote(written)
    }

    var body: [String: Any] {
        ["sequenceId": sequenceId, "reason": reason.rawValue, "note": note.map { $0 as Any } ?? NSNull()]
    }
}

extension HTTPRoomMessageSender: RoomReporting {
    /// `POST /api/v1/sessions/{id}/reports` with your own bearer. 201 (or 200 for a report already open) is sent;
    /// anything else did not go: offline, the API without the route yet (404), a message it cannot find, or too many.
    func report(sessionId: String, _ request: RoomReportRequest) async throws {
        let (_, http) = try await postAnswer(sessionId: sessionId, path: "reports",
                                             idempotencyKey: "report-" + UUID().uuidString.lowercased(),
                                             body: request.body)
        switch http.statusCode {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403: throw RoomSendError.notAllowed
        case 400, 413, 422: throw RoomSendError.rejected
        default: throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
    }
}
