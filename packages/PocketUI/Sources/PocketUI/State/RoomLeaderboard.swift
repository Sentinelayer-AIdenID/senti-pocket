import Foundation

/// The room's leaderboard, read from its pinned 🏆 message (edited in place as the standings change) into a ranked
/// list. The board is a fixed format: a title line, one line per ranked author, then a paragraph on how it works. Only
/// lines in the exact row shape become rows; any other line is never shown in the list.
public struct RoomLeaderboard: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        /// Since the board's previous update.
        public enum Move: Equatable, Sendable {
            case new
            case up(Int)
            case down(Int)
        }

        /// An author is on the board once: their id keeps a row's identity as it moves.
        public var id: String { name }
        public let rank: Int
        public let name: String
        /// A person taking part (their id on the board without "human-"), not an agent.
        public let isPerson: Bool
        /// One of the host team's own agents.
        public let isTeam: Bool
        /// The score as the board writes it, with one decimal place.
        public let points: String
        public let helpful: Int
        public let move: Move?

        /// 🥇, 🥈 or 🥉 for the first three; "4." and on after them.
        public var rankText: String {
            switch rank {
            case 1: return "🥇"
            case 2: return "🥈"
            case 3: return "🥉"
            default: return "\(rank)."
            }
        }

        /// "person", "SentiLab team", or nil for another agent.
        public var chip: String? {
            switch (isPerson, isTeam) {
            case (true, true): return "person · SentiLab team"
            case (true, false): return "person"
            case (false, true): return "SentiLab team"
            case (false, false): return nil
            }
        }

        public var pointsText: String { "\(points) pts" }
        public var helpfulText: String { "\(helpful) helpful" }

        /// The movement badge: 🆕, ▲2 or ▼1.
        public var moveText: String? {
            switch move {
            case .new: return "🆕"
            case .up(let places): return "▲\(places)"
            case .down(let places): return "▼\(places)"
            case nil: return nil
            }
        }

        /// What VoiceOver reads: "Rank 4, box-host, SentiLab team, 34.9 points, 14 helpful", then the move if any.
        public var accessibilityLabel: String {
            var parts = ["Rank \(rank)", name]
            if isPerson { parts.append("person") }
            if isTeam { parts.append("SentiLab team") }
            parts += ["\(points) points", helpfulText]
            switch move {
            case .new: parts.append("new on the board")
            case .up(let places): parts.append("up \(places)")
            case .down(let places): parts.append("down \(places)")
            case nil: break
            }
            return parts.joined(separator: ", ")
        }
    }

    public let rows: [Row]
    /// "HH:MM", UTC, when the board says it last changed.
    public let updatedAt: String?
    /// The board's own words on how it works: plain text, shown collapsed under the list.
    public let howItWorks: String?

    /// "Who's helping most · Updated 00:46 UTC" (or "just now" when the board doesn't say).
    public var header: String { "Who's helping most · Updated \(updatedAt.map { "\($0) UTC" } ?? "just now")" }

    public init(rows: [Row], updatedAt: String?, howItWorks: String?) {
        self.rows = rows
        self.updatedAt = updatedAt
        self.howItWorks = howItWorks
    }

    /// The board in a pinned message's text, or nil when not one row parses (the room then says the board is
    /// unavailable and offers the message itself). Lines may end in CRLF.
    public static func parse(_ text: String) -> RoomLeaderboard? {
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(String.UnicodeScalarView(line.last == "\r" ? line.dropLast() : line[...]))
        }
        var rows: [Row] = []
        var lastRow = -1
        for (index, line) in lines.enumerated() {
            guard let row = Self.row(line), !rows.contains(where: { $0.name == row.name }) else { continue }
            rows.append(row)
            lastRow = index
        }
        guard !rows.isEmpty else { return nil }
        let paragraph = lines[(lastRow + 1)...]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Self.row($0) == nil }
            .joined(separator: "\n")
        return RoomLeaderboard(rows: rows, updatedAt: Self.firstMatch(of: updatedPattern, in: text),
                               howItWorks: paragraph.isEmpty ? nil : paragraph)
    }

    // The format's row pattern, with ASCII digits only (ICU's \d would take any script's digits).
    private static let rowPattern = try? NSRegularExpression(
        pattern: #"^(🥇|🥈|🥉|([0-9]{1,3})\.) \*\*([a-z0-9._-]{1,40})\*\*( \(person\))?( · SentiLab team)?"#
            + #" · ([0-9]{1,6}\.[0-9]) pts · ([0-9]{1,6}) helpful(?: (🆕|▲[0-9]{1,3}|▼[0-9]{1,3}))?$"#
    )
    private static let updatedPattern = try? NSRegularExpression(pattern: #"last ([0-9]{2}:[0-9]{2}) UTC"#)

    static func row(_ line: String) -> Row? {
        let range = NSRange(line.startIndex..., in: line)
        guard let rowPattern, let match = rowPattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ number: Int) -> String? {
            Range(match.range(at: number), in: line).map { String(line[$0]) }
        }
        guard let mark = group(1), let name = group(3), let points = group(6),
              let helpful = group(7).flatMap({ Int($0) }) else { return nil }
        let rank: Int
        switch mark {
        case "🥇": rank = 1
        case "🥈": rank = 2
        case "🥉": rank = 3
        default:
            guard let number = group(2).flatMap({ Int($0) }) else { return nil }
            rank = number
        }
        var move: Row.Move?
        if let badge = group(8) {
            if badge == "🆕" {
                move = .new
            } else if let places = Int(String(String.UnicodeScalarView(badge.unicodeScalars.dropFirst()))) {
                move = badge.unicodeScalars.first == "▲" ? .up(places) : .down(places)
            }
        }
        return Row(rank: rank, name: name, isPerson: group(4) != nil, isTeam: group(5) != nil, points: points,
                   helpful: helpful, move: move)
    }

    private static func firstMatch(of pattern: NSRegularExpression?, in text: String) -> String? {
        guard let pattern,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
