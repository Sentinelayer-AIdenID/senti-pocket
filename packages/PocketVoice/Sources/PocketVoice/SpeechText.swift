import Foundation

/// A chat message made ready for a voice, like the web's Listen (sentinelayer-web `useSpeech` `toSpeechText` and
/// `buildQueue`): Markdown becomes plain speech, then paced segments with a pause after each, so it sounds like
/// someone reading instead of one flat run.
public enum SpeechText {
    /// One piece to say, then the silence after it.
    public struct Segment: Equatable, Sendable {
        public let text: String
        /// Seconds of silence after this segment: longest after a paragraph, shorter after a sentence, a breath
        /// where a long sentence was split, none after the last.
        public let pauseAfter: TimeInterval

        public init(text: String, pauseAfter: TimeInterval) {
            self.text = text
            self.pauseAfter = pauseAfter
        }
    }

    static let paragraphPause: TimeInterval = 0.430
    static let sentencePause: TimeInterval = 0.220
    static let clausePause: TimeInterval = 0.120
    /// Some voices stumble over very long utterances.
    static let maxSegmentLength = 200

    /// Markdown as a voice should say it: no syntax marks, link and image text instead of their URLs, a bare URL
    /// said as "link", a code block announced instead of read out, and @mentions without the @.
    public static func spoken(fromMarkdown markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for (pattern, template, options) in rules {
            text = replace(pattern, in: text, with: template, options: options)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The spoken text in segments, split at paragraphs, then sentences, then (for a long sentence) clauses.
    public static func segments(_ spoken: String) -> [Segment] {
        let paragraphs = split(spoken, at: "\\n{2,}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var segments: [Segment] = []
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let oneLine = replace("\\n+", in: paragraph, with: " ").trimmingCharacters(in: .whitespaces)
            let sentences = split(oneLine, at: "(?<=[.!?\u{2026}])\\s+")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let effective = sentences.isEmpty ? [oneLine] : sentences
            for (sentenceIndex, sentence) in effective.enumerated() {
                let clauses = splitLongClause(sentence)
                for (clauseIndex, clause) in clauses.enumerated() where !clause.isEmpty {
                    let lastClause = clauseIndex == clauses.count - 1
                    let lastSentence = sentenceIndex == effective.count - 1
                    let lastParagraph = paragraphIndex == paragraphs.count - 1
                    var pause = clausePause
                    if lastClause { pause = lastSentence ? paragraphPause : sentencePause }
                    if lastClause && lastSentence && lastParagraph { pause = 0 }
                    segments.append(Segment(text: clause, pauseAfter: pause))
                }
            }
        }
        return segments
    }

    /// In order, as the web applies them.
    private static let rules: [(String, String, NSRegularExpression.Options)] = [
        ("```[\\s\\S]*?```", " . code block . ", []),
        ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1", []),
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1", []),
        ("https?://\\S+", "link", []),
        ("`([^`]+)`", "$1", []),
        ("(\\*\\*|__|\\*|_|~~)(.*?)\\1", "$2", []),
        ("^\\s{0,3}#{1,6}\\s+", "", [.anchorsMatchLines]),
        ("^\\s{0,3}>\\s?", "", [.anchorsMatchLines]),
        ("^\\s{0,3}(?:[-*+]|\\d+\\.)\\s+", "", [.anchorsMatchLines]),
        ("^\\s{0,3}[-*_]{3,}\\s*$", "", [.anchorsMatchLines]),
        ("\\|", " ", []),
        ("(^|\\s)@([a-z0-9][\\w-]*)", "$1$2", [.caseInsensitive]),
        ("[ \\t]+", " ", []),
        ("\\n{3,}", "\n\n", [])
    ]

    private static func splitLongClause(_ clause: String) -> [String] {
        guard clause.count > maxSegmentLength else { return [clause] }
        var parts: [String] = []
        var remaining = clause.trimmingCharacters(in: .whitespaces)
        while remaining.count > maxSegmentLength {
            // Prefer a comma or semicolon; else the last space; else a hard cut.
            let window = String(remaining.prefix(maxSegmentLength))
            let breakAt = [", ", "; ", " "]
                .compactMap { window.range(of: $0, options: .backwards).map { window.distance(from: window.startIndex, to: $0.lowerBound) } }
                .max() ?? -1
            let cut = breakAt > 40 ? breakAt + 1 : maxSegmentLength
            parts.append(String(remaining.prefix(cut)).trimmingCharacters(in: .whitespaces))
            remaining = String(remaining.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
        }
        if !remaining.isEmpty { parts.append(remaining) }
        return parts
    }

    private static func replace(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func split(_ text: String, at pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        pieces.append(String(text[start...]))
        return pieces
    }
}
