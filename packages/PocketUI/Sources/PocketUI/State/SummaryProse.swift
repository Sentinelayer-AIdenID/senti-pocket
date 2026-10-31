import Foundation
import PocketContracts

/// A summary as Pocket shows it: a paragraph of prose, then one quiet line of when, who and how it was written. The
/// server's prose (`format: "prose-v2"`) and this phone's own summaries are shown exactly as written; only an older
/// server's summary, which has no format, is read into sentences here (`SummaryProse.legacy`).
public struct SummaryReading: Equatable, Sendable {
    /// The summary's paragraph (or paragraphs).
    public let prose: String
    /// When it covers, who took part and how it was written, each a short phrase; empty when none of it is known.
    public let detailParts: [String]

    /// Text that is prose already, shown as written: only the whitespace around it is trimmed, so "2*3" stays "2*3".
    public init(prose text: String, details: [String] = []) {
        self.init(shown: text.trimmingCharacters(in: .whitespacesAndNewlines), details: details)
    }

    /// An older server's summary (no `format`), read into sentences by `SummaryProse.legacy`.
    public init(legacy text: String, details: [String] = []) {
        self.init(shown: SummaryProse.legacy(text), details: details)
    }

    /// The server's summary text with its `format`: as written when it has one, an older server's when it has none.
    public init(server text: String, format: String?, details: [String] = []) {
        self.init(shown: SummaryProse.server(text, format: format), details: details)
    }

    private init(shown prose: String, details: [String]) {
        self.prose = prose
        detailParts = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The prose on one line, for a row that shows its start.
    public var oneLine: String {
        prose.replacingOccurrences(of: "\n\n", with: " ")
    }

    /// The quiet line under the paragraph: "Oct 31, 9:02 – 9:40 AM · ada-agent and lin-agent · Basic summary".
    public var details: String? {
        detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
    }

    /// The quiet line as VoiceOver reads it, with pauses instead of dots.
    public var spokenDetails: String? {
        detailParts.isEmpty ? nil : detailParts.joined(separator: ", ")
    }
}

/// How Pocket reads a summary's text. The server's prose (`format: "prose-v2"`) is the server's to write and is never
/// parsed or changed here. An older server sent no format and wrote five labelled lines, "Objective:", "What changed:",
/// "How:", "Checks:" and "Record:", padded with its own stock phrases when it knew nothing ("outcomes not verified",
/// "RLAIF not reported", its usage record, "deterministic transcript summary"). Read here, its labels and those exact
/// phrases go, what is left is joined into sentences, and each @-mention becomes the name it stands for.
public enum SummaryProse {
    /// The five parts, by the label a line starts with.
    enum Part: String {
        case objective
        case changed = "what changed"
        case how
        case checks
        case record
    }

    /// Where a part being read into sentences comes from.
    enum Source: Equatable {
        /// An older server's labelled line.
        case legacy(Part)
        /// This phone's own model.
        case phone
    }

    /// The server's summary text as Pocket shows it. A summary that names its format (`"prose-v2"`) is the server's
    /// prose, which clients do not parse: only the whitespace around it is trimmed. One without a format comes from
    /// an older server and is read by `legacy`.
    public static func server(_ text: String, format: String?) -> String {
        isLegacy(format: format) ? legacy(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a summary comes from an older server: it names no format.
    public static func isLegacy(format: String?) -> Bool {
        format?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    /// A room's saved summary, which the room list carries without its format. An older server's five labelled lines
    /// are read by `legacy`; anything else is the server's prose, shown as written. The server's prose never opens
    /// with one of the labels: it refuses a summary that does.
    public static func saved(_ text: String) -> String {
        labelledParts(splitLines(text)) == nil ? text.trimmingCharacters(in: .whitespacesAndNewlines) : legacy(text)
    }

    /// An older server's summary as prose: labelled parts become sentences, and other text keeps its paragraphs.
    public static func legacy(_ text: String) -> String {
        let lines = splitLines(text)
        if let parts = labelledParts(lines) {
            return joined(parts.map { rewrite($0.text, from: .legacy($0.part)) })
        }
        return paragraphs(lines)
    }

    /// This phone's own summary parts as sentences, in order. A part that is only the placeholder the phone's model
    /// writes when the thread names nothing ("None mentioned") is left out; everything else is kept as it says it.
    public static func sentences(_ parts: [String]) -> String {
        joined(parts.map { rewrite($0, from: .phone) })
    }

    /// Text without Markdown marks, each @-mention as the name it stands for. A link keeps its words, code keeps its
    /// letters, and a star between two letters or digits stays ("2*3"): only emphasis and stray stars go.
    public static func clean(_ text: String) -> String {
        var value = replace(linkExpression, in: text, with: "$1")
        for mark in ["`", "~~"] { value = value.replacingOccurrences(of: mark, with: "") }
        value = replace(starExpression, in: value, with: "")
        value = replace(markerExpression, in: value, with: "")
        value = named(value)
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A handle as a person reads it: no @, and a person's handle without its "human-".
    public static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        if name.lowercased().hasPrefix("human-") { name = String(name.dropFirst("human-".count)) }
        return name
    }

    /// "a", "a and b", "a, b and c".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - The quiet line

    /// When a summary covers, in the reader's words: "Oct 31, 9:02 – 9:40 AM", one time when it is one moment, and the
    /// year only when it isn't this year.
    public static func when(from start: Date?, to end: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let dates = [start, end].compactMap { $0 }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let template = calendar.isDate(first, equalTo: now, toGranularity: .year) ? "MMMdjmm" : "yMMMdjmm"
        if last.timeIntervalSince(first) < 60 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale ?? .current
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: first)
        }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = template
        return formatter.string(from: first, to: last)
    }

    /// Who took part: up to `shown` names, then how many more ("ada-agent, lin-agent, sam and 2 more").
    public static func people(_ names: [String], shown: Int = 3) -> String? {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in names {
            let name = displayName(raw)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            unique.append(name)
        }
        guard !unique.isEmpty else { return nil }
        guard unique.count > shown else { return list(unique) }
        return unique.prefix(shown).joined(separator: ", ") + " and \(unique.count - shown) more"
    }

    /// How a summary was written, as its quiet line says it, in the API's words: "AI summary" for one a model wrote
    /// (`mode: "llm"`), "Basic summary" for one composed from the text without a model, any other mode as it comes.
    public static func mode(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if ["determin", "fallback", "basic", "outline"].contains(where: { lower.contains($0) }) { return "Basic summary" }
        if ["model", "llm", "ai", "server", "generated"].contains(lower) { return "AI summary" }
        // A format is not a mode.
        if lower.hasPrefix("prose") || lower.hasPrefix("five-part") { return nil }
        let words = lower.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Why a basic summary was written without AI, in plain words, from the server's `fallbackReason`; nil when it
    /// gives none. The server's own reason is never shown as it is.
    public static func fallbackNote(_ reason: String?) -> String? {
        guard let value = reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        switch value {
        case "provider disabled":
            return "AI summaries are turned off on the server, so this one was written without AI."
        case "provider unavailable":
            return "The AI summary service isn't available right now, so this one was written without AI."
        case "reader cannot generate":
            return "This one was written without AI. An AI summary takes its place when someone who can post here "
                + "opens it."
        case "budget exhausted":
            return "Today's AI summaries are used up, so this one was written without AI. Try again tomorrow."
        default:
            if value.hasPrefix("invalid") || value.contains("attempt") {
                return "The AI summary didn't work this time, so this one was written without AI. It can be tried "
                    + "again tomorrow."
            }
            return "This one was written without AI."
        }
    }

    /// The quiet line's parts from the server's summary fields: its time range, participants and mode, each left out
    /// when absent. A time range is `{"start", "end"}` (or from/to, first/last, startedAt/endedAt), a pair, or one
    /// date, as ISO 8601 or epoch seconds; other text is shown as written. Participants are names, or objects with a
    /// name.
    public static func details(server fields: [String: Any], now: Date = Date(), calendar: Calendar = .current) -> [String] {
        [timeRange(fields["timeRange"], now: now, calendar: calendar),
         people(participants(fields["participants"])),
         mode(fields["mode"] as? String)].compactMap { $0 }
    }

    // MARK: - An older server's labelled parts

    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The labelled parts, when the text is a five-part summary: its first line carries one of the labels. A line
    /// without a label continues the part above it.
    static func labelledParts(_ lines: [String]) -> [(part: Part, text: String)]? {
        var parts: [(part: Part, text: String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let found = labelled(trimmed) {
                parts.append((part: found.0, text: found.1))
            } else if parts.isEmpty {
                return nil
            } else {
                parts[parts.count - 1].text += " " + replace(markerExpression, in: trimmed, with: "")
            }
        }
        return parts.isEmpty ? nil : parts
    }

    /// A line's label and the rest of it, for "Objective: …", "**What changed:** …", "**How**: …" or "- Checks: …".
    static func labelled(_ line: String) -> (Part, String)? {
        guard let match = labelExpression?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let labelRange = Range(match.range(at: 1), in: line),
              let restRange = Range(match.range(at: 2), in: line) else { return nil }
        let label = line[labelRange].lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let part = Part(rawValue: label) else { return nil }
        return (part, String(line[restRange]))
    }

    /// One part as sentences, or nil when nothing in it says anything. Only boilerplate goes (`isBoilerplate`); an
    /// older server's counts become a sentence, and its record of ids reads "See …".
    static func rewrite(_ text: String, from source: Source) -> String? {
        var counts = Counts()
        var units: [String] = []
        for unit in sentenceUnits(clean(text)) {
            var body = unit
            var terminal = "."
            if let last = body.last, ".!?…".contains(last) {
                terminal = String(last)
                body.removeLast()
            }
            var kept: [String] = []
            for piece in body.split(separator: ";") {
                let clause = piece.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
                if clause.isEmpty || isBoilerplate(clause, from: source) { continue }
                if case .legacy = source, counts.take(clause) { continue }
                kept.append(kept.isEmpty ? opening(clause) : clause)
            }
            if !kept.isEmpty { units.append(kept.joined(separator: "; ") + terminal) }
        }
        if let line = counts.sentence { units.append(line) }
        guard !units.isEmpty else { return nil }
        let sentence = units.joined(separator: " ")
        return source == .legacy(.record) && startsWithReference(sentence) ? "See " + sentence : sentence
    }

    /// The counts an older server's outline gave instead of saying who worked ("1 participant(s), 0s. Top
    /// contributor: lin-agent"), said as one sentence.
    struct Counts {
        var participants: Int?
        var seconds: Int?
        var top: String?
        var found = false

        /// Takes a clause that is one of the counts; false for anything else.
        mutating func take(_ clause: String) -> Bool {
            let range = NSRange(clause.startIndex..., in: clause)
            if let match = SummaryProse.participantsExpression?.firstMatch(in: clause, range: range) {
                participants = Range(match.range(at: 1), in: clause).flatMap { Int(clause[$0]) }
                seconds = Range(match.range(at: 2), in: clause).flatMap { Int(clause[$0]) }
                found = true
                return true
            }
            if let match = SummaryProse.topExpression?.firstMatch(in: clause, range: range),
               let nameRange = Range(match.range(at: 1), in: clause) {
                let name = SummaryProse.displayName(String(clause[nameRange]))
                top = ["", "n/a", "na", "none", "unknown"].contains(name.lowercased()) ? nil : name
                found = true
                return true
            }
            return false
        }

        var sentence: String? {
            guard found else { return nil }
            let over = seconds.flatMap(SummaryProse.duration).map { " over \($0)" } ?? ""
            switch (participants, top) {
            case (1?, let top?):
                return "Only \(top) took part\(over)."
            case (let count?, let top?) where count > 1:
                return "\(count) participants took part\(over); \(top) contributed most."
            case (let count?, nil) where count > 1:
                return "\(count) participants took part\(over)."
            case (nil, let top?):
                return "\(top) contributed most."
            default:
                return nil
            }
        }
    }

    /// A length of time worth saying: a minute or more.
    static func duration(_ seconds: Int) -> String? {
        guard seconds >= 60 else { return nil }
        if seconds < 3600 {
            let minutes = (seconds + 30) / 60
            return minutes == 1 ? "a minute" : "\(minutes) minutes"
        }
        let hours = Int((Double(seconds) / 3600).rounded())
        return hours == 1 ? "an hour" : "\(hours) hours"
    }

    /// A clause that says nothing, exactly as its writer puts it when it knows nothing: the placeholder this phone's
    /// model is told to write for a part the thread doesn't mention ("None mentioned"), and an older server's own
    /// stock phrases ("Tests not verified", "RLAIF not reported", "3 recorded events", its usage record,
    /// "deterministic transcript summary"). A clause with anything more in it is kept, whoever wrote it: "Tests were
    /// not verified." and "No tests found." say something.
    static func isBoilerplate(_ clause: String, from source: Source) -> Bool {
        let key = clause.lowercased()
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;!?…"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if key.isEmpty || placeholders.contains(key) { return true }
        guard case .legacy = source else { return false }
        if legacyStockPhrases.contains(key) { return true }
        let range = NSRange(key.startIndex..., in: key)
        return legacyStockExpressions.contains { $0.firstMatch(in: key, range: range) != nil }
    }

    /// What a summary writer puts in a part it has nothing for.
    static let placeholders: Set<String> = ["none mentioned", "none", "n/a"]
    /// An older server's stock phrases, as it wrote them.
    static let legacyStockPhrases: Set<String> = [
        "no objective reported", "outcomes not verified", "tests not verified", "rlaif not reported",
        "not reported", "deterministic transcript summary"
    ]

    static func startsWithReference(_ text: String) -> Bool {
        referenceExpression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - An older server's other text

    /// Text as it came, paragraph by paragraph: each paragraph's lines joined, a list item or heading ending as a
    /// sentence ends, and every line cleaned.
    static func paragraphs(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var units: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !units.isEmpty { paragraphs.append(units.joined(separator: " ")) }
                units = []
                continue
            }
            let isItem = markerExpression?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
            let cleaned = clean(trimmed)
            guard !cleaned.isEmpty else { continue }
            units.append(isItem ? ended(cleaned) : cleaned)
        }
        if !units.isEmpty { paragraphs.append(units.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Text ending as a sentence ends: a closing period unless it already ends with one (or ! ? …), quotes allowed.
    static func ended(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        while let last = value.last, ",:;".contains(last) { value.removeLast() }
        guard !value.isEmpty else { return value }
        let closing: Set<Character> = [")", "]", "\"", "'", "\u{201D}", "\u{2019}", "\u{BB}"]
        var index = value.endIndex
        while index > value.startIndex, closing.contains(value[value.index(before: index)]) {
            index = value.index(before: index)
        }
        if index > value.startIndex, ".!?…".contains(value[value.index(before: index)]) { return value }
        return value + "."
    }

    /// Sentences one after another, each said once.
    static func joined(_ sentences: [String?]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for case let sentence? in sentences {
            let key = sentence.lowercased().filter { $0.isLetter || $0.isNumber }
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            kept.append(sentence)
        }
        return kept.joined(separator: " ")
    }

    /// Text cut where a sentence ends.
    static func sentenceUnits(_ text: String) -> [String] {
        guard let regex = sentenceBreakExpression else { return [text] }
        var units: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            units.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        units.append(String(text[start...]))
        return units.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Each @-mention as the name it stands for, so no name is lost: "@a @b approved the fix." reads "a and b approved
    /// the fix.", and @all is everyone. Mentions that open a sentence before another one starts, which say who it was
    /// for ("@a @b The build is green."), keep their names before a colon: "a and b: The build is green."
    static func named(_ text: String) -> String {
        guard text.contains("@"), let regex = mentionRunExpression else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let run = Range(match.range, in: result) else { continue }
            let names = result[run].split(whereSeparator: \.isWhitespace).map { handle -> String in
                let name = displayName(String(handle))
                return name.lowercased() == "all" ? "everyone" : name
            }
            let before = result[..<run.lowerBound]
            let opensSentence = before.trimmingCharacters(in: .whitespaces).isEmpty
                || before.range(of: #"[.!?;]\s+$"#, options: .regularExpression) != nil
            let next = result[run.upperBound...].first { !$0.isWhitespace }
            let addressed = opensSentence && next.map { !$0.isLowercase && !",:;.!?".contains($0) } == true
            result.replaceSubrange(run, with: list(names) + (addressed ? ":" : ""))
        }
        return result
    }

    /// Words that now open a sentence, capitalized when the first is a plain lowercase word ("the pin moved"), never
    /// when it is a handle or a name ("ada-agent", "iOS").
    static func opening(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let word = text.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        guard !word.isEmpty,
              word.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "\u{2019}" }) else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func replace(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: - Server fields

    static func timeRange(_ value: Any?, now: Date, calendar: Calendar) -> String? {
        guard let value else { return nil }
        switch value {
        case let range as [String: Any]:
            let start = ["start", "from", "first", "startedAt", "startAt", "begin", "since"].lazy.compactMap { date(range[$0]) }.first
            let end = ["end", "to", "last", "endedAt", "endAt", "until"].lazy.compactMap { date(range[$0]) }.first
            return when(from: start, to: end, now: now, calendar: calendar)
        case let pair as [Any]:
            let dates = pair.compactMap { date($0) }
            return when(from: dates.min(), to: dates.max(), now: now, calendar: calendar)
        case let text as String:
            if let moment = date(text) { return when(from: moment, to: moment, now: now, calendar: calendar) }
            let ends = text.components(separatedBy: "/")
            if ends.count == 2, let start = date(ends[0]), let end = date(ends[1]) {
                return when(from: start, to: end, now: now, calendar: calendar)
            }
            // The server's own words, as written.
            let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return shown.isEmpty ? nil : shown
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let text as String:
            return ParsedSessionTimestamp(text.trimmingCharacters(in: .whitespaces)).date
        case let number as NSNumber:
            let seconds = number.doubleValue > 100_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        default:
            return nil
        }
    }

    static func participants(_ value: Any?) -> [String] {
        let items: [Any]
        if let list = value as? [Any] {
            items = list
        } else if let text = value as? String {
            items = text.components(separatedBy: ",")
        } else {
            return []
        }
        return items.compactMap { item -> String? in
            if let name = item as? String { return name }
            guard let person = item as? [String: Any] else { return nil }
            return ["displayName", "name", "handle", "login", "agentId", "id"].lazy.compactMap { person[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: - Expressions, compiled once

    private static func expression(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static let labelExpression = expression(
        #"^(?:[-*•]\s+)?(?:\*\*|__)?\s*(objective|what\s+changed|how|checks|record)\s*(?:\*\*|__)?\s*:\s*(?:\*\*|__)?\s*(.*)$"#
    )
    private static let linkExpression = expression(#"!?\[([^\]]*)\]\([^)]*\)"#)
    /// Stars that are not between two letters or digits: emphasis, or a stray mark ("2*3" keeps its star).
    private static let starExpression = expression(#"(?<![\p{L}\p{N}])\*+|\*+(?![\p{L}\p{N}])"#, [])
    /// A heading, quote, bullet or number opening a line.
    private static let markerExpression = expression(#"^\s*(?:#{1,6}\s+|>\s*|[-*•+]\s+|\d{1,3}[.)]\s+)"#)
    /// @-mentions one after another, with only spaces between them; an email address's @ is not one.
    private static let mentionRunExpression = expression(
        #"(?<![\w@.])@[A-Za-z0-9_-]+(?:[ \t]+@[A-Za-z0-9_-]+)*"#, []
    )
    private static let sentenceBreakExpression = expression(#"(?<=[.!?…])\s+"#, [])
    fileprivate static let participantsExpression = expression(
        #"^(\d+)\s+participants?(?:\s*\(s\))?(?:\s*,\s*(\d+)\s*s(?:econds?)?)?$"#
    )
    fileprivate static let topExpression = expression(#"^top\s+contributor\s*:?\s*(.+)$"#)
    private static let referenceExpression = expression(
        #"^(?:#\d|(?:prs?|pull\s+requests?|commits?|builds?|issues?|tickets?|releases?|tags?)\b|[0-9a-f]{7,40}\b|https?://|v?\d)"#
    )
    /// An older server's stock phrases with a number in them: its count of events, and its usage record.
    private static let legacyStockExpressions: [NSRegularExpression] = [
        #"^\d[\d,]*\s+recorded\s+events?$"#,
        #"^\d[\d,]*\s+tokens?(?:\s*,\s*\$\s*\d[\d,]*(?:\.\d+)?)?$"#
    ].compactMap { expression($0) }
}
