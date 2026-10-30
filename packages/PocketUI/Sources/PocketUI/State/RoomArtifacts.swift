import Foundation

/// A message as the artifacts panel reads it.
public struct RoomArtifactSource: Equatable, Sendable {
    public let id: String
    public let sequenceId: Int64
    public let author: String
    public let text: String
    public let date: Date?
    /// Files on the message: id and name.
    public let files: [(id: String, name: String)]
    /// A checkpoint (its text is the title).
    public let isCheckpoint: Bool

    public init(id: String, sequenceId: Int64, author: String, text: String, date: Date?,
                files: [(id: String, name: String)] = [], isCheckpoint: Bool = false) {
        self.id = id
        self.sequenceId = sequenceId
        self.author = author
        self.text = text
        self.date = date
        self.files = files
        self.isCheckpoint = isCheckpoint
    }

    public static func == (lhs: RoomArtifactSource, rhs: RoomArtifactSource) -> Bool {
        lhs.id == rhs.id && lhs.sequenceId == rhs.sequenceId && lhs.author == rhs.author && lhs.text == rhs.text
            && lhs.date == rhs.date && lhs.files.map(\.id) == rhs.files.map(\.id) && lhs.files.map(\.name) == rhs.files.map(\.name)
            && lhs.isCheckpoint == rhs.isCheckpoint
    }
}

/// One thing the room produced or pointed at, like the Claude app's artifacts: a pull request, a ticket, a file, a
/// link or a code block, each tied back to the message it came from (the newest mention).
public struct RoomArtifact: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case checkpoint, pullRequest, ticket, file, link, code

        public var title: String {
            switch self {
            case .checkpoint: return "Checkpoints"
            case .pullRequest: return "Pull requests"
            case .ticket: return "Tickets"
            case .file: return "Files"
            case .link: return "Links"
            case .code: return "Code"
            }
        }

        public var symbol: String {
            switch self {
            case .checkpoint: return "flag.checkered"
            case .pullRequest: return "arrow.triangle.pull"
            case .ticket: return "ticket"
            case .file: return "doc"
            case .link: return "link"
            case .code: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    /// Where it opens: the PR, the ticket (in the app), the link; nil for code and files.
    public let url: URL?
    /// The newest message that mentions it, and who wrote that.
    public let sequenceId: Int64
    public let author: String
    public let date: Date?
    /// How many messages mention it.
    public let mentions: Int

    public init(id: String, kind: Kind, title: String, detail: String?, url: URL?, sequenceId: Int64, author: String,
                date: Date?, mentions: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
        self.sequenceId = sequenceId
        self.author = author
        self.date = date
        self.mentions = mentions
    }
}

public enum RoomArtifacts {
    /// Every artifact in `messages`, newest mention first, one entry per thing (a PR mentioned ten times is one entry).
    public static func extract(from messages: [RoomArtifactSource]) -> [RoomArtifact] {
        var found: [String: RoomArtifact] = [:]
        func note(_ key: String, _ make: (Int) -> RoomArtifact, at message: RoomArtifactSource) {
            if let existing = found[key] {
                let newer = (message.date ?? .distantPast) >= (existing.date ?? .distantPast)
                let updated = make(existing.mentions + 1)
                found[key] = newer ? updated : RoomArtifact(
                    id: existing.id, kind: existing.kind, title: existing.title, detail: existing.detail, url: existing.url,
                    sequenceId: existing.sequenceId, author: existing.author, date: existing.date, mentions: existing.mentions + 1
                )
            } else {
                found[key] = make(1)
            }
        }
        for message in messages {
            if message.isCheckpoint {
                let key = "checkpoint:\(message.id)"
                note(key, { count in
                    RoomArtifact(id: key, kind: .checkpoint, title: message.text, detail: nil, url: nil,
                                 sequenceId: message.sequenceId, author: message.author, date: message.date, mentions: count)
                }, at: message)
                continue
            }
            // Tickets (the keeper's links), then the rest of the text's links.
            let split = ChatReferences.ticketLinks(in: message.text)
            for ticket in split.tickets {
                note("ticket:\(ticket.ticketId)", { count in
                    RoomArtifact(id: "ticket:\(ticket.ticketId)", kind: .ticket, title: ticket.title, detail: nil, url: ticket.url,
                                 sequenceId: message.sequenceId, author: message.author, date: message.date, mentions: count)
                }, at: message)
            }
            for (label, url) in links(in: message.text) {
                if let pr = ChatReferences.pullRequest(url) {
                    let key = "pr:\(pr.owner.lowercased())/\(pr.repo.lowercased())#\(pr.number)"
                    note(key, { count in
                        RoomArtifact(id: key, kind: .pullRequest, title: label.flatMap { $0 == url.absoluteString ? nil : $0 } ?? pr.label,
                                     detail: pr.label, url: url, sequenceId: message.sequenceId, author: message.author,
                                     date: message.date, mentions: count)
                    }, at: message)
                } else if !(url.host?.lowercased().hasSuffix("sentinelayer.com") == true && url.query?.contains("ticket=") == true) {
                    // (A Senti ticket link is a ticket, above, not a link.)
                    let key = "link:\(url.absoluteString)"
                    note(key, { count in
                        RoomArtifact(id: key, kind: .link, title: label ?? url.host ?? url.absoluteString,
                                     detail: url.host, url: url, sequenceId: message.sequenceId, author: message.author,
                                     date: message.date, mentions: count)
                    }, at: message)
                }
            }
            for file in message.files {
                let key = "file:\(file.id)"
                note(key, { count in
                    RoomArtifact(id: key, kind: .file, title: file.name, detail: nil, url: nil, sequenceId: message.sequenceId,
                                 author: message.author, date: message.date, mentions: count)
                }, at: message)
            }
            if let code = firstCodeLine(in: message.text) {
                let key = "code:\(message.id)"
                note(key, { count in
                    RoomArtifact(id: key, kind: .code, title: code.firstLine, detail: code.language, url: nil,
                                 sequenceId: message.sequenceId, author: message.author, date: message.date, mentions: count)
                }, at: message)
            }
        }
        return found.values.sorted {
            ($0.date ?? .distantPast, $0.sequenceId, $0.id) > ($1.date ?? .distantPast, $1.sequenceId, $1.id)
        }
    }

    /// Markdown links `[label](url)` and bare http(s) URLs, in order; only http(s) with a host.
    static func links(in text: String) -> [(label: String?, url: URL)] {
        var result: [(String?, URL)] = []
        var seen = Set<String>()
        let markdown = try? NSRegularExpression(pattern: #"\[([^\]\n]{1,300})\]\((https?://[^)\s]+)\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var covered: [NSRange] = []
        for match in markdown?.matches(in: text, range: range) ?? [] {
            guard let labelRange = Range(match.range(at: 1), in: text), let urlRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: String(text[urlRange])), url.host != nil else { continue }
            covered.append(match.range)
            if seen.insert(url.absoluteString).inserted { result.append((String(text[labelRange]), url)) }
        }
        let bare = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#)
        for match in bare?.matches(in: text, range: range) ?? [] where !covered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            guard let urlRange = Range(match.range, in: text) else { continue }
            let raw = String(text[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard let url = URL(string: raw), url.host != nil else { continue }
            if seen.insert(url.absoluteString).inserted { result.append((nil, url)) }
        }
        return result
    }

    /// The first line of a message's first fenced code block, and its language when one is named.
    static func firstCodeLine(in text: String) -> (firstLine: String, language: String?)? {
        guard let fence = text.range(of: "```") else { return nil }
        let after = text[fence.upperBound...]
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }
        let language = lines[0].trimmingCharacters(in: .whitespaces)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return nil }
            if !trimmed.isEmpty {
                let short = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
                return (short, language.isEmpty ? nil : language)
            }
        }
        return nil
    }
}
