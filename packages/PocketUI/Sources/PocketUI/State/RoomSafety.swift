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

/// What a report is about: someone else's message, or a reply on it (reported under its own id and author).
public struct RoomReportTarget: Equatable, Identifiable, Sendable {
    /// The message, or the message a reply is on.
    public let sequenceId: Int64
    /// The reply's own action id, for a reply (the API's `replyId`).
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

    /// The longest note you can write: the API's limit.
    public var noteLimit: Int { RoomReport.noteLimit }

    /// The note as the API takes it: what you wrote, cut to fit and without NUL (which the API refuses), or nil.
    public func apiNote(_ written: String) -> String? {
        let clean = written.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = RoomReport.clamped(clean, to: noteLimit)
        return trimmed.isEmpty ? nil : trimmed
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
        /// The server won't take it (the message is gone, it is yours, or you are no longer in the room): trying again
        /// would not help.
        case refused
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
    public static let refused = "This can't be reported. It may have been deleted, or you're no longer in this room."

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

    /// An agent, not a person: blocked by its name, so every agent with that name is blocked.
    public var isAgent: Bool { !actorId.lowercased().hasPrefix("human-") }
}

public enum RoomBlocking {
    public static let hiddenLine = "Message from someone you blocked"

    /// What blocking does and doesn't do, said before you block.
    public static func confirmation(for target: RoomBlockTarget) -> String {
        let who = target.isAgent
            ? "Blocking an agent blocks its name: every agent called \(target.name), in every room. Their"
            : "Their"
        return who + " messages and replies show as one line in every room, and room search hides their words. "
            + calls + " They aren't told, and you can unblock them in Settings."
    }

    /// What blocking leaves as it is.
    public static let calls = "Calls from them still ring, and Waiting on you still shows their questions."

    /// The server's own posts (checkpoints, joins) can't be blocked.
    public static let serverAuthor = "senti"

    /// What Show opens: a message, or a reply wherever it shows (in the room or in its thread).
    public static func revealKey(message id: String) -> String { "msg:\(id)" }
    public static func revealKey(reply id: String) -> String { "reply:\(id)" }

    public static func revealKey(_ row: RoomChatMessageRow) -> String {
        row.inlineReplyId.map(revealKey(reply:)) ?? revealKey(message: row.id)
    }
}

/// What a person is told, once per account, before anything they write in a room is shared with AI (App Store guideline
/// 5.1.2(i)). Says what is shared and with whom; never names the providers.
public enum AIConsentText {
    public static let title = "AI and what you share"
    public static let notice = "What you share in a room (messages, replies, files, tickets, and what you say on calls) "
        + "is shared with the AI agents in that room and with Senti's own AI features, such as room titles, progress "
        + "scoring and noticing when you've finished speaking on a call. These run on AI models from third-party "
        + "providers."
    public static let settingsHint = "You can change this in Settings, under AI and your messages."
}

extension RoomChatIntent {
    /// Writes something into the room (a message, a reply, a file, an edit, a reaction, a pin, a new name): it waits for
    /// this account's OK to share with AI (`AIConsentText`), asked once.
    public var isRoomWrite: Bool {
        switch self {
        case .sendMessage, .retrySend, .react, .sendReply, .sendReplyToReply, .reactToReply, .setEmojiReaction,
             .setPinned, .renameRoom, .editMessage, .editReply:
            return true
        case .dismissNotice, .loadOlder, .loadNewer, .jumpToLatest, .openTickets, .openSearch, .readerAtBottom,
             .bottomFlapHeld, .sendTapped, .retry, .jumpToMessage, .discardSend, .openThread, .closeThread,
             .openLeaderboard, .closeLeaderboard, .focusHandled, .openBreakout, .openAttachment, .shareAttachment,
             .readAloud, .stopReadingAloud, .attachmentAppeared, .messageOnScreen, .replyOnScreen, .toggleRepeats,
             .peopleOpened, .openInvite, .keepLatestForJumpDown, .openReport, .sendReport, .closeReport, .block,
             .revealBlocked, .allowAIAgents, .declineAIAgents:
            return false
        }
    }
}
