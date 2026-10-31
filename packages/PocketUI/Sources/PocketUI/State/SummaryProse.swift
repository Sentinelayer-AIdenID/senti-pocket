import Foundation
import PocketContracts

/// A summary as Pocket shows it: sentences, never label lines (Carter, 10-31: a summary has the "meat and bones",
/// who, what, when, why and where). Whoever wrote it reads the same way: the server in prose, an older server in five
/// labelled parts, or this phone. The paragraph comes first, then one quiet line of when, who and how it was written.
public struct SummaryReading: Equatable, Sendable {
    /// The summary in sentences: no labels, no stock phrases that say nothing, no @-mentions, no Markdown marks.
    public let prose: String
    /// When it covers, who took part and how it was written, each a short phrase; empty when none of it is known.
    public let detailParts: [String]

    /// Any summary text, read as prose (`SummaryProse.prose`), with its quiet line's parts.
    public init(_ text: String, details: [String] = []) {
        prose = SummaryProse.prose(text)
        detailParts = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The prose on one line, for a row that shows its start.
    public var oneLine: String {
        prose.replacingOccurrences(of: "\n\n", with: " ")
    }

    /// The quiet line under the paragraph: "Oct 31, 9:02 – 9:40 AM · mrrcarter, claude-warden · Basic summary".
    public var details: String? {
        detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")
    }

    /// The quiet line as VoiceOver reads it, with pauses instead of dots.
    public var spokenDetails: String? {
        detailParts.isEmpty ? nil : detailParts.joined(separator: ", ")
    }
}

/// Turns any summary into prose. An older server (and this phone, until 10-31) wrote five labelled lines, "Objective:",
/// "What changed:", "How:", "Checks:" and "Record:", padded with stock phrases when it knew nothing ("1 recorded
/// events; outcomes not verified", "Tests not verified; RLAIF not reported", "1408 tokens, $0.0000; deterministic
/// transcript summary"). Read here, the labels and the stock phrases go and what is left is joined into sentences.
/// No summary keeps an @-mention or a Markdown mark.
public enum SummaryProse {
    /// The five parts, by the label a line starts with.
    enum Part: String {
        case objective
        case changed = "what changed"
        case how
        case checks
        case record
    }

    /// Any summary text as prose: labelled parts become sentences, and prose keeps its paragraphs.
    public static func prose(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if let parts = labelledParts(lines) {
            return joined(parts.map { rewrite($0.text, as: $0.part) })
        }
        return paragraphs(lines)
    }

    /// A summary's parts as sentences, in order: each one cleaned, its stock phrases left out, a part with nothing
    /// left dropped, and each ending as a sentence ends.
    public static func sentences(_ parts: [String]) -> String {
        joined(parts.map { rewrite($0, as: nil) })
    }

    /// Text without Markdown marks or @-mentions. A link keeps its words and code keeps its letters. Mentions that
    /// open a sentence (who it was addressed to) go; a name mentioned inside one stays, without its @.
    public static func clean(_ text: String) -> String {
        var value = replace(linkExpression, in: text, with: "$1")
        for mark in ["`", "*", "~~"] { value = value.replacingOccurrences(of: mark, with: "") }
        value = replace(markerExpression, in: value, with: "")
        value = replace(carbonCopyExpression, in: value, with: "")
        value = unmentioned(unaddressed(value))
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

    /// Who took part: up to `shown` names, then how many more ("claude-warden, pocket-forge, mrrcarter and 2 more").
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

    /// How a summary was written, as its quiet line says it. The server's outline made without a model is a "Basic
    /// summary" (the web's words), one a model wrote is a "Model summary", and any other mode is named as it comes.
    public static func mode(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if ["determin", "fallback", "basic", "outline"].contains(where: { lower.contains($0) }) { return "Basic summary" }
        if ["model", "llm", "ai", "server", "generated"].contains(lower) { return "Model summary" }
        // A format is not a mode.
        if lower.hasPrefix("prose") || lower.hasPrefix("five-part") { return nil }
        let words = lower.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The quiet line's parts from the server's summary fields (`format: "prose-v2"`): its time range, participants
    /// and mode, each left out when absent. A time range is `{"start", "end"}` (or from/to, first/last,
    /// startedAt/endedAt), a pair, or one date, as ISO 8601 or epoch seconds; other text is shown as written.
    /// Participants are names, or objects with a name.
    public static func details(server fields: [String: Any], now: Date = Date(), calendar: Calendar = .current) -> [String] {
        [timeRange(fields["timeRange"], now: now, calendar: calendar),
         people(participants(fields["participants"])),
         mode(fields["mode"] as? String)].compactMap { $0 }
    }

    // MARK: - Labelled parts

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

    /// One part as sentences, or nil when nothing in it says anything. Its stock phrases go, the counts an outline
    /// gives instead of names become a sentence, and a record of ids reads "See …".
    static func rewrite(_ text: String, as part: Part?) -> String? {
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
                if clause.isEmpty || counts.take(clause) || isStock(clause) { continue }
                kept.append(kept.isEmpty ? opening(clause) : clause)
            }
            if !kept.isEmpty { units.append(kept.joined(separator: "; ") + terminal) }
        }
        if let line = counts.sentence { units.append(line) }
        guard !units.isEmpty else { return nil }
        let sentence = units.joined(separator: " ")
        return part == .record && startsWithReference(sentence) ? "See " + sentence : sentence
    }

    /// The counts an older server's outline gave instead of saying who worked ("1 participant(s), 0s. Top contributor:
    /// claude-warden"), said as one sentence.
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

    /// A phrase that says nothing: the outline's counts of events and tokens, "not verified", "not reported".
    static func isStock(_ clause: String) -> Bool {
        let value = clause.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?…"))
        guard !value.isEmpty else { return true }
        let range = NSRange(value.startIndex..., in: value)
        if stockExpressions.contains(where: { $0.firstMatch(in: value, range: range) != nil }) { return true }
        let lower = value.lowercased()
        guard lower.contains("rlaif") else { return false }
        return lower.range(of: #"\b(?:not|no|none|unreported|absent|n/a)\b"#, options: .regularExpression) != nil
    }

    static func startsWithReference(_ text: String) -> Bool {
        referenceExpression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Prose

    /// Prose as it came, paragraph by paragraph: each paragraph's lines joined, a list item or heading ending as a
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

    /// Text without the mentions that open it or a sentence in it to say who it is for: several mentions, a mention
    /// followed by a comma or colon, or one followed by a capital or a mark ("@a @b *Warden's review",
    /// "@claude-warden, please look"). One mention followed by a lowercase word is the sentence's subject
    /// ("@claude-warden fixed it") and keeps its name.
    static func unaddressed(_ text: String) -> String {
        guard text.contains("@"), let regex = addresseesExpression else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let run = Range(match.range(at: 2), in: result) else { continue }
            let mentions = result[run].filter { $0 == "@" }.count
            let punctuated = result[run].contains(where: { $0 == "," || $0 == ":" })
            let next = result[run.upperBound...].first
            if mentions > 1 || punctuated || next.map({ !$0.isLowercase }) ?? true {
                let rest = opening(String(result[run.upperBound...]))
                result.replaceSubrange(run.lowerBound..., with: rest)
            }
        }
        return result
    }

    /// Words that now open a sentence, capitalized when the first is a plain lowercase word ("the pin moved"), never
    /// when it is a handle or a name ("pocket-forge", "iOS").
    static func opening(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let word = text.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        guard !word.isEmpty,
              word.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "\u{2019}" }) else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Each @handle left inside a sentence, as its name; @all is everyone.
    static func unmentioned(_ text: String) -> String {
        guard text.contains("@"), let regex = mentionExpression else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let handle = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[handle])
            result.replaceSubrange(whole, with: name.lowercased() == "all" ? "everyone" : displayName(name))
        }
        return result
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
            let shown = prose(text)
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
    /// A heading, quote, bullet or number opening a line.
    private static let markerExpression = expression(#"^\s*(?:#{1,6}\s+|>\s*|[-*•+]\s+|\d{1,3}[.)]\s+)"#)
    /// Mentions opening the text or a sentence (group 2), which may say who it was addressed to.
    private static let addresseesExpression = expression(#"(^|[.!?;]\s+)((?:@[A-Za-z0-9_-]+[,:]?(?:\s+|$))+)"#)
    /// "cc @a @b" closing the text.
    private static let carbonCopyExpression = expression(#"[\s,;]*\bcc\b:?\s*(?:@[A-Za-z0-9_-]+[,]?\s*)+$"#)
    private static let mentionExpression = expression(#"(?<![\w@.])@([A-Za-z0-9_-]+)"#, [])
    private static let sentenceBreakExpression = expression(#"(?<=[.!?…])\s+"#, [])
    fileprivate static let participantsExpression = expression(
        #"^(\d+)\s+participants?(?:\s*\(s\))?(?:\s*,\s*(\d+)\s*s(?:econds?)?)?$"#
    )
    fileprivate static let topExpression = expression(#"^top\s+contributor\s*:?\s*(.+)$"#)
    private static let referenceExpression = expression(
        #"^(?:#\d|(?:prs?|pull\s+requests?|commits?|builds?|issues?|tickets?|releases?|tags?)\b|[0-9a-f]{7,40}\b|https?://|v?\d)"#
    )
    private static let stockExpressions: [NSRegularExpression] = [
        #"^\d[\d,]*\s+recorded\s+events?$"#,
        #"^outcomes?\s+(?:(?:were|was|are|is)\s+)?not\s+verified$"#,
        #"^tests?\s+(?:(?:were|was|are|is)\s+)?not\s+verified$"#,
        #"^deterministic\s+transcript\s+summary$"#,
        #"^\d[\d,]*\s+tokens?(?:\s*,\s*\$\s*\d[\d,]*(?:\.\d+)?)?$"#,
        #"^\$\s*\d[\d,]*(?:\.\d+)?$"#,
        #"^(?:none|nothing|n/?a)(?:\s+(?:mentioned|reported|recorded|noted|given|found))?$"#,
        #"^not\s+(?:reported|mentioned|recorded|verified|available)$"#,
        #"^no\s+objective\s+(?:reported|recorded|given|stated)$"#,
        #"^no\s+(?:checks?|tests?|commits?|prs?|pull\s+requests?|builds?|artifacts?|evidence|records?|hashes|links|references)(?:\s*(?:,|or|and)\s*(?:checks?|tests?|commits?|prs?|pull\s+requests?|builds?|artifacts?|evidence|records?|hashes|links|references))*\s+(?:(?:were|was)\s+)?(?:reported|mentioned|recorded|referenced|named|given|found|noted)$"#
    ].compactMap { expression($0) }
}
