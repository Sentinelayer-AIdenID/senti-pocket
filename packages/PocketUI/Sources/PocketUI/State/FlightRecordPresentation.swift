import Foundation
import PocketContracts

/// The Flight record panel: who is working on what in the room. Boxes (agents on their own machines) with what
/// they are thinking and doing, and the room's other agents with their latest "working on" line.
public struct FlightRecordState: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral
        case ok
        case fail
    }

    /// One step: a thought in the agent's words, or a command and how it ended.
    public struct Line: Equatable, Identifiable, Sendable {
        public let id: String
        public let at: Date?
        public let text: String
        public let isCommand: Bool
        public let tone: Tone

        public init(id: String, at: Date?, text: String, isCommand: Bool, tone: Tone = .neutral) {
            self.id = id
            self.at = at
            self.text = text
            self.isCommand = isCommand
            self.tone = tone
        }
    }

    public struct Box: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let model: String
        public let phase: String
        /// Its ticket's title, or its job.
        public let job: String?
        /// What it is doing now: its newest thought, or its newest command.
        public let current: String?
        public let lastActivity: Date?
        public let expiresAt: Date?
        public let consoleURL: URL?
        /// Newest first.
        public let lines: [Line]
        public let posts: Int
        public let doneSummary: String?

        public init(id: String, name: String, model: String, phase: String, job: String?, current: String?,
                    lastActivity: Date?, expiresAt: Date?, consoleURL: URL?, lines: [Line], posts: Int, doneSummary: String?) {
            self.id = id
            self.name = name
            self.model = model
            self.phase = phase
            self.job = job
            self.current = current
            self.lastActivity = lastActivity
            self.expiresAt = expiresAt
            self.consoleURL = consoleURL
            self.lines = lines
            self.posts = posts
            self.doneSummary = doneSummary
        }

        /// Working now (rather than waiting for its next turn): the line under its name shimmers.
        public var isWorking: Bool {
            ["working", "capturing", "booting", "probing"].contains(phase.lowercased())
        }
    }

    /// An agent in the room without a box of its own (or whose box is not listed): its latest "working on" line.
    public struct Agent: Equatable, Identifiable, Sendable {
        public let id: String
        public let isHere: Bool
        public let isIdle: Bool
        public let status: String?
        public let statusAt: Date?

        public init(id: String, isHere: Bool, isIdle: Bool, status: String?, statusAt: Date?) {
            self.id = id
            self.isHere = isHere
            self.isIdle = isIdle
            self.status = status
            self.statusAt = statusAt
        }
    }

    /// The room's figures, as the web's two rows of three (Carter, 10-27 and #55014): boxes minted, active and
    /// finished, then agent hours worked, days saved against one engineer, and the cost.
    public struct Totals: Equatable, Sendable {
        public let minted: Int
        public let active: Int
        public let finished: Int
        /// The counts and the cost are minimums: the service left the room's oldest boxes out.
        public let isMinimum: Bool
        /// Agent hours worked, added together; nil when no box has a working record yet.
        public let workedHours: Double?
        /// The hours, and so the days saved, are a minimum: some records are missing or still being counted.
        public let workIsMinimum: Bool
        /// Days saved against one engineer at 8 hours a day; nil when the room's span is unknown.
        public let savedDays: Double?
        public let costUsd: Double?
        /// The cost as a percent of engineers at $80 an hour for the same hours.
        public let costPercent: Double?

        public init(minted: Int, active: Int, finished: Int, isMinimum: Bool = false, workedHours: Double? = nil,
                    workIsMinimum: Bool = false, savedDays: Double? = nil, costUsd: Double? = nil, costPercent: Double? = nil) {
            self.minted = minted
            self.active = active
            self.finished = finished
            self.isMinimum = isMinimum
            self.workedHours = workedHours
            self.workIsMinimum = workIsMinimum
            self.savedDays = savedDays
            self.costUsd = costUsd
            self.costPercent = costPercent
        }

        /// A figure as the web writes it: one decimal below 10, none above, and a small positive value never as 0.
        public static func amount(_ value: Double, locale: Locale = .current) -> String {
            if value > 0 && value < 0.05 { return "<0.1" }
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = value < 10 ? 1 : 0
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        /// A minimum reads "≥" (at least); one that rounds below 0.1 reads ">0".
        public static func shown(_ value: Double, isMinimum: Bool, locale: Locale = .current) -> String {
            let text = amount(value, locale: locale)
            guard isMinimum else { return text }
            return text == "<0.1" ? ">0" : "≥" + text
        }

        public static func dayUnit(_ value: Double, locale: Locale = .current) -> String {
            amount(value, locale: locale) == "1" ? "day" : "days"
        }

        public static func usd(_ value: Double, locale: Locale = .current) -> String {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.minimumFractionDigits = value >= 100 ? 0 : 2
            formatter.maximumFractionDigits = value >= 100 ? 0 : 2
            return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
        }
    }

    public let boxes: [Box]
    public let agents: [Agent]
    public let finishedBoxes: Int
    public let isLoading: Bool
    public let failure: String?
    public let totals: Totals?

    public init(boxes: [Box] = [], agents: [Agent] = [], finishedBoxes: Int = 0, isLoading: Bool = false, failure: String? = nil,
                totals: Totals? = nil) {
        self.boxes = boxes
        self.agents = agents
        self.finishedBoxes = finishedBoxes
        self.isLoading = isLoading
        self.failure = failure
        self.totals = totals
    }

    /// Thoughts and commands merged newest first, at most `limit`.
    public static func lines(narration: [(at: String, text: String)], commands: [(at: String, text: String, exitCode: Int?)],
                             limit: Int = 30) -> [Line] {
        var lines: [Line] = []
        for (index, entry) in narration.enumerated() {
            lines.append(Line(id: "n\(index)", at: ParsedSessionTimestamp(entry.at).date, text: entry.text, isCommand: false))
        }
        for (index, entry) in commands.enumerated() {
            let tone: Tone = entry.exitCode.map { $0 == 0 ? .ok : .fail } ?? .neutral
            lines.append(Line(id: "c\(index)", at: ParsedSessionTimestamp(entry.at).date, text: Self.command(entry.text), isCommand: true, tone: tone))
        }
        return Array(lines.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }.prefix(limit))
    }

    /// A command as one readable line: the shell wrapper peeled off, kept short.
    public static func command(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for wrapper in ["/bin/bash -lc ", "bash -lc ", "/bin/sh -c ", "sh -c "] where text.hasPrefix(wrapper) {
            text = String(text.dropFirst(wrapper.count))
            // The record may cut a long command before its closing quote.
            if let first = text.first, first == "\"" || first == "'" {
                text.removeFirst()
                if text.last == first { text.removeLast() }
            }
            break
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }
}
