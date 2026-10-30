import Foundation
import PocketUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A thread's summary for its row in the room (Carter, #55474: "I wish I had the summarized here at top level before I
/// even open the thread"). Written on the phone by Apple's on-device model where the phone has it (iOS 26 with Apple
/// Intelligence): private, free, and nothing leaves the phone. Elsewhere there is none, and the row reads as before.
protocol ThreadSummarizing: Sendable {
    func summarize(thread lines: [String]) async -> String?
}

enum ThreadSummaryInput {
    /// At least this many replies before a thread is worth summarizing.
    static let minimumReplies = 3
    /// The newest replies the model reads, each cut short, so a long thread stays well inside its context.
    static let maximumLines = 24
    static let maximumLineLength = 280
    /// A summary longer than this is cut.
    static let maximumSummaryLength = 240

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
}

/// Apple's on-device model, when this phone has it and it is ready.
struct OnDeviceThreadSummarizer: ThreadSummarizing {
    static let instructions = """
        You summarize a chat thread for someone deciding whether to open it. Write one or two short sentences in \
        plain words: what was done or decided, and what is still open or waiting on someone. Do not greet, do not \
        use lists or Markdown, and do not invent anything that is not in the thread.
        """

    func summarize(thread lines: [String]) async -> String? {
        guard !lines.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: "The thread, oldest first:\n" + lines.joined(separator: "\n"))
                return ThreadSummaryInput.cleaned(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
