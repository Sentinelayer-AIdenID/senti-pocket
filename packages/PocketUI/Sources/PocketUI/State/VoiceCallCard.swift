import Foundation

/// The two messages that open and close a voice room in the room, written by the phone and read back to fold the call
/// into one card. Plain text, so the web and every agent read them as ordinary messages; the mentions in the opening
/// one are the ring.
public enum VoiceCallMarkers {
    static let startPrefix = "📞 Calling "
    static let endPrefix = "📞 Voice room with "

    /// "📞 Calling @pocket-forge: …" (one agent) or "📞 Calling @a @b: …" (a meeting).
    public static func start(caller: String, agents: [String], meeting: Bool) -> String {
        let mentions = agents.map { "@\($0)" }.joined(separator: " ")
        let what = meeting ? "a voice meeting" : "a voice room with you"
        let floor = meeting
            ? " In a meeting the first agent to answer a turn has the floor: if another agent already answered it, or the "
                + "phone posts that someone has the floor, stay quiet until the next turn."
            : ""
        // The phone rings until an answer lands and reads it before listening (Carter, 10-30): pick up at once.
        return "\(startPrefix)\(mentions): \(caller) started \(what). The phone is ringing: pick up now with a "
            + "one-line hello, which is read before they speak. Then answer each of their spoken turns as a short "
            + "top-level post: 1–3 spoken sentences, no markdown. The phone reads it aloud in your own voice." + floor
    }

    /// "📞 Adding @claude-warden: …", an agent brought into a call already going (Carter, 10-30). The others in the
    /// call are named without a mention, so only the added agent is rung.
    public static func added(caller: String, agent: String, joining others: [String]) -> String {
        let with = others.isEmpty ? "" : " with " + others.joined(separator: ", ")
        return "\(addPrefix)@\(agent): \(caller) added you to a voice room already going\(with). The phone is waiting: "
            + "join now with a one-line hello, which is read before they speak. Then answer each of their spoken turns "
            + "as a short top-level post: 1–3 spoken sentences, no markdown. The phone reads it aloud in your own voice. "
            + "The first agent to answer a turn has the floor: if another agent already answered it, or the phone posts "
            + "that someone has the floor, stay quiet until the next turn."
    }

    static let addPrefix = "📞 Adding "

    /// The agents an opening message calls, or nil when the text does not open a call.
    public static func calledAgents(in text: String) -> [String]? {
        mentions(after: startPrefix, in: text)
    }

    /// The agents a message adds to a call already going, or nil when the text does not add any.
    public static func addedAgents(in text: String) -> [String]? {
        mentions(after: addPrefix, in: text)
    }

    private static func mentions(after prefix: String, in text: String) -> [String]? {
        guard text.hasPrefix(prefix), let colon = text.firstIndex(of: ":") else { return nil }
        let names = text[text.index(text.startIndex, offsetBy: prefix.count)..<colon]
            .split(separator: " ")
            .compactMap { word -> String? in
                guard word.hasPrefix("@"), word.count > 1 else { return nil }
                return String(word.dropFirst()).lowercased()
            }
        return names.isEmpty ? nil : names
    }

    public static func isEnd(_ text: String) -> Bool {
        text.hasPrefix(endPrefix) && text.contains(" ended")
    }
}

/// A voice room shown as one card in the room: who, how long, live or ended, and the whole conversation, which opens
/// with a tap. Carter: a call should not be all over the room.
public struct VoiceCallCard: Equatable, Sendable {
    public struct Turn: Equatable, Identifiable, Sendable {
        public let id: String
        public let speaker: String
        public let isHuman: Bool
        public let text: String
        public let at: Date?
    }

    public let id: String
    public let agents: [String]
    public let caller: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let turns: [Turn]
    /// The transcript the closing message carries. That message folds into the card, so the card offers the file
    /// itself (found porting the card to the web, #694: otherwise the file can't be reached from the room).
    public var transcript: RoomAttachmentChip?

    public var isLive: Bool { endedAt == nil }

    public var title: String {
        switch agents.count {
        case 0: return "Voice room"
        case 1: return "Voice room with \(agents[0])"
        default: return "Voice meeting with " + agents.dropLast().joined(separator: ", ") + " and " + (agents.last ?? "")
        }
    }

    /// A call never stretches past this, so one that was never closed does not swallow the room.
    public static let longestCall: TimeInterval = 30 * 60

    /// Takes each voice room out of the rows, oldest first: from its opening message to its closing one, the caller's
    /// spoken turns and the called agents' posts become the card on the opening message. The agents' posts leave the
    /// room only for a call that closed with its closing message: a call that never closed (the app quit mid-call)
    /// lists them on its card and hides none of them (warden). Anything else in that stretch stays as it was.
    public static func fold(_ inputs: [RoomChatMessageInput]) -> (kept: [RoomChatMessageInput], cards: [String: VoiceCallCard]) {
        var kept: [RoomChatMessageInput] = []
        kept.reserveCapacity(inputs.count)
        var cards: [String: VoiceCallCard] = [:]
        var index = 0
        while index < inputs.count {
            let input = inputs[index]
            guard input.isHuman, input.kind == .message, !input.isInlineReply,
                  var agents = VoiceCallMarkers.calledAgents(in: input.text) else {
                kept.append(input)
                index += 1
                continue
            }
            let caller = input.authorId.lowercased()
            let limit = input.date.map { $0.addingTimeInterval(longestCall) }
            let closed = closes(after: index, in: inputs, caller: caller, limit: limit)
            var turns: [Turn] = []
            var others: [RoomChatMessageInput] = []
            var endedAt: Date?
            var transcript: RoomAttachmentChip?
            var next = index + 1
            while next < inputs.count {
                let candidate = inputs[next]
                if let limit, let at = candidate.date, at > limit { break }
                let fromCaller = candidate.isHuman && candidate.authorId.lowercased() == caller
                if fromCaller, candidate.kind == .message, VoiceCallMarkers.calledAgents(in: candidate.text) != nil {
                    // A new call from the same person closes this one where it stopped.
                    endedAt = turns.last?.at ?? input.date
                    break
                }
                if fromCaller, VoiceCallMarkers.isEnd(candidate.text) {
                    endedAt = candidate.date ?? input.date
                    transcript = candidate.attachments.first
                    next += 1
                    break
                }
                if fromCaller, candidate.kind == .message, let added = VoiceCallMarkers.addedAgents(in: candidate.text) {
                    // Someone brought in mid-call: from here their answers are the call's too, and the message that
                    // added them leaves the room with the call, like the answers.
                    for agent in added where !agents.contains(agent) { agents.append(agent) }
                    if !closed { others.append(candidate) }
                    next += 1
                    continue
                }
                let fromCalled = !candidate.isHuman && agents.contains(candidate.authorId.lowercased())
                if candidate.kind == .message, (fromCaller && candidate.isVoiceTurn) || fromCalled {
                    turns.append(Turn(id: candidate.id, speaker: candidate.authorName, isHuman: candidate.isHuman,
                                      text: candidate.text, at: candidate.date))
                    if fromCalled, !closed { others.append(candidate) }
                } else {
                    others.append(candidate)
                }
                next += 1
            }
            if endedAt == nil, let limit, let last = turns.last?.at ?? input.date, Date() > limit {
                endedAt = last
            }
            cards[input.id] = VoiceCallCard(id: input.id, agents: agents, caller: input.authorName,
                                            startedAt: input.date, endedAt: endedAt, turns: turns, transcript: transcript)
            kept.append(input)
            kept.append(contentsOf: others)
            index = next
        }
        return (kept, cards)
    }

    /// Whether the call opened at `index` closes with its caller's closing message before the limit, and before the
    /// same caller opens another call.
    static func closes(after index: Int, in inputs: [RoomChatMessageInput], caller: String, limit: Date?) -> Bool {
        var next = index + 1
        while next < inputs.count {
            let candidate = inputs[next]
            if let limit, let at = candidate.date, at > limit { return false }
            if candidate.isHuman, candidate.authorId.lowercased() == caller {
                if VoiceCallMarkers.isEnd(candidate.text) { return true }
                if candidate.kind == .message, VoiceCallMarkers.calledAgents(in: candidate.text) != nil { return false }
            }
            next += 1
        }
        return false
    }

    /// "4 turns · 3 min", or "live · 4 turns".
    public func summary(now: Date = Date()) -> String {
        let count = "\(turns.count) \(turns.count == 1 ? "turn" : "turns")"
        guard let startedAt else { return count }
        if isLive { return "live · \(count)" }
        let seconds = max(0, Int((endedAt ?? now).timeIntervalSince(startedAt)))
        let length = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
        return "\(count) · \(length)"
    }
}
