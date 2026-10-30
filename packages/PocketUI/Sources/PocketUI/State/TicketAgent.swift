import Foundation

/// The signal model's name is never shown anywhere (sentinelayer-web `ticketSignal.ts`, Carter 2026-10-18): ticket
/// text reads "the signal layer" in its place, as the web's drawer reads it.
public enum TicketSignal {
    static let modelNamePattern = #"\b[Jj][Ee][Vv](?:[-\s]?\d+(?:\.\d+)*|(?=[A-Z_\d])\w*|\b)"#

    public static func hideModelName(_ text: String) -> String {
        guard let modelName = try? NSRegularExpression(pattern: modelNamePattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return modelName.stringByReplacingMatches(in: text, range: range, withTemplate: "the signal layer")
    }

    /// A ticket's title as a person sees it anywhere: the name hidden, "(untitled)" when empty.
    public static func publicTitle(_ title: String) -> String {
        let shown = hideModelName(title.trimmingCharacters(in: .whitespacesAndNewlines))
        return shown.isEmpty ? "(untitled)" : shown
    }
}

/// Starting an agent on its own machine for a ticket (sentinelayer-web `ticketMintPrefill`,
/// `ticketJobDescription`): its name from the ticket's id, and a job that starts from the ticket.
public enum TicketAgent {
    /// The 8 characters a PR body names in `Closes-Ticket:`.
    public static func shortId(_ ticketId: String) -> String {
        String(ticketId.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
    }

    public static func agentName(for ticketId: String) -> String {
        "mint-\(shortId(ticketId))"
    }

    /// The job: the ticket's id, title, status and room, its description, and what to do with it.
    public static func jobDescription(ticketId: String, title: String, status: String, sessionId: String, body: String) -> String {
        let description = body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let header = [
            "Ticket: \(ticketId)",
            "Title: \(TicketSignal.publicTitle(title))",
            "Status: \(status.isEmpty ? "unknown" : status)",
            "Room: \(sessionId)"
        ].joined(separator: "\n")
        return [
            header,
            TicketSignal.hideModelName("Description:\n\(description.isEmpty ? "(no description on the ticket)" : description)"),
            "You were minted for this ticket. Read it, post a short plan in the room, do the work in your machine, "
                + "and when a PR finishes it put the line `Closes-Ticket: \(shortId(ticketId))` in the PR body."
        ].joined(separator: "\n\n")
    }
}
