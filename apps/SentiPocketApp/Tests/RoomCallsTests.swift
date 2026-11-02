#if canImport(CallKit) && canImport(PushKit)
import CallKit
import Foundation
import PocketContracts
import XCTest
@testable import SentiPocketApp

/// The calls API as a recording fake. A read returns `details` (or the matching one of `others`), or throws `failure`;
/// it waits for `gate` when there is one. An answer throws `answerFailure` when set, and later reads then return
/// `readBack` (or throw `failure`).
private final class FakeCallsAPI: RoomCallsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String] = []
    private var reads = 0
    private var answerTried = false
    let details: RoomCallDetails?
    private let failure: any Error
    private let others: [RoomCallDetails]
    private let answerFailure: (any Error)?
    private let readBack: RoomCallDetails?
    private let gate: ReadGate?

    init(details: RoomCallDetails?, failure: any Error = RoomCallsClient.Failure.unreachable,
         others: [RoomCallDetails] = [], answerFailure: (any Error)? = nil, readBack: RoomCallDetails? = nil,
         gate: ReadGate? = nil) {
        self.details = details
        self.failure = failure
        self.others = others
        self.answerFailure = answerFailure
        self.readBack = readBack
        self.gate = gate
    }

    func call(sessionId: String, callId: String) async throws -> RoomCallDetails {
        await gate?.wait()
        let afterFailedAnswer = lock.withLock { () -> Bool in
            reads += 1
            return answerTried && answerFailure != nil
        }
        if afterFailedAnswer {
            guard let readBack else { throw failure }
            return readBack
        }
        if let other = others.first(where: { $0.callId == callId }) { return other }
        guard let details else { throw failure }
        return details
    }

    func setStatus(sessionId: String, callId: String, status: String) async throws {
        lock.withLock {
            statuses.append(status)
            if status == "answered" { answerTried = true }
        }
        if status == "answered", let answerFailure { throw answerFailure }
    }

    var sent: [String] { lock.withLock { statuses } }
    var readCount: Int { lock.withLock { reads } }
}

/// Holds reads until the test lets them through, so a call can be answered before it is read.
private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goes = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if goes { continuation.resume() }
        }
    }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        held.forEach { $0.resume() }
    }
}

/// Carter's P0: agents ring his phone (sentinelayer-api #1046). The push is a doorbell; CallKit rings; answering
/// opens the room, whose voice room talks with the caller.
@MainActor
final class RoomCallsTests: XCTestCase {
    private let doorbell = RoomCallDoorbell(callId: "call_1", sessionId: "e9e8dc5e-8d57-4603-975f-09156e3b4473",
                                            callerName: "pocket-forge")

    private func details(callId: String = "call_1", sessionId: String? = nil, caller: String = "pocket-forge",
                         status: String = "ringing", expires: Date? = nil) -> RoomCallDetails {
        RoomCallDetails(callId: callId, sessionId: sessionId ?? doorbell.sessionId, callerActorId: caller,
                        callerName: caller, reason: "Build 19 is up", status: status, ringExpiresAt: expires)
    }

    private func confirmed(_ desk: RoomCallDesk) async {
        await until("the server took the answer") { desk.waiting?.answerConfirmed == true }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Waits for what a detached task reports: a fixed number of yields was too few on a slow runner (#240's
    /// run 41027524317 got [] for ["declined"]).
    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func test_the_doorbell_is_the_call_the_room_and_the_caller_only() {
        XCTAssertEqual(RoomCallDoorbell.parse(["callId": "call_1", "sessionId": "room-1", "callerName": "  pocket-forge "]),
                       RoomCallDoorbell(callId: "call_1", sessionId: "room-1", callerName: "pocket-forge"))
        XCTAssertEqual(RoomCallDoorbell.parse(["callId": "c", "sessionId": "r"])?.callerName, "Senti", "no name, still a call")
        XCTAssertNil(RoomCallDoorbell.parse(["sessionId": "room-1", "callerName": "x"]), "a dial push has no callId")
        XCTAssertNil(RoomCallDoorbell.parse(["callId": "../etc", "sessionId": "room-1"]), "only plain identifiers")
        XCTAssertNil(RoomCallDoorbell.parse(["callId": String(repeating: "a", count: 129), "sessionId": "room-1"]))
        XCTAssertEqual(RoomCallDoorbell.parse(["callId": "c", "sessionId": "r", "callerName": String(repeating: "n", count: 200)])?
            .callerName.count, 80)
    }

    func test_a_doorbell_rings_by_the_callers_name_and_reaches_the_desk_only_when_signed_in() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reported: [(UUID, String?)] = []
        var ended: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { id, update, completion in
                reported.append((id, update.localizedCallerName))
                completion(true)
            },
            reportEndedCall: { ended.append($0) }
        )
        var received: [(RoomCallDoorbell, UUID)] = []
        manager.onRoomCallReceived = { received.append(($0, $1)) }
        var signedIn = true
        manager.isRoomCallAuthorized = { signedIn }
        var completions = 0
        let push: [AnyHashable: Any] = ["callId": "call_1", "sessionId": "room-1", "callerName": "pocket-forge",
                                        "aps": [String: Any]()]

        manager.handleIncomingPushPayload(push) { completions += 1 }
        await settle()
        XCTAssertEqual(reported.map(\.1), ["pocket-forge"], "the call screen names the caller")
        XCTAssertEqual(received.map(\.0.callId), ["call_1"])
        XCTAssertEqual(received.first?.1, reported.first?.0, "the desk gets the UUID CallKit rang")
        XCTAssertEqual(completions, 1)

        signedIn = false
        manager.handleIncomingPushPayload(push) { completions += 1 }
        await settle()
        XCTAssertEqual(reported.count, 2, "every push is reported, signed in or not")
        XCTAssertEqual(received.count, 1, "signed out, the call never reaches the desk")
        XCTAssertEqual(ended, [reported[1].0], "and its ring ends at once")
        XCTAssertEqual(reported[1].1, "Senti", "a ring not for the person signed in names no caller (warden, #298 review)")
        XCTAssertEqual(completions, 2)
    }

    /// An agent's call you answer talks at once. The voice room takes the answered call
    /// once CallKit gives it audio, inside the system call, which stays up until the voice room hangs up.
    func test_answering_tells_the_room_and_opens_it_and_the_voice_room_talks_inside_the_system_call() async {
        let api = FakeCallsAPI(details: details())
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var opened: [String] = []
        var endedSystem: [UUID] = []
        desk.openRoom = { opened.append($0) }
        desk.endSystemCall = { endedSystem.append($0) }
        let uuid = UUID()

        desk.received(doorbell, uuid: uuid)
        await until("read") { api.readCount == 1 }
        XCTAssertEqual(api.readCount, 1, "the details are read with your own session")
        desk.answered(uuid)
        await until("answered") { api.sent == ["answered"] }
        XCTAssertEqual(api.sent, ["answered"])
        await until("opened on the server's yes") { opened == [doorbell.sessionId] }
        XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId), "not before CallKit gives the call its audio")
        desk.audioActivated(uuid)
        XCTAssertEqual(desk.waiting?.audioReady, true, "the room hears that the waiting call can talk")
        XCTAssertNil(desk.takeWaiting(for: "another-room"))
        let taken = desk.takeWaiting(for: doorbell.sessionId)
        XCTAssertEqual(taken?.partner, "pocket-forge", "the voice room talks with the caller")
        XCTAssertTrue(endedSystem.isEmpty, "the system call stays up: its audio is the voice room's")
        XCTAssertNil(desk.waiting)
        XCTAssertTrue(desk.isLive(uuid))

        desk.voiceRoomEnded(taken!)
        await until("ended") { api.sent == ["answered", "ended"] }
        XCTAssertEqual(api.sent, ["answered", "ended"])
        XCTAssertEqual(endedSystem, [uuid], "hanging up in Pocket ends the system call")
        XCTAssertFalse(desk.isLive(uuid))
        desk.ended(uuid)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.sent, ["answered", "ended"], "an ended call is not ended twice")
        XCTAssertNil(desk.hungUp, "Pocket hung up, so nothing else has to")
    }

    /// Hanging up on the phone's own call screen (the call answered with the phone locked) ends the voice room too.
    func test_hanging_up_on_the_call_screen_ends_the_voice_room() async {
        let api = FakeCallsAPI(details: details())
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        desk.audioActivated(uuid)
        await confirmed(desk)
        XCTAssertNotNil(desk.takeWaiting(for: doorbell.sessionId))
        desk.ended(uuid)
        XCTAssertEqual(desk.hungUp, uuid, "the room's voice room is told to hang up")
        await until("ended") { api.sent == ["answered", "ended"] }
        desk.audioActivated(uuid)
        XCTAssertFalse(desk.isLive(uuid), "a late audio callback does not bring it back")
    }

    func test_ending_before_an_answer_declines_and_after_it_ends() async {
        let api = FakeCallsAPI(details: details(), others: [details(callId: "call_2", caller: "claude-warden")])
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let declined = UUID()
        desk.received(doorbell, uuid: declined)
        await settle()
        desk.ended(declined)
        await until("declined") { api.sent == ["declined"] }
        XCTAssertEqual(api.sent, ["declined"])

        let other = RoomCallDoorbell(callId: "call_2", sessionId: doorbell.sessionId, callerName: "claude-warden")
        let hungUp = UUID()
        desk.received(other, uuid: hungUp)
        desk.answered(hungUp)
        await confirmed(desk)
        desk.ended(hungUp)
        await until("answered, then ended") { api.sent == ["declined", "answered", "ended"] }
        XCTAssertEqual(api.sent, ["declined", "answered", "ended"])
        XCTAssertNil(desk.waiting, "hung up before the voice room took it: nothing waits")
        XCTAssertNotEqual(desk.hungUp, declined, "a declined call had no voice room to end")
    }

    /// Hanging up before the answer reached the server (the call was still being read) is a decline: the server
    /// never hears an answer for it.
    func test_hanging_up_before_the_answer_reached_the_server_declines() async {
        let gate = ReadGate()
        let api = FakeCallsAPI(details: details(), gate: gate)
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        desk.ended(uuid)
        await until("declined") { api.sent == ["declined"] }
        gate.open()
        await until("read") { api.readCount == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.sent, ["declined"], "no answer is sent for a call already hung up")
        XCTAssertNil(desk.waiting)
    }

    func test_a_repeated_doorbell_ends_its_second_ring_and_a_finished_call_stops_ringing() async {
        let api = FakeCallsAPI(details: details(status: "answered"))
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var endedSystem: [UUID] = []
        desk.endSystemCall = { endedSystem.append($0) }
        let first = UUID()
        let second = UUID()
        desk.received(doorbell, uuid: first)
        desk.received(doorbell, uuid: second)
        XCTAssertEqual(endedSystem.first, second, "the same call delivered again does not ring twice")
        await settle()
        XCTAssertEqual(endedSystem, [second, first], "answered elsewhere already: the ring here stops")
        XCTAssertTrue(api.sent.isEmpty, "nothing is reported for a call this phone never took")
    }

    func test_a_ring_nobody_answers_stops_when_it_runs_out() async {
        let api = FakeCallsAPI(details: details(expires: Date().addingTimeInterval(0.05)))
        let desk = RoomCallDesk(api: api, sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
        var endedSystem: [UUID] = []
        desk.endSystemCall = { endedSystem.append($0) }
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        for _ in 0..<100 where endedSystem.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(endedSystem, [uuid])
        XCTAssertTrue(api.sent.isEmpty, "the server calls it missed")
    }

    func test_the_voip_token_registers_with_its_kind_and_an_alert_token_without_one() {
        let voip = PushDeviceClient.registration(token: "ab", environment: "production", bundleId: "com.plexaura.sentipocket.app",
                                                 appVersion: "0.1.0", kind: "voip")
        XCTAssertEqual(voip["kind"] as? String, "voip")
        XCTAssertEqual(voip["bundleId"] as? String, "com.plexaura.sentipocket.app", "the server adds .voip to the topic")
        let alert = PushDeviceClient.registration(token: "cd", environment: "production", bundleId: "b", appVersion: nil, kind: nil)
        XCTAssertNil(alert["kind"], "a server without calls still accepts an alert token")
        XCTAssertNil(alert["appVersion"])
    }

    func test_call_details_read_as_the_api_writes_them() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"callId": "call_1", "sessionId": "room-1", "callerActorId": "pocket-forge", "callerName": "pocket-forge",
         "reason": "Build 19 is up", "status": "ringing", "createdAt": "2026-10-30T03:00:00Z",
         "ringExpiresAt": "2026-10-30T03:00:45Z"}
        """.utf8))
        let details = RoomCallDetails(json: json)
        XCTAssertEqual(details?.callerActorId, "pocket-forge")
        XCTAssertEqual(details?.status, "ringing")
        XCTAssertEqual(details?.ringExpiresAt, ParsedSessionTimestamp("2026-10-30T03:00:45Z").date)
        XCTAssertNil(RoomCallDetails(json: try JSONDecoder().decode(JSONValue.self, from: Data("{\"callId\": \"x\"}".utf8))))
        XCTAssertEqual(details?.briefsVoiceLine, false, "a turn names the call only when the server says so")

        let briefed = RoomCallDetails(json: try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"callId": "call_1", "sessionId": "room-1", "callerActorId": "pocket-forge", "status": "ringing",
         "voiceLineBrief": true}
        """.utf8)))
        XCTAssertEqual(briefed?.briefsVoiceLine, true)

        let statusless = RoomCallDetails(json: try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"callId": "call_1", "sessionId": "room-1", "callerActorId": "pocket-forge"}
        """.utf8)))
        XCTAssertNotEqual(statusless?.status, "ringing", "a call read without its status is not ringing")
        XCTAssertEqual(statusless?.isLiveRing(of: RoomCallDoorbell(callId: "call_1", sessionId: "room-1", callerName: "x"),
                                              at: Date()), false)
    }

    /// Warden (#281): Mute on the phone's call screen reaches the room's voice room.
    func test_mute_on_the_call_screen_is_kept_per_call() async {
        let desk = RoomCallDesk(api: FakeCallsAPI(details: details()),
                                sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        desk.setMuted(uuid, true)
        XCTAssertEqual(desk.muted, [uuid])
        desk.setMuted(uuid, false)
        XCTAssertTrue(desk.muted.isEmpty)
        desk.setMuted(UUID(), true)
        XCTAssertTrue(desk.muted.isEmpty, "a call this desk does not own is ignored")
    }

    /// The app's Mute is asked of the call screen, which mutes through `setMuted` like a
    /// tap there, so the app and the call screen never disagree. A call that is over is never asked about.
    func test_the_apps_mute_is_asked_of_the_call_screen_for_a_live_call_only() async {
        let desk = RoomCallDesk(api: FakeCallsAPI(details: details()),
                                sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var asked: [UUID] = []
        desk.muteSystemCall = { [weak desk] uuid, muted, done in
            asked.append(uuid)
            // CallKit performs it, and onMuted reaches the desk as a tap on the call screen does.
            desk?.setMuted(uuid, muted)
            done(true)
        }
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        let screen = RoomCallScreen(desk: desk, uuid: uuid)
        var results: [Bool] = []
        screen.setMuted(true) { results.append($0) }
        XCTAssertEqual(asked, [uuid])
        XCTAssertEqual(desk.muted, [uuid])
        screen.setMuted(false) { results.append($0) }
        XCTAssertTrue(desk.muted.isEmpty)

        desk.ended(uuid)
        screen.setMuted(true) { results.append($0) }
        desk.requestMuted(UUID(), true) { results.append($0) }
        XCTAssertEqual(results, [true, true, false, false])
        XCTAssertEqual(asked, [uuid, uuid], "a call that is over, or not this desk's, is never asked about")
    }

    /// The app's Mute asks CallKit to mute the call as if on its screen, so the call screen
    /// shows it too, and CallKit performing it reaches `onMuted` like a tap there. A call not live here is not asked.
    func test_the_apps_mute_is_a_callkit_mute_of_that_call() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var requested: [CXSetMutedCallAction] = []
        let manager = SentiCallManager(provider: provider, requestTransaction: { transaction, completion in
            requested += transaction.actions.compactMap { $0 as? CXSetMutedCallAction }
            completion(true)
        })
        var heard: [String] = []
        manager.onMuted = { uuid, muted in heard.append("\(uuid) \(muted)") }
        let call = IncomingDecisionCall(id: UUID(), dialId: "", callerDisplayName: "pocket-forge", message: "",
                                        context: nil, priority: "high")
        manager.ring(call)
        var results: [Bool] = []
        manager.requestMuted(call.id, true) { results.append($0) }
        XCTAssertEqual(requested.map(\.callUUID), [call.id])
        XCTAssertEqual(requested.map(\.isMuted), [true])
        XCTAssertEqual(results, [true])
        XCTAssertTrue(heard.isEmpty, "nothing is muted until CallKit performs it")
        if let action = requested.first { manager.provider(provider, perform: action) }
        XCTAssertEqual(heard, ["\(call.id) true"])

        manager.requestMuted(UUID(), true) { results.append($0) }
        XCTAssertEqual(results, [true, false])
        XCTAssertEqual(requested.count, 1, "a call not live here is never asked about")
    }

    /// Warden (#281): an answered call no voice room takes ends, rather than staying connected and silent.
    func test_an_answered_call_no_voice_room_takes_ends() async {
        let api = FakeCallsAPI(details: details(), others: [details(callId: "call_2", caller: "claude-warden")])
        let desk = RoomCallDesk(api: api, ringFor: 3_600, takeWithin: 0.05,
                                sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        var endedSystem: [UUID] = []
        desk.endSystemCall = { endedSystem.append($0) }
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        await until("ended") { endedSystem == [uuid] }
        await until("told the room") { api.sent == ["answered", "ended"] }
        XCTAssertNil(desk.waiting)
        XCTAssertFalse(desk.isLive(uuid))

        // One a voice room took in time is left alone (its own desk: the take now waits for the server's yes).
        let patient = RoomCallDesk(api: api, ringFor: 3_600, takeWithin: 0.3,
                                   sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        var endedLater: [UUID] = []
        patient.endSystemCall = { endedLater.append($0) }
        let taken = UUID()
        let other = RoomCallDoorbell(callId: "call_2", sessionId: doorbell.sessionId, callerName: "claude-warden")
        patient.received(other, uuid: taken)
        patient.answered(taken)
        patient.audioActivated(taken)
        await confirmed(patient)
        XCTAssertNotNil(patient.takeWaiting(for: doorbell.sessionId))
        try? await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(patient.isLive(taken))
        XCTAssertTrue(endedLater.isEmpty)
    }

    // MARK: - Only the server's live ring of this call becomes a call (#298 review)

    /// A call the server refuses to read, or answers unreadably, never starts: its ring ends, an answer given meanwhile
    /// ends with it, nothing is told to the server, and the room never opens. A refusal is not asked again.
    func test_a_call_the_server_will_not_read_never_starts() async {
        let failures: [any Error] = [RoomCallsClient.Failure.refused(401), RoomCallsClient.Failure.refused(403),
                                     RoomCallsClient.Failure.unreadable, RoomCallsClient.Failure.signedOut]
        for failure in failures {
            let gate = ReadGate()
            let api = FakeCallsAPI(details: nil, failure: failure, gate: gate)
            let desk = RoomCallDesk(api: api, retryAfter: 0, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
            var opened: [String] = []
            var endedSystem: [UUID] = []
            desk.openRoom = { opened.append($0) }
            desk.endSystemCall = { endedSystem.append($0) }
            let uuid = UUID()
            desk.received(doorbell, uuid: uuid)
            desk.answered(uuid)
            desk.audioActivated(uuid)
            XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId), "\(failure): not before the server read it")
            gate.open()
            await until("\(failure): the call ends") { endedSystem == [uuid] }
            XCTAssertNil(desk.waiting, "\(failure)")
            XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId), "\(failure)")
            XCTAssertFalse(desk.isLive(uuid), "\(failure)")
            XCTAssertTrue(opened.isEmpty, "\(failure): the room never opens")
            XCTAssertTrue(api.sent.isEmpty, "\(failure): nothing is told to the server")
            XCTAssertEqual(api.readCount, 1, "\(failure): a refusal is final")
        }
    }

    /// An unreachable server is read three times in all; still nothing, and the ring ends.
    func test_an_unreachable_server_is_read_three_times_then_the_ring_ends() async {
        let api = FakeCallsAPI(details: nil)
        let desk = RoomCallDesk(api: api, retryAfter: 0, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var endedSystem: [UUID] = []
        desk.endSystemCall = { endedSystem.append($0) }
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        await until("the ring ends") { endedSystem == [uuid] }
        XCTAssertEqual(api.readCount, 3)
        XCTAssertTrue(api.sent.isEmpty)
    }

    /// A read that is not this doorbell's live ring (another call, another room, a caller the server did not name,
    /// over already, or past its ring) ends the call it was answered as, before the room opens.
    func test_a_read_that_is_not_this_calls_live_ring_ends_it() async {
        let cases: [(String, RoomCallDetails)] = [
            ("another call", details(callId: "call_9")),
            ("another room", details(sessionId: "another-room")),
            ("no caller", details(caller: "")),
            ("declined", details(status: "declined")),
            ("missed", details(status: "missed")),
            ("past its ring", details(expires: Date().addingTimeInterval(-1))),
        ]
        for (name, read) in cases {
            let gate = ReadGate()
            let api = FakeCallsAPI(details: read, gate: gate)
            let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
            var opened: [String] = []
            var endedSystem: [UUID] = []
            desk.openRoom = { opened.append($0) }
            desk.endSystemCall = { endedSystem.append($0) }
            let uuid = UUID()
            desk.received(doorbell, uuid: uuid)
            desk.answered(uuid)
            desk.audioActivated(uuid)
            gate.open()
            await until("\(name): the call ends") { endedSystem == [uuid] }
            XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId), name)
            XCTAssertTrue(opened.isEmpty, "\(name): the room never opens")
            XCTAssertTrue(api.sent.isEmpty, "\(name): no answer is sent")
        }
    }

    /// Answered before the read lands: nothing is sent and the room stays shut until the server reads the call as
    /// its live ring; then the answer goes, and the room opens on the server's yes. The voice room talks with the
    /// caller the server named, never the name the push carried.
    func test_an_answer_before_the_read_waits_for_it_and_talks_with_the_caller_the_server_named() async {
        let gate = ReadGate()
        let api = FakeCallsAPI(details: details(caller: "pocket-forge"), gate: gate)
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var opened: [String] = []
        desk.openRoom = { opened.append($0) }
        let pushed = RoomCallDoorbell(callId: "call_1", sessionId: doorbell.sessionId, callerName: "someone-else")
        let uuid = UUID()
        desk.received(pushed, uuid: uuid)
        desk.answered(uuid)
        desk.audioActivated(uuid)
        await settle()
        XCTAssertTrue(api.sent.isEmpty, "no answer before the read")
        XCTAssertTrue(opened.isEmpty, "the room waits for the server")
        XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId))
        XCTAssertTrue(desk.isLive(uuid), "still pending, not ended")

        gate.open()
        await confirmed(desk)
        XCTAssertEqual(api.sent, ["answered"])
        XCTAssertEqual(opened, [doorbell.sessionId])
        XCTAssertEqual(desk.takeWaiting(for: doorbell.sessionId)?.partner, "pocket-forge")
    }

    /// The server refusing the answer (the call was taken, or is over) ends the call; the room never opens.
    func test_a_refused_answer_ends_the_call() async {
        let api = FakeCallsAPI(details: details(), answerFailure: RoomCallsClient.Failure.refused(409),
                               readBack: details(status: "answered"))
        let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        var opened: [String] = []
        var endedSystem: [UUID] = []
        desk.openRoom = { opened.append($0) }
        desk.endSystemCall = { endedSystem.append($0) }
        let uuid = UUID()
        desk.received(doorbell, uuid: uuid)
        desk.answered(uuid)
        desk.audioActivated(uuid)
        await until("the call ends") { endedSystem == [uuid] }
        XCTAssertEqual(api.sent, ["answered"])
        XCTAssertEqual(api.readCount, 1, "a refusal is not read back: answered by someone else is not yours")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId))
    }

    /// The answer's reply was lost (no answer, or an unreadable one). Reading the call back as answered cannot tell this
    /// phone's answer from another device's (#298 review: device A's reply is lost while device B answers), so the call
    /// ends whatever a read would say, and it is not read back at all.
    func test_a_lost_answer_reply_ends_the_call_even_when_the_call_reads_as_answered() async {
        let lost: [(String, any Error)] = [("no answer", RoomCallsClient.Failure.unreachable),
                                           ("unreadable answer", RoomCallsClient.Failure.unreadable)]
        for (name, failure) in lost {
            let api = FakeCallsAPI(details: details(), answerFailure: failure, readBack: details(status: "answered"))
            let desk = RoomCallDesk(api: api, sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
            var opened: [String] = []
            var endedSystem: [UUID] = []
            desk.openRoom = { opened.append($0) }
            desk.endSystemCall = { endedSystem.append($0) }
            let uuid = UUID()
            desk.received(doorbell, uuid: uuid)
            desk.answered(uuid)
            desk.audioActivated(uuid)
            await until("\(name): the call ends") { endedSystem == [uuid] }
            XCTAssertTrue(opened.isEmpty, "\(name): another device may have the call")
            XCTAssertNil(desk.takeWaiting(for: doorbell.sessionId), name)
            XCTAssertEqual(api.sent, ["answered"], "\(name): nothing else is told to the server")
            XCTAssertEqual(api.readCount, 1, "\(name): not read back")
        }
    }
}
#endif
