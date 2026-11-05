import Foundation

/// The fast voice line (API #1062): a short spoken answer to a call turn, grounded in the room, streamed sentence by
/// sentence in about a second instead of waiting for an agent to write one (each answer used to take 18 s). It
/// speaks as "<agent> (voice)", never as the agent itself; the agent's own answer still comes in the room after.
enum VoiceLineEvent: Equatable, Sendable {
    case sentence(String)
    case done(speaker: String)
    /// The server gave the turn to an agent, before any of its answer's sound (`turn_assigned`).
    case turnAssigned(VoiceTurnAssignment)
    /// The answer's sound starts (`turn_started`) or ends (`turn_ended`); `turnId` when the server named it.
    case turnStarted(turnId: String?)
    case turnEnded(turnId: String?)
}

/// Who answers a turn, as the server assigns it (the shape agreed for the server's turn routing): the turn, the agent's
/// id, and the name the call shows ("Reviewer is answering").
struct VoiceTurnAssignment: Equatable, Sendable {
    let turnId: String
    let agentId: String
    let displayName: String
}

enum VoiceLineError: Error, Equatable {
    /// No voice line on this server (switched off, no model, or an older server): the call waits for the agents.
    case unavailable
    /// Too many asks: wait this long (the server's Retry-After) before the next.
    case rateLimited(retryAfter: TimeInterval?)
    case notAllowed
    case failed
}

/// Asking the voice line. A protocol so the call is testable without a network.
protocol VoiceLining: Sendable {
    /// `ringCallId` is the agent's call you answered, if this is one: the server reads why the agent called and its
    /// brief from it, so the quick answer can talk them through.
    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error>
}

/// One earlier turn of the call, for the voice line's context.
struct VoiceLineHistory: Equatable, Sendable {
    let speaker: String
    let text: String
}

/// Reads the voice line's Server-Sent Events: `event: sentence` / `data: {"text"}`, then `event: done` /
/// `data: {"speaker", "chars"}`, or `event: error`. Each event is taken at its `data:` line, so a reader that drops
/// blank lines still parses it. The turn's events come around the sentences: `event: turn_assigned` /
/// `data: {"turnId", "agentId", "displayName"}` before any sound, then `turn_started` and `turn_ended` /
/// `data: {"turnId"}`. An event this phone does not know, or one it cannot read, is skipped: it never ends the answer.
struct VoiceLineEventReader {
    private var event = ""

    enum Parsed: Equatable {
        case none
        case event(VoiceLineEvent)
        case failed
    }

    mutating func read(_ line: String) -> Parsed {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.hasPrefix("event:") {
            event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return .none
        }
        guard line.hasPrefix("data:") else { return .none }
        let data = Data(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces).utf8)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        defer { event = "" }
        switch event {
        case "sentence":
            guard let text = json["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            return .event(.sentence(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "done":
            return .event(.done(speaker: json["speaker"] as? String ?? ""))
        case "turn_assigned":
            guard let turnId = Self.identifier(json["turnId"]), let agentId = Self.identifier(json["agentId"]) else {
                return .none
            }
            let name = Self.displayName(json["displayName"]) ?? agentId
            return .event(.turnAssigned(VoiceTurnAssignment(turnId: turnId, agentId: agentId, displayName: name)))
        case "turn_started":
            return .event(.turnStarted(turnId: Self.identifier(json["turnId"])))
        case "turn_ended":
            return .event(.turnEnded(turnId: Self.identifier(json["turnId"])))
        case "error":
            return .failed
        default:
            return .none
        }
    }

    /// An id as the server sends it: a non-empty string of at most 128 characters, without spaces or control characters.
    private static func identifier(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= 128,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { return nil }
        return text
    }

    /// The name the call shows: one line (line breaks and control characters become single spaces), at most 60
    /// characters; nil when there is none.
    private static func displayName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(60))
    }
}

/// Has the person finished their turn? Asked of the signal model through the server
/// (`POST /sessions/{id}/voice/endpoint`) after a short pause; it answers in about 80 ms (measured 10-30), so a turn
/// can end on a 0.3 s pause instead of 1.4 s. A protocol so the call is testable without a network.
protocol VoiceEndpointing: Sendable {
    /// How likely the words so far are a finished turn, 0 to 1. Throws `VoiceLineError.unavailable` when the server
    /// has no endpointing.
    func finished(sessionId: String, text: String, callId: String) async throws -> Double
}
