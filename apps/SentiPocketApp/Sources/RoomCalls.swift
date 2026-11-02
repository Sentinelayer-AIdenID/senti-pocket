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
    /// The server says its voice line reads this call's brief when a turn names the call (`voiceLineBrief`). Only then
    /// does a turn carry the call: a refused turn is never taken to mean an older server.
    let briefsVoiceLine: Bool

    init(callId: String, sessionId: String, callerActorId: String, callerName: String, reason: String?, status: String,
         ringExpiresAt: Date?, briefsVoiceLine: Bool = false) {
        self.callId = callId
        self.sessionId = sessionId
        self.callerActorId = callerActorId
        self.callerName = callerName
        self.reason = reason
        self.status = status
        self.ringExpiresAt = ringExpiresAt
        self.briefsVoiceLine = briefsVoiceLine
    }

    /// The live ring of exactly this doorbell's call: same call and room, a caller the server named, still ringing,
    /// and not past its ring.
    func isLiveRing(of doorbell: RoomCallDoorbell, at now: Date) -> Bool {
        callId == doorbell.callId && sessionId == doorbell.sessionId && !callerActorId.isEmpty && status == "ringing"
            && (ringExpiresAt.map { $0 > now } ?? true)
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
            // A call read without its status is not taken to be ringing.
            status: json["status"]?.stringValue ?? "unknown",
            ringExpiresAt: json["ringExpiresAt"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date },
            briefsVoiceLine: json["voiceLineBrief"]?.boolValue ?? false
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
/// you answer there; the conversation is the room's voice room with the caller, inside the system call, so it talks
/// as soon as you answer, with the phone locked too. Declining, hanging up, and letting it ring out are told to the
/// room through the API.
@MainActor
final class RoomCallDesk: ObservableObject {
    static let shared = RoomCallDesk()

    struct Call: Equatable {
        let uuid: UUID
        let doorbell: RoomCallDoorbell
        /// The call as the server read it to you, set only when it is this doorbell's live ring.
        var details: RoomCallDetails?
        var answered = false
        /// The answer has gone to the server (it is told "ended" after this, "declined" before).
        var answerSent = false
        /// The server took the answer, or read the call back as answered when the answer's reply was lost.
        var answerConfirmed = false
        var finished = false
        /// CallKit has given the answered call its audio: the voice room can listen and speak.
        var audioReady = false

        /// Whom the voice room talks with: the caller as the server named it. The push's name only labels the ring.
        var partner: String? { details?.callerActorId }
    }

    /// An answered call waiting for its room's voice room to take it.
    @Published private(set) var waiting: Call?
    /// The last call the phone's own call screen hung up: its voice room ends too.
    @Published private(set) var hungUp: UUID?
    /// The calls muted on the phone's own call screen: their voice rooms do not listen.
    @Published private(set) var muted: Set<UUID> = []
    private(set) var calls: [UUID: Call] = [:]

    var api: any RoomCallsAPI
    /// Ends the system call (CallKit) for this UUID.
    var endSystemCall: (UUID) -> Void = { _ in }
    /// Mutes or unmutes the system call (CallKit) for this UUID as if on its screen; `done(false)` when it could not.
    var muteSystemCall: @MainActor (UUID, Bool, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, done in
        done(false)
    }
    /// Puts the room on screen.
    var openRoom: (String) -> Void = { _ in }
    private let ringFor: TimeInterval
    /// How long an answered call may wait for a voice room before it ends (warden, #281): never connected and silent.
    private let takeWithin: TimeInterval
    /// The pause before reading a call again when the server could not be reached.
    private let retryAfter: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: () -> Date

    init(
        api: any RoomCallsAPI = RoomCallsClient(apiBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL"])),
        ringFor: TimeInterval = 45,
        takeWithin: TimeInterval = 60,
        retryAfter: TimeInterval = 1,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.api = api
        self.ringFor = ringFor
        self.takeWithin = takeWithin
        self.retryAfter = retryAfter
        self.sleep = sleep
        self.now = now
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
        let retryAfter = self.retryAfter
        Task { [weak self] in
            let details = await Self.read(doorbell, api: api, retryAfter: retryAfter)
            guard let self, var call = self.calls[uuid], !call.finished else { return }
            // Only the server's live ring of this very call goes on: one it refused or could not be reached for, a
            // different call, or one answered, declined, missed or past its ring elsewhere stops ringing here, and an
            // answer already given ends with it. The push alone never starts a call.
            guard let details, details.isLiveRing(of: doorbell, at: self.now()) else {
                self.drop(uuid)
                return
            }
            call.details = details
            self.calls[uuid] = call
            if self.waiting?.uuid == uuid { self.waiting = call }
            self.sendAnswer(uuid)
            let expiry = details.ringExpiresAt.map { $0.timeIntervalSince(self.now()) } ?? self.ringFor
            await self.sleep(expiry)
            if let call = self.calls[uuid], !call.answered, !call.finished {
                // Nobody answered before the ring ran out; the server calls it missed.
                self.finish(uuid, report: nil)
            }
        }
    }

    /// The call as the server reads it to you. Only an unreachable server is asked again (three tries in all); a
    /// refusal or an unreadable answer is final.
    private static func read(_ doorbell: RoomCallDoorbell, api: any RoomCallsAPI,
                             retryAfter: TimeInterval) async -> RoomCallDetails? {
        for attempt in 1...3 {
            do {
                return try await api.call(sessionId: doorbell.sessionId, callId: doorbell.callId)
            } catch RoomCallsClient.Failure.unreachable where attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, retryAfter) * 1_000_000_000))
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Answered on the call screen. The answer goes to the server once the call is read as its live ring (at once,
    /// or when the read lands), and the room opens only when the server has taken it; its voice room then takes the
    /// call. One no voice room takes in time (Pocket was killed and the push woke it with no room on screen, or the
    /// call could not be confirmed) ends, rather than staying connected and silent.
    func answered(_ uuid: UUID) {
        guard var call = calls[uuid], !call.finished else { return }
        call.answered = true
        calls[uuid] = call
        waiting = call
        sendAnswer(uuid)
        let wait = takeWithin
        Task { [weak self] in
            await self?.sleep(wait)
            guard let self, self.waiting?.uuid == uuid, let call = self.calls[uuid], !call.finished else { return }
            self.waiting = nil
            self.finish(uuid, report: call.answerSent ? "ended" : nil)
        }
    }

    /// Tells the server an answered, verified call was answered, in order with the other reports. The room opens on
    /// the server's yes. A refusal ends the call. A lost reply (no answer, or one that could not be read) is settled by
    /// reading the call back: answered is a yes, anything else ends it.
    private func sendAnswer(_ uuid: UUID) {
        guard var call = calls[uuid], call.answered, !call.answerSent, !call.finished, call.details != nil else { return }
        call.answerSent = true
        calls[uuid] = call
        let api = self.api
        let doorbell = call.doorbell
        let previous = reporting
        let confirming = Task { () -> Bool in
            await previous?.value
            do {
                try await api.setStatus(sessionId: doorbell.sessionId, callId: doorbell.callId, status: "answered")
                return true
            } catch RoomCallsClient.Failure.refused(_) {
                return false
            } catch {
                guard let read = try? await api.call(sessionId: doorbell.sessionId, callId: doorbell.callId) else {
                    return false
                }
                return read.callId == doorbell.callId && read.sessionId == doorbell.sessionId && read.status == "answered"
            }
        }
        reporting = Task { _ = await confirming.value }
        Task { [weak self] in
            let confirmed = await confirming.value
            guard let self, var call = self.calls[uuid], !call.finished else { return }
            guard confirmed else {
                self.drop(uuid)
                return
            }
            call.answerConfirmed = true
            self.calls[uuid] = call
            if self.waiting?.uuid == uuid { self.waiting = call }
            self.openRoom(doorbell.sessionId)
        }
    }

    /// A call that is not the server's to take: its ring or its answered call ends, and nothing waits for it. Nothing
    /// is reported, since the server did not take this phone's word for the call.
    private func drop(_ uuid: UUID) {
        if waiting?.uuid == uuid { waiting = nil }
        finish(uuid, report: nil)
    }

    /// Mute or unmute on the phone's own call screen, or the app's Mute performed there.
    func setMuted(_ uuid: UUID, _ isMuted: Bool) {
        guard calls[uuid] != nil else { return }
        if isMuted { muted.insert(uuid) } else { muted.remove(uuid) }
    }

    /// The app's own Mute for a call that is live: asked of the call screen, which then mutes through `setMuted`
    /// exactly as a tap there does, so the app and the call screen never disagree.
    func requestMuted(_ uuid: UUID, _ isMuted: Bool, done: @escaping @MainActor (Bool) -> Void) {
        guard isLive(uuid) else {
            done(false)
            return
        }
        muteSystemCall(uuid, isMuted, done)
    }

    /// The call screen ended: before the answer reached the server that is a decline; after it, the end of the call,
    /// and its voice room hangs up too.
    func ended(_ uuid: UUID) {
        guard let call = calls[uuid], !call.finished else { return }
        if waiting?.uuid == uuid {
            // Hung up before the voice room started.
            waiting = nil
        }
        markFinished(uuid)
        report(call, call.answerSent ? "ended" : "declined")
        if call.answered { hungUp = uuid }
    }

    /// CallKit activated the audio of a call this desk owns.
    func audioActivated(_ uuid: UUID) {
        guard var call = calls[uuid], !call.finished else { return }
        call.audioReady = true
        calls[uuid] = call
        if waiting?.uuid == uuid { waiting = call }
    }

    /// Whether the call is still going (not ended, declined or missed).
    func isLive(_ uuid: UUID) -> Bool {
        calls[uuid].map { !$0.finished } ?? false
    }

    /// The room's voice room takes the answered call once CallKit has given it audio. The system call stays up: its
    /// audio is the voice room's, which is what keeps the call talking with the phone locked or Pocket in the
    /// background.
    func takeWaiting(for sessionId: String) -> Call? {
        guard let call = waiting, call.doorbell.sessionId == sessionId, call.audioReady, call.answerConfirmed,
              call.partner != nil else { return nil }
        waiting = nil
        return call
    }

    /// The room's voice room for this call hung up: the system call ends with it.
    func voiceRoomEnded(_ call: Call) {
        guard let current = calls[call.uuid], !current.finished else { return }
        markFinished(call.uuid)
        report(current, "ended")
        endSystemCall(call.uuid)
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

/// An answered call's screen, as its voice room sees it: the panel's Mute is asked of it.
@MainActor
final class RoomCallScreen: VoiceRoomCallScreen {
    private let desk: RoomCallDesk
    private let uuid: UUID

    init(desk: RoomCallDesk, uuid: UUID) {
        self.desk = desk
        self.uuid = uuid
    }

    func setMuted(_ on: Bool, done: @escaping @MainActor (Bool) -> Void) {
        desk.requestMuted(uuid, on, done: done)
    }
}
