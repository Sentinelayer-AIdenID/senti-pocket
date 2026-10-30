import Foundation

/// The fast voice line (API #1062): a short spoken answer to a call turn, grounded in the room, streamed sentence by
/// sentence in about a second instead of waiting for an agent to write one (Carter, 10-30: each answer took 18 s). It
/// speaks as "<agent> (voice)", never as the agent itself; the agent's own answer still comes in the room after.
enum VoiceLineEvent: Equatable, Sendable {
    case sentence(String)
    case done(speaker: String)
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
    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error>
}

/// One earlier turn of the call, for the voice line's context.
struct VoiceLineHistory: Equatable, Sendable {
    let speaker: String
    let text: String
}

/// Reads the voice line's Server-Sent Events: `event: sentence` / `data: {"text"}`, then `event: done` /
/// `data: {"speaker", "chars"}`, or `event: error`. Each event is taken at its `data:` line, so a reader that drops
/// blank lines still parses it.
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
        case "error":
            return .failed
        default:
            return .none
        }
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
