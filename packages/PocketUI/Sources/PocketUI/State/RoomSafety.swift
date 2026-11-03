import Foundation

/// Why a message is reported, as the API names it (`POST /api/v1/sessions/{id}/reports`), in the order the report
/// sheet lists them.
public enum RoomReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam
    case harassment
    case hate
    case sexual
    case violence
    case selfHarm = "self_harm"
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment or bullying"
        case .hate: return "Hate"
        case .sexual: return "Sexual content"
        case .violence: return "Violence or threats"
        case .selfHarm: return "Self-harm"
        case .other: return "Something else"
        }
    }
}

/// What a report is about: someone else's message, or a reply. The API reads messages by their sequence, so a reply is
/// reported on its thread's message and named at the start of the note, for whoever reviews it.
public struct RoomReportTarget: Equatable, Identifiable, Sendable {
    public let sequenceId: Int64
    /// The reply's own action id, for a reply.
    public let replyId: String?
    /// Who wrote it, as messages carry it (`human-<login>` or an agent id).
    public let authorId: String
    public let authorName: String

    public init(sequenceId: Int64, replyId: String? = nil, authorId: String, authorName: String) {
        self.sequenceId = sequenceId
        self.replyId = replyId
        self.authorId = authorId
        self.authorName = authorName
    }

    public var id: String { replyId.map { "reply:\($0)" } ?? "msg:\(sequenceId)" }

    /// What the stored note starts with for a reply.
    public var notePrefix: String? { replyId.map { "Reply \($0)" } }

    /// The longest note you can write: the API's limit, less the reply's name and its line break.
    public var noteLimit: Int {
        RoomReport.noteLimit - (notePrefix.map { $0.unicodeScalars.count + 1 } ?? 0)
    }

    /// The note as the API takes it: the reply's name, then what you wrote (cut to fit, and without NUL, which the API
    /// refuses), or nil when there is neither.
    public func apiNote(_ written: String) -> String? {
        let clean = written.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = RoomReport.clamped(clean, to: noteLimit)
        let parts = [notePrefix, trimmed.isEmpty ? nil : trimmed].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// The report sheet: choosing a reason, sending, sent, or not sent.
public struct RoomReportState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case choosing
        case sending
        case sent
        /// It did not go; the sheet keeps the reason and note so it can be sent again.
        case failed
    }

    public let target: RoomReportTarget
    public var phase: Phase
    /// You have blocked its author: once sent, the sheet says so instead of offering to block.
    public var authorIsBlocked: Bool
    /// You can block from here.
    public var canBlock: Bool

    public init(target: RoomReportTarget, phase: Phase = .choosing, authorIsBlocked: Bool = false, canBlock: Bool = false) {
        self.target = target
        self.phase = phase
        self.authorIsBlocked = authorIsBlocked
        self.canBlock = canBlock
    }
}

public enum RoomReport {
    /// The API's limit on a report's note, in Unicode code points (it counts with Python's len).
    public static let noteLimit = 500
    public static let thanks = "Thanks. We'll review it within 24 hours."
    public static let notSent = "Your report couldn't be sent right now. Try again in a little while."

    /// `text` cut to at most `limit` code points, never inside a character.
    public static func clamped(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var kept = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard count + size <= limit else { break }
            kept.append(character)
            count += size
        }
        return kept
    }
}

/// Someone you blocked: their messages and replies show as one line in every room, which Show opens once.
public struct RoomBlockTarget: Equatable, Identifiable, Sendable {
    /// As messages carry it (`human-<login>` or an agent id).
    public let actorId: String
    public let name: String

    public init(actorId: String, name: String) {
        self.actorId = actorId
        self.name = name
    }

    public var id: String { actorId.lowercased() }
}

public enum RoomBlocking {
    public static let hiddenLine = "Message from someone you blocked"
    public static let confirmation = "Their messages and replies show as one line in every room. They aren't told, "
        + "and you can unblock them in Settings."

    /// What Show opens: a message, or a reply wherever it shows (in the room or in its thread).
    public static func revealKey(message id: String) -> String { "msg:\(id)" }
    public static func revealKey(reply id: String) -> String { "reply:\(id)" }

    public static func revealKey(_ row: RoomChatMessageRow) -> String {
        row.inlineReplyId.map(revealKey(reply:)) ?? revealKey(message: row.id)
    }
}

/// What a person is told, once per account, before what they send in a room reaches its AI agents (App Store
/// guideline 5.1.2(i)). Never names the providers.
public enum AIConsentText {
    public static let notice = "Messages you send in a room are shared with the AI agents in that room, which run on AI "
        + "models from third-party providers, to read and answer them."
    public static let settingsHint = "You can change this in Settings, under AI and your messages."
}
