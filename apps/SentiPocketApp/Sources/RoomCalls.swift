import Foundation
import PocketContracts
import PocketSyncClient

/// An agent ringing you through the API (sentinelayer-api #1046). The VoIP push is a doorbell: only the call, its
/// room and who is calling (`{callId, sessionId, callerName}`). The details are read with your own session, and the
/// conversation happens in the room's voice room, never over the server.
struct RoomCallDoorbell: Equatable, Sendable {
    let callId: String
    let sessionId: String
    let callerName: String

    /// The doorbell, or nil for any other push. Identifiers are short and plain; a caller name is shown as given,
    /// cut to 80 characters.
    static func parse(_ payload: [AnyHashable: Any]) -> RoomCallDoorbell? {
        guard let callId = payload["callId"] as? String, isIdentifier(callId),
              let sessionId = payload["sessionId"] as? String, isIdentifier(sessionId) else { return nil }
        let name = ((payload["callerName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RoomCallDoorbell(callId: callId, sessionId: sessionId, callerName: name.isEmpty ? "Senti" : String(name.prefix(80)))
    }

    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}

/// A call as the API reads it to the person it rings (`GET /sessions/{id}/calls/{callId}`).
struct RoomCallDetails: Equatable, Sendable {
    let callId: String
    let sessionId: String
    /// Who rang: an agent's id, or `human-<login>`.
    let callerActorId: String
    let callerName: String
    let reason: String?
    /// ringing, answered, declined, ended or missed.
    let status: String
    let ringExpiresAt: Date?

    init(callId: String, sessionId: String, callerActorId: String, callerName: String, reason: String?, status: String,
         ringExpiresAt: Date?) {
        self.callId = callId
        self.sessionId = sessionId
        self.callerActorId = callerActorId
        self.callerName = callerName
        self.reason = reason
        self.status = status
        self.ringExpiresAt = ringExpiresAt
    }

    init?(json: JSONValue) {
        guard let callId = json["callId"]?.stringValue, let sessionId = json["sessionId"]?.stringValue,
              let caller = json["callerActorId"]?.stringValue, !caller.isEmpty else { return nil }
        self.init(
            callId: callId,
            sessionId: sessionId,
            callerActorId: caller,
            callerName: json["callerName"]?.stringValue ?? caller,
            reason: json["reason"]?.stringValue,
            status: json["status"]?.stringValue ?? "ringing",
            ringExpiresAt: json["ringExpiresAt"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date }
        )
    }
}

/// The calls API, as the person rung: read a call, and answer, decline or end it.
protocol RoomCallsAPI: Sendable {
    func call(sessionId: String, callId: String) async throws -> RoomCallDetails
    func setStatus(sessionId: String, callId: String, status: String) async throws
}

struct RoomCallsClient: RoomCallsAPI {
    let apiBaseURL: URL?
    var urlSession: URLSession = SentiHTTPTransportPolicy.liveSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    enum Failure: Error, Equatable { case notConfigured, signedOut, refused(Int), unreachable, unreadable }

    func call(sessionId: String, callId: String) async throws -> RoomCallDetails {
        let data = try await send("GET", path: "/api/v1/sessions/\(sessionId)/calls/\(callId)", body: nil)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let details = RoomCallDetails(json: json) else { throw Failure.unreadable }
        return details
    }

    func setStatus(sessionId: String, callId: String, status: String) async throws {
        _ = try await send("POST", path: "/api/v1/sessions/\(sessionId)/calls/\(callId)/status", body: ["status": status])
    }

    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw Failure.notConfigured
        }
        guard let bearer = tokenProvider(), !bearer.isEmpty else { throw Failure.signedOut }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status) }
        return data
    }
}

/// The calls agents ring you with, from the doorbell to the room (Carter's P0: agents call you). CallKit rings and
/// you answer there; the conversation is the room's voice room with the caller, which opens when the app is in
/// front. Declining, hanging up, and letting it ring out are told to the room through the API.
@MainActor
final class RoomCallDesk: ObservableObject {
    static let shared = RoomCallDesk()

    struct Call: Equatable {
        let uuid: UUID
        let doorbell: RoomCallDoorbell
        var details: RoomCallDetails?
        var answered = false
        var finished = false

        /// Whom the voice room talks with: the caller's id once read, else the name the doorbell carried.
        var partner: String { details?.callerActorId ?? doorbell.callerName }
    }

    /// An answered call waiting for its room to come on screen.
    @Published private(set) var waiting: Call?
    private(set) var calls: [UUID: Call] = [:]

    var api: any RoomCallsAPI
    /// Ends the system call (CallKit) for this UUID.
    var endSystemCall: (UUID) -> Void = { _ in }
    /// Puts the room on screen.
    var openRoom: (String) -> Void = { _ in }
    private let ringFor: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        api: any RoomCallsAPI = RoomCallsClient(apiBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL"])),
        ringFor: TimeInterval = 45,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.api = api
        self.ringFor = ringFor
        self.sleep = sleep
    }

    func owns(_ uuid: UUID) -> Bool { calls[uuid] != nil }

    /// CallKit showed the ring. The same call delivered again ends its second ring at once.
    func received(_ doorbell: RoomCallDoorbell, uuid: UUID) {
        LaunchUrgency.shared.raise()
        if calls.values.contains(where: { $0.doorbell.callId == doorbell.callId && !$0.finished }) {
            endSystemCall(uuid)
            return
        }
        calls[uuid] = Call(uuid: uuid, doorbell: doorbell)
        let api = self.api
        Task { [weak self] in
            let details = try? await api.call(sessionId: doorbell.sessionId, callId: doorbell.callId)
            guard let self, var call = self.calls[uuid] else { return }
            call.details = details
            self.calls[uuid] = call
            if self.waiting?.uuid == uuid { self.waiting = call }
            // Answered, declined or missed elsewhere already: stop ringing here.
            if let status = details?.status, status != "ringing", !call.answered {
                self.finish(uuid, report: nil)
                return
            }
            let expiry = details?.ringExpiresAt.map { $0.timeIntervalSinceNow } ?? self.ringFor
            await self.sleep(expiry)
            if let call = self.calls[uuid], !call.answered, !call.finished {
                // Nobody answered before the ring ran out; the server calls it missed.
                self.finish(uuid, report: nil)
            }
        }
    }

    /// Answered on the call screen: tell the room, then open it; its voice room starts once the app is in front.
    func answered(_ uuid: UUID) {
        guard var call = calls[uuid], !call.finished else { return }
        call.answered = true
        calls[uuid] = call
        report(call, "answered")
        waiting = call
        openRoom(call.doorbell.sessionId)
    }

    /// The call screen ended: before an answer that is a decline; after it, the end of the call.
    func ended(_ uuid: UUID) {
        guard let call = calls[uuid], !call.finished else { return }
        if waiting?.uuid == uuid {
            // Hung up before the voice room started.
            waiting = nil
        }
        markFinished(uuid)
        report(call, call.answered ? "ended" : "declined")
    }

    /// The room is on screen with the app in front: hand over the waiting call, ending the system call so its
    /// audio is free for the voice room.
    func takeWaiting(for sessionId: String) -> Call? {
        guard let call = waiting, call.doorbell.sessionId == sessionId else { return nil }
        waiting = nil
        endSystemCall(call.uuid)
        return call
    }

    /// The room's voice room for this call hung up.
    func voiceRoomEnded(_ call: Call) {
        guard let current = calls[call.uuid], !current.finished else { return }
        markFinished(call.uuid)
        report(current, "ended")
    }

    private func finish(_ uuid: UUID, report status: String?) {
        guard let call = calls[uuid], !call.finished else { return }
        markFinished(uuid)
        endSystemCall(uuid)
        if let status { report(call, status) }
    }

    private func markFinished(_ uuid: UUID) {
        calls[uuid]?.finished = true
    }

    /// Reports go one after another, so the server always hears "answered" before "ended".
    private var reporting: Task<Void, Never>?

    private func report(_ call: Call, _ status: String) {
        let api = self.api
        let previous = reporting
        reporting = Task {
            await previous?.value
            try? await api.setStatus(sessionId: call.doorbell.sessionId, callId: call.doorbell.callId, status: status)
        }
    }
}
