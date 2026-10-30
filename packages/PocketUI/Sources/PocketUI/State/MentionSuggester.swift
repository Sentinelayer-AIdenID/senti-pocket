import Foundation

/// Someone you can @-mention in a room.
public struct MentionCandidate: Equatable, Identifiable, Sendable {
    public var id: String { handle }
    /// What gets typed after the @: a person's login or an agent's id. The API notifies people by login
    /// (sentinelayer-api `session_mention_notifications.py` matches `github_username`), which their server-authored
    /// id carries as `human-<login>`; a display name never notifies anyone.
    public let handle: String
    public let displayName: String
    public let isHuman: Bool
    public let isAll: Bool
    /// The last time this participant posted, for ordering agents (recent first).
    public let lastActive: Date?

    public init(handle: String, displayName: String, isHuman: Bool, isAll: Bool = false, lastActive: Date? = nil) {
        self.handle = handle
        self.displayName = displayName
        self.isHuman = isHuman
        self.isAll = isAll
        self.lastActive = lastActive
    }

    public static let everyone = MentionCandidate(handle: "all", displayName: "Everyone", isHuman: false, isAll: true)
}

/// @-mention autocomplete with the web's rules (sentinelayer-web `useMentionSuggestions.ts` at d479a03):
/// - a mention starts with `@` at the start of the text or after whitespace, and runs to the caret;
/// - humans first, then agents active in the last 10 minutes, then the rest, alphabetical in each group;
/// - your own handle is never offered; `@all` is offered for an empty query or a prefix of "all";
/// - a match is a case-insensitive substring of the handle or the display name.
/// The phone composer treats the end of the draft as the caret.
public enum MentionSuggester {
    public static let recentWindow: TimeInterval = 10 * 60
    /// Everyone who matches, in a list the composer scrolls (a room can have hundreds of agents).
    public static let maximumSuggestions = 60

    /// The query being typed at the end of `draft`, and where its `@` starts.
    public static func activeQuery(in draft: String) -> (query: String, atIndex: String.Index)? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: { $0.isWhitespace }) else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        guard query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return (String(query), at)
    }

    /// The room's mentionable participants from its authors.
    public static func candidates(
        authors: [(id: String, name: String, isHuman: Bool, lastActive: Date?)],
        ownHandles: Set<String>,
        now: Date = Date()
    ) -> [MentionCandidate] {
        var byHandle: [String: MentionCandidate] = [:]
        for author in authors {
            let handle: String
            if author.isHuman {
                let id = author.id.lowercased()
                handle = id.hasPrefix("human-")
                    ? String(id.dropFirst("human-".count))
                    : author.name.lowercased().replacingOccurrences(of: " ", with: "")
            } else {
                handle = author.id.lowercased()
            }
            guard !handle.isEmpty, !ownHandles.contains(handle), handle != "all" else { continue }
            if let existing = byHandle[handle], (existing.lastActive ?? .distantPast) >= (author.lastActive ?? .distantPast) {
                continue
            }
            byHandle[handle] = MentionCandidate(
                handle: handle,
                displayName: author.isHuman ? author.name : author.id,
                isHuman: author.isHuman,
                lastActive: author.lastActive
            )
        }
        func group(_ candidate: MentionCandidate) -> Int {
            if candidate.isHuman { return 0 }
            if let last = candidate.lastActive, now.timeIntervalSince(last) < recentWindow { return 1 }
            return 2
        }
        return byHandle.values.sorted {
            let left = group($0)
            let right = group($1)
            return left != right ? left < right : $0.handle < $1.handle
        }
    }

    public static func suggestions(for query: String, among candidates: [MentionCandidate]) -> [MentionCandidate] {
        let needle = query.lowercased()
        var matches = candidates.filter {
            needle.isEmpty || $0.handle.contains(needle) || $0.displayName.lowercased().contains(needle)
        }
        if needle.isEmpty || "all".hasPrefix(needle) { matches.insert(.everyone, at: 0) }
        return Array(matches.prefix(maximumSuggestions))
    }

    /// Replaces the typed `@query` at the end of `draft` with `@handle ` (trailing space, ready to keep typing).
    public static func apply(_ candidate: MentionCandidate, to draft: String) -> String {
        guard let active = activeQuery(in: draft) else { return draft }
        return String(draft[..<active.atIndex]) + "@" + candidate.handle + " "
    }
}

/// A decision the ticket keeper asks a person, from a ticket's `## Decision` section (web `ticketDecision.ts`):
///
///     ## Decision
///     Question: <one sentence>
///     Options: Yes · No · <option> · Custom
///
/// Options are separated by ` · ` only; "Custom", "Other", "free text" or "something else" offers a text answer, and
/// no options at all means an open question. Fenced code is never a section. The answer is ONE chat line that
/// @-mentions the ticket's current assignee.
public struct TicketDecision: Equatable, Sendable {
    public let question: String
    public let options: [String]
    public let allowsCustom: Bool

    public static let maximumOptions = 6

    public static func parse(_ body: String) -> TicketDecision? {
        var inFence: (char: Character, length: Int)?
        var inSection = false
        var sectionLines: [String] = []
        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fenceChars = trimmed.prefix { $0 == "`" || $0 == "~" }
            if let fence = inFence {
                if fenceChars.count >= fence.length, fenceChars.first == fence.char,
                   trimmed.dropFirst(fenceChars.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    inFence = nil
                }
                continue
            }
            if fenceChars.count >= 3, let first = fenceChars.first, fenceChars.allSatisfy({ $0 == first }) {
                inFence = (first, fenceChars.count)
                continue
            }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
                if inSection { break }
                inSection = heading == "decision" || heading == "decision needed"
                continue
            }
            if inSection { sectionLines.append(trimmed) }
        }
        guard inSection || !sectionLines.isEmpty else { return nil }

        var question = ""
        var options: [String] = []
        var custom = false
        var sawOptions = false
        for line in sectionLines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "question" {
                    question = value
                    continue
                }
                if key == "option" || key == "options" {
                    sawOptions = true
                    for part in value.components(separatedBy: "·") {
                        let option = part.trimmingCharacters(in: .whitespaces)
                        guard !option.isEmpty else { continue }
                        if ["custom", "other", "free text", "something else"].contains(option.lowercased()) {
                            custom = true
                        } else if !options.contains(option), options.count < maximumOptions {
                            options.append(option)
                        }
                    }
                    continue
                }
            }
            if question.isEmpty, !line.isEmpty { question = line }
        }
        question = question.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return nil }
        if !sawOptions || options.isEmpty { custom = true }
        return TicketDecision(question: question, options: options, allowsCustom: custom)
    }

    /// The chat line the web posts: `Decision on [Ticket: <title>](/dashboard/sessions/<room>?ticket=<id>): <answer>[ —
    /// <detail>]` then ` @<assignee>`, or ` (for <name>)` when the assignee is a user id, or nothing when unassigned.
    public static func chatLine(
        sessionId: String,
        ticketId: String,
        title: String,
        answer: String,
        detail: String = "",
        assignee: String?,
        personLabel: (String) -> String = { $0 }
    ) -> String {
        let card = Self.ticketCard(sessionId: sessionId, ticketId: ticketId, title: title)
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = trimmedDetail.isEmpty ? answer.trimmingCharacters(in: .whitespacesAndNewlines)
            : "\(answer.trimmingCharacters(in: .whitespacesAndNewlines)) — \(trimmedDetail)"
        let owner = assignee?.trimmingCharacters(in: .whitespaces) ?? ""
        let to: String
        if owner.isEmpty {
            to = ""
        } else if UUID(uuidString: owner) != nil {
            to = " (for \(personLabel(owner)))"
        } else {
            to = " @\(owner)"
        }
        return "Decision on \(card): \(what)\(to)"
    }

    /// The chat line the web posts after an assignment (`assignmentChatLine`), so everyone sees it and an agent
    /// assignee's listener wakes: `Assigned <card> to @<agent>`, the person's name for a user id, or `Unassigned <card>`.
    public static func assignmentLine(
        sessionId: String,
        ticketId: String,
        title: String,
        assignee: String?,
        personLabel: (String) -> String = { $0 }
    ) -> String {
        let card = Self.ticketCard(sessionId: sessionId, ticketId: ticketId, title: title)
        let who = assignee?.trimmingCharacters(in: .whitespaces) ?? ""
        if who.isEmpty { return "Unassigned \(card)" }
        return "Assigned \(card) to \(UUID(uuidString: who) != nil ? personLabel(who) : "@\(who)")"
    }

    /// `[Ticket: <title on one line, no brackets>](/dashboard/sessions/<room>?ticket=<id>)`, the web's bare card.
    static func ticketCard(sessionId: String, ticketId: String, title: String) -> String {
        let cleanTitle = title
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "[Ticket: \(cleanTitle.isEmpty ? "(untitled)" : cleanTitle)](/dashboard/sessions/\(sessionId)?ticket=\(ticketId))"
    }
}
