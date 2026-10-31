import Foundation
import PocketUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A thread's summary for its row in the room (Carter, #55474: "I wish I had the summarized here at top level before I
/// even open the thread"). Written on the phone by Apple's on-device model where the phone has it (iOS 26 with Apple
/// Intelligence): private, free, and nothing leaves the phone. Elsewhere there is none, and the row reads as before.
///
/// Its parts are Carter's (10-30, "The Perfect Engineering Swarm Summary Spec"): what the thread set out to do, what
/// changed, how (who did which steps, with which tools), what was checked and how it came out, and the record (the
/// commits, pull requests and builds it names). The record is copied from the thread, never written by the model.
/// They read as one paragraph of prose, without labels (Carter, 10-31), with when and who in the line under it.
protocol ThreadSummarizing: Sendable {
    func summarize(thread lines: [String]) async -> String?
}

enum ThreadSummaryInput {
    /// At least this many replies before a thread is worth summarizing.
    static let minimumReplies = 3
    /// The newest replies the model reads, each cut short, so a long thread stays well inside its context.
    static let maximumLines = 24
    static let maximumLineLength = 280
    /// A summary (or one part of it) longer than this is cut.
    static let maximumSummaryLength = 240
    /// The most record entries kept.
    static let maximumRecord = 8

    /// "author: words" for each reply, newest last, the box signature and Markdown left out.
    static func lines(_ replies: [RoomChatMessageInput]) -> [String] {
        let ordered = replies.sorted { ($0.date ?? .distantPast, $0.sequenceId) < ($1.date ?? .distantPast, $1.sequenceId) }
        return ordered.suffix(maximumLines).map { reply in
            let words = RoomChatQuiet.line(reply.text)
            let cut = words.count > maximumLineLength ? String(words.prefix(maximumLineLength)) + "…" : words
            return "\(reply.authorName): \(cut)"
        }
    }

    /// The model's answer as a row shows it: one paragraph, no Markdown markers, bounded; nil when empty.
    static func cleaned(_ answer: String) -> String? {
        var text = answer.replacingOccurrences(of: "\n", with: " ")
        for marker in ["**", "__", "`", "#"] { text = text.replacingOccurrences(of: marker, with: "") }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > maximumSummaryLength ? String(text.prefix(maximumSummaryLength)) + "…" : text
    }

    private static let commitExpression = try? NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#)
    /// Two to four digits: a room's message numbers (#55514) are five and up, and are not pull requests (warden, #264).
    private static let pullRequestExpression = try? NSRegularExpression(pattern: #"(?<![\w/])#\d{2,4}\b"#)
    private static let buildExpression = try? NSRegularExpression(pattern: #"\b20\d{8}\b"#)

    /// The commits, pull requests and builds the thread names, in the order it names them, each once. A commit is
    /// seven or more hex characters with at least one digit and one letter, so plain words and numbers are not taken.
    static func record(in lines: [String]) -> [String] {
        var found: [String] = []
        func add(_ value: String) {
            if !found.contains(value), found.count < maximumRecord { found.append(value) }
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            var hits: [(Int, String)] = []
            for expression in [pullRequestExpression, buildExpression, commitExpression].compactMap({ $0 }) {
                for match in expression.matches(in: line, range: range) {
                    guard let span = Range(match.range, in: line) else { continue }
                    let value = String(line[span])
                    if expression === commitExpression {
                        guard value.contains(where: \.isNumber), value.contains(where: \.isLetter) else { continue }
                    }
                    hits.append((match.range.location, value))
                }
            }
            for (_, value) in hits.sorted(by: { $0.0 < $1.0 }) { add(value) }
        }
        return found
    }

    /// The summary as the room keeps it: one paragraph, the parts in Carter's order as sentences without labels, the
    /// stock phrases that say nothing ("None mentioned") left out, and the ids the thread names last.
    static func composed(objective: String, changed: String, how: String, checks: String, record: [String]) -> String? {
        guard let objective = cleaned(objective) else { return nil }
        var parts = [objective] + [changed, how, checks].compactMap { cleaned($0) }
        if !record.isEmpty { parts.append("The thread names \(SummaryProse.list(record)).") }
        let prose = SummaryProse.sentences(parts)
        return prose.isEmpty ? nil : prose
    }

    /// The line under the summary: when the thread's replies were written, and who wrote them, most replies first.
    static func details(_ replies: [RoomChatMessageInput], now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for reply in replies {
            if counts[reply.authorName] == nil { order.append(reply.authorName) }
            counts[reply.authorName, default: 0] += 1
        }
        let ranked = order.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
            .map(\.element)
        let dates = replies.compactMap(\.date)
        return [SummaryProse.when(from: dates.min(), to: dates.max(), now: now, calendar: calendar),
                SummaryProse.people(ranked)].compactMap { $0 }
    }
}

#if canImport(FoundationModels)
/// What the on-device model writes for a thread, typed, so every part comes back in its place.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ThreadDigest {
    @Guide(description: "The goal the thread worked toward: the ticket, bug or request it set out to resolve. One sentence.")
    var objective: String
    @Guide(description: "What actually changed: the code, behaviour or decision, concretely, with names from the thread. One or two sentences.")
    var changed: String
    @Guide(description: "How it got there: which agent or person did which steps, with which tools, commands or files. One or two sentences.")
    var how: String
    @Guide(description: "What was checked and how it came out: tests, builds, reviews or gates that passed or failed. Write 'None mentioned' if the thread names none.")
    var checks: String
}
#endif

/// Apple's on-device model, when this phone has it and it is ready.
struct OnDeviceThreadSummarizer: ThreadSummarizing {
    static let instructions = """
        You summarize an engineering chat thread for someone deciding whether to open it. Fill each part from the \
        thread only: never invent names, numbers, tools or results that are not in it. Be concrete and plain, \
        without greetings, lists or Markdown.
        """

    func summarize(thread lines: [String]) async -> String? {
        guard !lines.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(
                    to: "The thread, oldest first:\n" + lines.joined(separator: "\n"),
                    generating: ThreadDigest.self
                )
                let digest = response.content
                return ThreadSummaryInput.composed(
                    objective: digest.objective, changed: digest.changed, how: digest.how, checks: digest.checks,
                    record: ThreadSummaryInput.record(in: lines)
                )
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
