#if canImport(CallKit) && canImport(PushKit)
import CallKit
import Foundation
import PocketContracts
import XCTest
@testable import SentiPocketApp

/// The calls API as a recording fake.
private final class FakeCallsAPI: RoomCallsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String] = []
    private var reads = 0
    let details: RoomCallDetails?

    init(details: RoomCallDetails?) {
        self.details = details
    }

    func call(sessionId: String, callId: String) async throws -> RoomCallDetails {
        lock.withLock { reads += 1 }
        guard let details else { throw RoomCallsClient.Failure.unreachable }
        return details
    }

    func setStatus(sessionId: String, callId: String, status: String) async throws {
        lock.withLock { statuses.append(status) }
    }

    var sent: [String] { lock.withLock { statuses } }
    var readCount: Int { lock.withLock { reads } }
}

/// Carter's P0: agents ring his phone (sentinelayer-api #1046). The push is a doorbell; CallKit rings; answering
/// opens the room, whose voice room talks with the caller.
@MainActor
final class RoomCallsTests: XCTestCase {
    private let doorbell = RoomCallDoorbell(callId: "call_1", sessionId: "e9e8dc5e-8d57-4603-975f-09156e3b4473",
                                            callerName: "pocket-forge")

    private func details(status: String = "ringing", expires: Date? = nil) -> RoomCallDetails {
        RoomCallDetails(callId: "call_1", sessionId: doorbell.sessionId, callerActorId: "pocket-forge",
                        callerName: "pocket-forge", reason: "Build 19 is up", status: status, ringExpiresAt: expires)
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
        XCTAssertEqual(completions, 2)
    }

    func test_answering_tells_the_room_and_opens_it_and_the_voice_room_takes_over_in_front() async {
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
        XCTAssertEqual(opened, [doorbell.sessionId])
        XCTAssertNil(desk.takeWaiting(for: "another-room"))
        let taken = desk.takeWaiting(for: doorbell.sessionId)
        XCTAssertEqual(taken?.partner, "pocket-forge", "the voice room talks with the caller")
        XCTAssertEqual(endedSystem, [uuid], "the system call ends so the voice room has the audio")
        XCTAssertNil(desk.waiting)

        desk.voiceRoomEnded(taken!)
        await until("ended") { api.sent == ["answered", "ended"] }
        XCTAssertEqual(api.sent, ["answered", "ended"])
        desk.ended(uuid)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.sent, ["answered", "ended"], "an ended call is not ended twice")
    }

    func test_ending_before_an_answer_declines_and_after_it_ends() async {
        let api = FakeCallsAPI(details: details())
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
        desk.ended(hungUp)
        await until("answered, then ended") { api.sent == ["declined", "answered", "ended"] }
        XCTAssertEqual(api.sent, ["declined", "answered", "ended"])
        XCTAssertNil(desk.waiting, "hung up before the room opened: nothing waits")
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
    }
}
#endif
