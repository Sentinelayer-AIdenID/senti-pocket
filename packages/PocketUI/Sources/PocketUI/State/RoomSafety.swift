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

    /// What VoiceOver says when a report's outcome comes: sent, not sent, or refused; nothing while it is chosen or sent.
    public static func announcement(for phase: RoomReportState.Phase) -> String? {
        switch phase {
        case .sent: return thanks
        case .failed: return notSent
        case .refused: return refused
        case .choosing, .sending: return nil
        }
    }

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

/// Someone to block: their messages and replies show as one line in every room, which Show opens once. Chosen on a
/// message or a reply, it names that post too, so the server ties the block to the author you saw there.
public struct RoomBlockTarget: Equatable, Identifiable, Sendable {
    /// As messages carry it (`human-<login>` or an agent id).
    public let actorId: String
    public let name: String
    /// The message Block was chosen on, or the message the reply is on; nil from Blocked people.
    public let sequenceId: Int64?
    /// The reply Block was chosen on (its action id, the API's `replyId`).
    public let replyId: String?

    public init(actorId: String, name: String, sequenceId: Int64? = nil, replyId: String? = nil) {
        self.actorId = actorId
        self.name = name
        self.sequenceId = sequenceId
        self.replyId = replyId
    }

    /// The author of a post you reported, with that post.
    public init(_ post: RoomReportTarget, name: String? = nil) {
        self.init(actorId: post.authorId, name: name ?? post.authorName, sequenceId: post.sequenceId,
                  replyId: post.replyId)
    }

    public var id: String { actorId.lowercased() }

    /// An agent, not a person: blocked by this one id, so the same agent under another id is not.
    public var isAgent: Bool { !actorId.lowercased().hasPrefix("human-") }
}

public enum RoomBlocking {
    public static let hiddenLine = "Message from someone you blocked"

    /// What blocking does and doesn't do, said before you block.
    public static func confirmation(for target: RoomBlockTarget) -> String {
        let what = target.isAgent
            ? "Blocking an agent blocks this one id, \(target.id): the same agent under another id isn't blocked."
            : "Blocking a person doesn't hide their agents' messages."
        return "Their messages and replies show as one line in every room, and room search hides their words. "
            + calls + " " + what + " They aren't told, and you can unblock them in Settings."
    }

    /// What blocking does to calls (the server doesn't ring you for someone you blocked, so the call shows as missed),
    /// and what it leaves as it is.
    public static let calls = "Their calls don't ring your phone and may show as missed, and Waiting on you still "
        + "shows their questions."

    /// Blocks are by author id: a person's agents post under their own ids, and an agent can post under more than one.
    public static let byId = "Blocking a person doesn't hide their agents' messages, and blocking one agent id doesn't "
        + "block the same agent under another id."

    /// The server's own posts (checkpoints, joins) can't be blocked.
    public static let serverAuthor = "senti"

    /// The smallest tap a control takes, in points (Apple's Human Interface Guidelines).
    public static let minimumTapSize: CGFloat = 44

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
    /// The two answers: Agree records consent for this account; Not now sends nothing.
    public static let agree = "Agree"
    public static let notNow = "Not now"
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
             .revealBlocked, .allowAIAgents, .declineAIAgents, .loadOlderReplies, .loadLaterReplies, .continueToReply,
             .jumpToNewestReplies:
            return false
        }
    }
}
