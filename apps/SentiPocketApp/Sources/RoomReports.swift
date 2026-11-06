import Foundation
import PocketContracts
import PocketUI

/// Reporting someone else's message or reply (App Store guideline 1.2). A protocol so the room is testable without a
/// network.
protocol RoomReporting: Sendable {
    func report(sessionId: String, _ request: RoomReportRequest) async throws
}

/// The report as the API takes it: `{"sequenceId", "replyId"?, "reason", "note"}`. A reply is reported under its own
/// id (`replyId`, on the message it answers), so its own author and words are what is reviewed. The note is at most
/// 500 code points.
struct RoomReportRequest: Equatable, Sendable {
    let sequenceId: Int64
    let replyId: String?
    let reason: RoomReportReason
    let note: String?

    init(target: RoomReportTarget, reason: RoomReportReason, note written: String) {
        sequenceId = target.sequenceId
        replyId = target.replyId
        self.reason = reason
        note = target.apiNote(written)
    }

    var body: [String: Any] {
        var body: [String: Any] = ["sequenceId": sequenceId, "reason": reason.rawValue, "note": note.map { $0 as Any } ?? NSNull()]
        if let replyId { body["replyId"] = replyId }
        return body
    }
}

extension HTTPRoomMessageSender: RoomReporting {
    /// `POST /api/v1/sessions/{id}/reports` with your own bearer. 201 is sent. The server refusing it (403; 404 with
    /// its own code, for a room or message it won't report; 422, your own post among them) is `rejected` or
    /// `notAllowed`: trying again won't help. Anything else may go later: offline, too many (429), or an API without the
    /// route yet (a bare 404).
    func report(sessionId: String, _ request: RoomReportRequest) async throws {
        let (data, http) = try await postAnswer(sessionId: sessionId, path: "reports",
                                                idempotencyKey: "report-" + UUID().uuidString.lowercased(),
                                                body: request.body)
        try Self.reportOutcome(status: http.statusCode, body: data,
                               retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
    }

    /// What a report's answer means (see `report`).
    static func reportOutcome(status: Int, body: Data, retryAfter: Int? = nil) throws {
        switch status {
        case 200..<300:
            return
        case 401:
            throw RoomSendError.reauthenticationRequired
        case 403:
            throw RoomSendError.notAllowed
        case 404:
            let code = HTTPRoomTicketWriter.errorCode(try? JSONDecoder().decode(JSONValue.self, from: body))
            if code == "SESSION_NOT_FOUND" || code == "MESSAGE_NOT_FOUND" { throw RoomSendError.rejected }
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        case 400, 413, 422:
            throw RoomSendError.rejected
        default:
            throw RoomSendError.retryable(retryAfterSeconds: retryAfter)
        }
    }
}
