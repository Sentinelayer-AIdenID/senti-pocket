import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

private final class RoomReadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answer: (Int, String) = (200, "{}")
    private static var requests: [URLRequest] = []

    static func reset(status: Int = 200, body: String) {
        lock.lock()
        answer = (status, body)
        requests = []
        lock.unlock()
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, body) = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Ticket 2f95466a, the API's agent-broadcast contract as the phone reads it: who an `@any` went to, the box an agent
/// runs in, and whether the room takes `@any` at all.
final class AgentBroadcastTests: XCTestCase {
    private func message(_ payload: String, event: String = "session_message") throws -> RoomMessage? {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"e1","event":"\(event)","sequenceId":12,"ts":"2026-11-06T18:30:00Z","agentId":"human-alex",
         "payload":\(payload)}
        """.utf8))
        return RoomMessage(json: json)
    }

    /// The server decides at write time who an `@any` goes to, or that nobody was free, or that the author was over
    /// their limit; the message carries it, and nothing when it says nothing.
    func test_a_message_carries_who_its_at_any_went_to() throws {
        let picked = try message(#"{"text":"@any can you look?","addressed":{"any":"build-agent"}}"#)
        XCTAssertEqual(picked?.addressed, RoomAddressed(any: "build-agent"))
        let nobody = try message(#"{"text":"@any can you look?","addressed":{"any":null,"anyUnresolved":true}}"#)
        XCTAssertEqual(nobody?.addressed, RoomAddressed(anyUnresolved: true))
        let throttled = try message(#"{"text":"@all again","addressed":{"throttled":true}}"#)
        XCTAssertEqual(throttled?.addressed, RoomAddressed(throttled: true))
        let all = try message(#"{"text":"@all ship it","addressed":{"all":true}}"#)
        XCTAssertEqual(all?.addressed, RoomAddressed(all: true))
        XCTAssertNil(try message(#"{"text":"plain"}"#)?.addressed, "no addressed: nothing")
        XCTAssertNil(try message(#"{"text":"odd","addressed":"build-agent"}"#)?.addressed, "not an object: nothing")
        XCTAssertNil(try message(#"{"text":"@any","addressed":{"any":"  "}}"#)?.addressed?.any, "a blank id is no one")
        XCTAssertNil(try message(#"{"title":"Plan","addressed":{"any":"build-agent"}}"#, event: "session_checkpoint")?
            .addressed, "only a message is addressed")
    }

    /// A thread reply (an action) carries the same `addressed` as a message.
    func test_a_thread_reply_carries_who_its_at_any_went_to() throws {
        func reply(_ addressed: String) throws -> RoomReply? {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"id":"act-1","actionType":"reply","targetSequenceId":12,"actorId":"human-alex",
             "note":"@any can you check?","createdAt":"2026-11-06T18:40:00Z"\(addressed)}
            """.utf8))
            return RoomReply(json: json)
        }
        XCTAssertEqual(try reply(#","addressed":{"any":"build-agent"}"#)?.addressed, RoomAddressed(any: "build-agent"))
        XCTAssertEqual(try reply(#","addressed":{"anyUnresolved":true}"#)?.addressed,
                       RoomAddressed(anyUnresolved: true))
        XCTAssertEqual(try reply(#","addressed":{"throttled":true}"#)?.addressed, RoomAddressed(throttled: true))
        XCTAssertNil(try reply("")?.addressed)
    }

    /// The author of a message carries its box (`agent.boxMember`), and a reply carries its author's beside its flat
    /// `actorId` (`actorBoxMember`), so one who posted but is not here now can still be grouped.
    func test_the_author_of_a_message_or_reply_carries_its_box() throws {
        let box = #"{"id":"senti-3f2a9c01-1","boxMember":{"id":"3f2a9c01","index":1}}"#
        let event = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"e1","event":"session_message","sequenceId":12,"ts":"2026-11-06T18:30:00Z","agent":\(box),
         "payload":{"text":"done"}}
        """.utf8))
        XCTAssertEqual(RoomMessage(json: event)?.authorBox, RoomAgentBox(id: "3f2a9c01", index: 1))
        func action(_ author: String) throws -> RoomReply? {
            RoomReply(json: try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"id":"act-1","actionType":"reply","targetSequenceId":12,"actorId":"senti-3f2a9c01-1","note":"on it",
             "createdAt":"2026-11-06T18:40:00Z",\(author)}
            """.utf8)))
        }
        XCTAssertEqual(try action(#""actorBoxMember":{"id":"3f2a9c01","index":1}"#)?.authorBox,
                       RoomAgentBox(id: "3f2a9c01", index: 1))
        XCTAssertNil(try action(#""agent":\#(box)"#)?.authorBox, "an action's box is beside actorId, not in an agent")
        XCTAssertNil(try action(#""actorBoxMember":{"id":"NOTHEX!!","index":1}"#)?.authorBox)
        XCTAssertNil(try message(#"{"text":"plain"}"#)?.authorBox, "an author outside any box")
    }

    /// `box: true` keeps meaning the agent runs in a box; `boxMember` says which box and its place in it.
    func test_box_true_with_box_member_is_a_box_and_says_which() throws {
        let presence = try JSONDecoder().decode(RoomPresence.self, from: Data("""
        {"status":"ok","humansOnline":0,"agentsOnline":4,"present":[
          {"agentId":"senti-3f2a9c01-2","kind":"agent","box":true,"boxMember":{"id":"3f2a9c01","index":2}},
          {"agentId":"build-agent","kind":"agent","box":true},
          {"agentId":"review-agent","kind":"agent"},
          {"agentId":"senti-zz","kind":"agent","box":true,"boxMember":{"id":"NOTHEX!!","index":1}},
          {"agentId":"senti-big","kind":"agent","box":true,"boxMember":{"id":"3f2a9c01","index":300}}
        ]}
        """.utf8))
        let byId = Dictionary(uniqueKeysWithValues: presence.participants.map { ($0.id, $0) })
        XCTAssertEqual(byId["senti-3f2a9c01-2"]?.isBox, true)
        XCTAssertEqual(byId["senti-3f2a9c01-2"]?.boxMember, RoomAgentBox(id: "3f2a9c01", index: 2))
        XCTAssertEqual(byId["senti-3f2a9c01-2"]?.boxMember?.label, "Box 3f2a")
        XCTAssertEqual(byId["build-agent"]?.isBox, true, "box: true alone is still a box")
        XCTAssertNil(byId["build-agent"]?.boxMember)
        XCTAssertEqual(byId["review-agent"]?.isBox, false)
        XCTAssertNil(byId["review-agent"]?.boxMember)
        XCTAssertNil(byId["senti-zz"]?.boxMember, "an id that is not 8 hex characters")
        XCTAssertNil(byId["senti-big"]?.boxMember, "a place past the contract's two digits")
    }

    /// The room takes `@any` only when its read says `features.agentBroadcast: true`; anything else is off.
    func test_the_room_read_offers_at_any_only_when_it_says_so() throws {
        func features(_ body: String) throws -> RoomFeatures {
            try JSONDecoder().decode(RoomFeatures.self, from: Data(body.utf8))
        }
        XCTAssertTrue(try features(#"{"id":"room_1","features":{"agentBroadcast":true}}"#).agentBroadcast)
        XCTAssertFalse(try features(#"{"id":"room_1","features":{"agentBroadcast":false}}"#).agentBroadcast)
        XCTAssertFalse(try features(#"{"id":"room_1","features":{}}"#).agentBroadcast)
        XCTAssertFalse(try features(#"{"id":"room_1"}"#).agentBroadcast)
        XCTAssertFalse(try features(#"{"id":"room_1","features":{"agentBroadcast":"true"}}"#).agentBroadcast)
    }

    /// It is the room's own read.
    func test_the_features_read_is_the_rooms_own_read() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomReadURLProtocol.self]
        let transport = HTTPSessionTransport(apiBaseURL: URL(string: "https://api.example.test")!,
                                             urlSession: URLSession(configuration: configuration),
                                             tokenProvider: { "session-token" })
        RoomReadURLProtocol.reset(body: #"{"id":"room_1","features":{"agentBroadcast":true}}"#)
        let features = try await transport.roomFeatures(sessionId: "room_1")
        XCTAssertTrue(features.agentBroadcast)
        let request = try XCTUnwrap(RoomReadURLProtocol.captured().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/room_1")
    }
}
