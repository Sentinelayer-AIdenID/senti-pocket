import Foundation
import PocketContracts

// Agents talk to their teammates: @all, @any and pairs (the API's agent-broadcast contract, ticket 2f95466a). What the
// phone reads of it, and every field name it reads, are here and only here, so a renamed field is a change to this
// file alone:
// - a room offers `@any` when its read says `features.agentBroadcast: true`;
// - a message carries who the server chose at write time in `payload.addressed`, and a thread reply (an action) in its
//   own `addressed`;
// - an agent in a box carries its box as `{id, index}`: `boxMember` on presence (`box: true` still says it is a box),
//   `agent.boxMember` on a message's author, and `actorBoxMember` beside a reply's flat `actorId`, so one who posted
//   but is not here now still groups.
// The phone never chooses who picks up an @any: it only shows what the server decided.

/// Who a message was addressed to, as the server decided when it was written (`payload.addressed`).
public struct RoomAddressed: Equatable, Sendable {
    /// The one agent the server chose for an `@any`.
    public let any: String?
    /// An `@any` that found no agent free.
    public let anyUnresolved: Bool
    /// The author was over their broadcast limit: the words were kept, nobody was asked.
    public let throttled: Bool
    /// An `@all` (or `@everyone`, `@here`).
    public let all: Bool

    public init(any: String? = nil, anyUnresolved: Bool = false, throttled: Bool = false, all: Bool = false) {
        self.any = any
        self.anyUnresolved = anyUnresolved
        self.throttled = throttled
        self.all = all
    }

    /// From what holds it: a message's payload, or a reply's action row. Nil when it carries no `addressed` object.
    init?(in holder: JSONValue) {
        guard let addressed = holder["addressed"], addressed.objectValue != nil else { return nil }
        let chosen = addressed["any"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            any: chosen?.isEmpty == false ? chosen : nil,
            anyUnresolved: addressed["anyUnresolved"]?.boolValue ?? false,
            throttled: addressed["throttled"]?.boolValue ?? false,
            all: addressed["all"]?.boolValue ?? false
        )
    }
}

/// The box an agent runs in, from its presence entry's `boxMember`: the box's id (8 hex characters) and the agent's
/// place in it.
public struct RoomAgentBox: Equatable, Hashable, Sendable {
    public let id: String
    public let index: Int

    public init(id: String, index: Int) {
        self.id = id
        self.index = index
    }

    /// "Box 3f2a": the first four characters of its id, until boxes have names.
    public var label: String { "Box \(id.prefix(4))" }

    /// From a presence entry or a message's author record (`boxMember`); nil for an agent outside any box.
    init?(entry: JSONValue) {
        guard let box = entry["boxMember"] else { return nil }
        self.init(box: box)
    }

    /// From the box itself (`{id, index}`); nil for one not in the contract's shape.
    init?(box: JSONValue) {
        guard let id = box["id"]?.stringValue, id.range(of: #"^[0-9a-f]{8}\z"#, options: .regularExpression) != nil,
              let index = box["index"]?.intValue, (Int64(0)...99).contains(index) else { return nil }
        self.init(id: id, index: Int(index))
    }
}

/// What a room offers, from its read (`GET /api/v1/sessions/{id}`): `@any` only when `features.agentBroadcast` is
/// true, and adding the agents you work with only when `features.addAgents` is (the server says it for the room's
/// owner or an admin, where it has contacts). Absent, or anything but true, is off.
public struct RoomFeatures: Decodable, Equatable, Sendable {
    public let agentBroadcast: Bool
    public let addAgents: Bool

    public init(agentBroadcast: Bool = false, addAgents: Bool = false) {
        self.agentBroadcast = agentBroadcast
        self.addAgents = addAgents
    }

    public init(from decoder: Decoder) throws {
        let room = try decoder.singleValueContainer().decode(JSONValue.self)
        self.init(agentBroadcast: room["features"]?["agentBroadcast"]?.boolValue == true,
                  addAgents: room["features"]?["addAgents"]?.boolValue == true)
    }
}

extension RoomAgentBox {
    /// The box of a message's author, from its author record (`agent.boxMember`).
    static func author(of event: JSONValue) -> RoomAgentBox? {
        event["agent"].flatMap(RoomAgentBox.init(entry:))
    }

    /// The box of a reply's author: an action carries its author flat, so its box sits beside `actorId`
    /// (`actorBoxMember`).
    static func actor(of action: JSONValue) -> RoomAgentBox? {
        action["actorBoxMember"].flatMap(RoomAgentBox.init(box:))
    }
}

extension HTTPSessionTransport {
    /// The room's read, for what it offers.
    public func roomFeatures(sessionId: String) async throws -> RoomFeatures {
        guard SessionIdentifier.isValid(sessionId) else { throw SessionTransportError.invalidRequest }
        return try await getDecodable(RoomFeatures.self, path: ["api", "v1", "sessions", sessionId], query: [])
    }
}
