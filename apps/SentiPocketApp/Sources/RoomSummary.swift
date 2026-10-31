import Foundation
import PocketUI
import PocketVoice
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A room's summary, written by the API on request (Carter, 10-30: "I come to a room like this either as a stranger
/// or if it's been a long time"). `POST /api/v1/sessions/{id}/summary/generate` runs a small model with a deterministic
/// fallback and a 60-second cap, and keeps the result on the room.
///
/// The server's prose (`format: "prose-v2"`) is shown exactly as written, with its time range, participants and mode
/// in the line under it; only an older server's five labelled parts, which come without a format, are read into
/// sentences. While a model is still writing it (`pending`), the server's basic summary stands in.
struct RoomSummary: Equatable, Sendable {
    /// A heading, when it says more than the summary's first sentence.
    let title: String?
    let reading: SummaryReading
    /// Written without a model: the server's basic summary, or an older server's own outline.
    let isFallback: Bool
    /// Why it was written without AI, in plain words (`fallbackReason`); nil when the server doesn't say.
    let fallbackNote: String?
    /// A model is still writing the summary of the room as it is now; this one stands in until it settles.
    let isPending: Bool

    /// What the sheet says when nothing in the summary said anything.
    static let nothingYet = "There isn't enough in this room to summarize yet."

    init(title: String? = nil, reading: SummaryReading, isFallback: Bool = false, fallbackNote: String? = nil,
         isPending: Bool = false) {
        self.title = title
        self.reading = reading
        self.isFallback = isFallback
        self.fallbackNote = fallbackNote
        self.isPending = isPending
    }

    /// The room's saved summary as the room list has it (already read as prose), for a member who isn't its owner.
    init(saved text: String) {
        self.init(reading: SummaryReading(prose: text))
    }

    /// The summary in the API's answer; nil when the answer isn't one or holds no summary.
    init?(json data: Data, now: Date = Date(), calendar: Calendar = .current) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(answer: object, now: now, calendar: calendar)
    }

    /// The summary in the API's answer, or nil when it says there is none for the room as it is now
    /// (`"summary": null`). Throws `RoomSendError.rejected` when the answer can't be read.
    static func decode(_ data: Data, now: Date = Date(), calendar: Calendar = .current) throws -> RoomSummary? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoomSendError.rejected
        }
        if object["summary"] == nil || object["summary"] is NSNull { return nil }
        guard let summary = RoomSummary(answer: object, now: now, calendar: calendar) else { throw RoomSendError.rejected }
        return summary
    }

    /// The API's answer, as `docs/session-summaries.md` gives it: `{"ok": true, "cached": …, "pending": …,
    /// "summary": {"format": "prose-v2", "summary": "…", "title": "…", "mode": "llm" | "basic", "model": "…",
    /// "fallbackReason": "…", "participants": […], "timeRange": {…}, …}, …}`. A field the summary object lacks is read
    /// from the answer around it.
    init?(answer object: [String: Any], now: Date = Date(), calendar: Calendar = .current) {
        let fields = object.merging(object["summary"] as? [String: Any] ?? [:]) { _, inner in inner }
        guard let text = fields["summary"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let format = fields["format"] as? String
        let details = SummaryProse.details(server: fields, now: now, calendar: calendar)
        let written = SummaryReading(server: text, format: format, details: details)
        let reading = written.prose.isEmpty ? SummaryReading(prose: Self.nothingYet, details: details) : written
        let mode = (fields["mode"] as? String)?.lowercased()
        let isFallback = (fields["model"] as? String) == "deterministic-fallback" || mode == "basic"
        self.init(
            title: Self.heading(fields["title"] as? String, format: format, over: reading.prose),
            reading: reading,
            isFallback: isFallback,
            fallbackNote: isFallback ? SummaryProse.fallbackNote(fields["fallbackReason"] as? String) : nil,
            isPending: (object["pending"] as? Bool) ?? false
        )
    }

    /// The title as a heading: the server's as written when the summary has a format, an older server's read like its
    /// summary and without a closing period. None when it is empty, when it only names the room by id ("Session
    /// 1a2b3c4d"), or when the summary opens with it (an older server's title was its objective).
    static func heading(_ raw: String?, format: String?, over prose: String) -> String? {
        guard let raw else { return nil }
        var title = raw
        if SummaryProse.isLegacy(format: format) {
            title = SummaryProse.legacy(raw).replacingOccurrences(of: "\n", with: " ")
            while let last = title.last, ".:;,".contains(last) { title.removeLast() }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.range(of: #"^session [0-9a-f]{6,}$"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !letters(prose).hasPrefix(letters(title)) else { return nil }
        return title
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

protocol RoomSummaryGenerating: Sendable {
    /// Asks for the room's summary, as its owner: a new one, or the one already made for the room as it is now. Nil
    /// when the server has none to give.
    func generateSummary(sessionId: String) async throws -> RoomSummary?
    /// Reads the room's summary without asking for a new one (`cachedOnly=true`); nil when there is none for the room
    /// as it is now.
    func readSummary(sessionId: String) async throws -> RoomSummary?
}

/// While a model writes the room's summary the server answers with its basic summary and `pending`, and the sheet reads
/// it again (`cachedOnly=true`) until it settles: soon at first, then less often, for about two minutes in all. The
/// server stops calling a summary pending a minute after the model was asked.
enum RoomSummaryPolling {
    /// Seconds before each read.
    static let delays: [TimeInterval] = [2, 3, 5, 8, 13, 21, 34, 34]

    /// Reads the summary after each delay for as long as it is pending, giving `update` each one read, and returns the
    /// last. That one is still pending only when the reads ran out, one failed, or the server had none for the room as
    /// it is now (it moved on while the model wrote).
    @MainActor
    static func settle(_ first: RoomSummary,
                       read: () async throws -> RoomSummary?,
                       sleep: (TimeInterval) async throws -> Void,
                       update: (RoomSummary) -> Void) async throws -> RoomSummary {
        var current = first
        for delay in delays where current.isPending {
            try await sleep(delay)
            let next: RoomSummary?
            do {
                next = try await read()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return current
            }
            guard let next else { return current }
            current = next
            update(next)
        }
        return current
    }
}

/// Why a summary was not made, as the server (or the edge in front of it) answered: what the sheet says, and the
/// line it can send to the room so the failure reaches the agents at once (Carter, #55375: "that error should somehow
/// reach you guys quick. We cannot allow an error like that to go unnoticed").
struct RoomSummaryFailure: Error, Equatable {
    let status: Int
    /// The server's request id; nil when the request was refused before it reached the server.
    let requestId: String?

    var message: String {
        switch status {
        case 403, 404: return "Only the room's owner can summarize it."
        case 429: return "That's the most summaries for this minute. Try again in a minute."
        case 500..<600 where requestId == nil: return "Summaries aren't open on the server yet."
        case 500..<600: return "The summary service didn't answer (error \(status)). Try again in a minute."
        default: return "The summary could not be made (error \(status))."
        }
    }

    /// One line for the room, with what an agent needs to find it in the logs.
    func report(build: String) -> String {
        let reached = requestId.map { "request id `\($0)`" } ?? "refused before it reached the server (no request id)"
        return "Pocket problem: Summarize this room failed with HTTP \(status), \(reached). Build \(build)."
    }
}

extension HTTPRoomMessageSender: RoomSummaryGenerating {
    func generateSummary(sessionId: String) async throws -> RoomSummary? {
        try await summary(sessionId: sessionId, query: nil, keyPrefix: "summary-")
    }

    func readSummary(sessionId: String) async throws -> RoomSummary? {
        try await summary(sessionId: sessionId, query: "cachedOnly=true", keyPrefix: "summary-read-")
    }

    /// The summary can take up to the API's 60 seconds, longer than the live requests' deadline, so it gets its own
    /// session: no cache, no cookies, the bearer per request.
    private func summary(sessionId: String, query: String?, keyPrefix: String) async throws -> RoomSummary? {
        let (data, http) = try await postAnswer(sessionId: sessionId, path: "summary/generate",
                                                idempotencyKey: keyPrefix + UUID().uuidString.lowercased(),
                                                body: [:], query: query, session: Self.summarySession)
        if http.statusCode == 401 { throw RoomSendError.reauthenticationRequired }
        guard (200..<300).contains(http.statusCode) else {
            let requestId = http.value(forHTTPHeaderField: "X-Request-Id").flatMap { $0.isEmpty ? nil : $0 }
            throw RoomSummaryFailure(status: http.statusCode, requestId: requestId)
        }
        return try RoomSummary.decode(data)
    }

    static let summarySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}

/// The summary sheet. For the room's owner it says it is working while the room is read, then shows the summary as
/// prose with Listen and Copy; while a model is still writing it, the basic summary shows with a note that the AI
/// summary is on its way, and the sheet reads it again until it is. Refresh asks the server again (a room that has
/// moved on gets a new summary). Every other member reads the room's saved summary here, without Refresh.
struct RoomSummarySheet: View {
    let sessionId: String
    let roomTitle: String
    /// Makes the room's summary and reads it again while a model writes it: the owner's. Nil for another member.
    let generator: (any RoomSummaryGenerating)?
    /// The room's saved summary as the room list has it, which a member who isn't the owner reads.
    var saved: String?
    @ObservedObject var reader: MessageReader
    var onClose: () -> Void
    /// Posts a failure's report line to the room, when the room lets you post.
    var onReport: ((String) -> Void)?

    private enum Phase: Equatable {
        case working
        case ready(RoomSummary)
        /// The server has no summary of the room, or the room has none saved.
        case empty
        case failed(String, report: String?)
    }

    @State private var phase: Phase = .working
    /// The sheet is reading the summary again while a model writes it.
    @State private var waitsForAI = false
    @State private var copied = false
    @State private var reported = false
    /// Each load: Refresh and Try again start a new one, and the one before it stops.
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .working:
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading the whole room. This can take up to a minute.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 24)
                        .accessibilityIdentifier("pocket.room.summary.working")
                    case .ready(let summary):
                        if let title = summary.title {
                            Text(title)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        // Side by side, or one over the other when large text leaves no room.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                listenButton(summary)
                                copyButton(summary)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                listenButton(summary)
                                copyButton(summary)
                            }
                        }
                        if summary.isPending && waitsForAI {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                ProgressView()
                                Text("Writing the AI summary. The basic one shows until it's ready.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("pocket.room.summary.pending")
                        }
                        SummaryReadingView(summary.reading, identifier: "pocket.room.summary.text")
                        if let note = note(for: summary) {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("pocket.room.summary.note")
                        }
                    case .empty:
                        Text(generator == nil ? "This room has no summary yet. Its owner can write one." : RoomSummary.nothingYet)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pocket.room.summary.none")
                    case .failed(let message, let report):
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("pocket.room.summary.failure")
                        HStack(spacing: 12) {
                            Button("Try again") { attempt += 1 }
                                .buttonStyle(.bordered)
                            if let report, let onReport {
                                Button(reported ? "Sent to the room" : "Send this problem to the room") {
                                    onReport(report)
                                    reported = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(reported)
                                .accessibilityIdentifier("pocket.room.summary.report")
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(roomTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only the owner can make a new summary.
                if generator != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            if reader.readingId == readId { reader.stop() }
                            attempt += 1
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(phase == .working)
                        .accessibilityLabel("Refresh summary")
                        .accessibilityIdentifier("pocket.room.summary.refresh")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .task(id: attempt) { await load() }
        .onDisappear {
            if reader.readingId == readId { reader.stop() }
        }
    }

    /// The line under the summary about how it was written, when it has something to say: that the AI summary isn't
    /// ready yet, why a basic summary was written without AI, that an older server's outline came without a model, or
    /// that this is the room's saved summary.
    private func note(for summary: RoomSummary) -> String? {
        if summary.isPending {
            return waitsForAI ? nil : "The AI summary isn't ready yet. Refresh to check again."
        }
        if let note = summary.fallbackNote { return note }
        if summary.isFallback && !summary.reading.detailParts.contains("Basic summary") {
            return "Written without AI this time: the summary service did not answer, so this is the room's own outline."
        }
        if generator == nil { return "This is the room's saved summary. Its owner can make a new one." }
        return nil
    }

    private func listenButton(_ summary: RoomSummary) -> some View {
        Button {
            if reader.readingId == readId {
                reader.stop()
            } else {
                ReadAloudSource.shared.reading(in: sessionId)
                _ = reader.read(id: readId, markdown: summary.reading.prose, title: "Room summary")
            }
        } label: {
            Label(reader.readingId == readId ? "Stop" : "Listen",
                  systemImage: reader.readingId == readId ? "stop.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(reader.readingId == readId ? "Stop reading the summary" : "Listen to the summary")
        .accessibilityIdentifier("pocket.room.summary.listen")
    }

    private func copyButton(_ summary: RoomSummary) -> some View {
        Button {
            copy(summary)
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(copied ? "Summary copied" : "Copy the summary")
        .accessibilityIdentifier("pocket.room.summary.copy")
    }

    private var readId: String { "summary:\(sessionId)" }

    private static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
    }

    private func load() async {
        copied = false
        waitsForAI = false
        guard let generator else {
            phase = saved.map { .ready(RoomSummary(saved: $0)) } ?? .empty
            return
        }
        phase = .working
        do {
            let first = try await generator.generateSummary(sessionId: sessionId)
            // A load that Refresh replaced, or a closed sheet, leaves the sheet alone.
            guard !Task.isCancelled else { return }
            guard let first else {
                phase = .empty
                return
            }
            phase = .ready(first)
            guard first.isPending else { return }
            waitsForAI = true
            let last = try await RoomSummaryPolling.settle(
                first,
                read: { try await generator.readSummary(sessionId: sessionId) },
                sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                update: { phase = .ready($0) }
            )
            guard !Task.isCancelled else { return }
            waitsForAI = false
            phase = .ready(last)
        } catch RoomSendError.reauthenticationRequired {
            guard !Task.isCancelled else { return }
            waitsForAI = false
            phase = .failed("Sign in again to summarize this room.", report: nil)
        } catch let failure as RoomSummaryFailure {
            guard !Task.isCancelled else { return }
            waitsForAI = false
            CrashReporter.shared.note("summary failed \(failure.status)")
            phase = .failed(failure.message, report: failure.report(build: Self.build))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            waitsForAI = false
            phase = .failed("The summary could not be made just now. Check your connection and try again.", report: nil)
        }
    }

    private func copy(_ summary: RoomSummary) {
        #if canImport(UIKit)
        UIPasteboard.general.string = [summary.title, summary.reading.prose, summary.reading.details]
            .compactMap { $0 }.joined(separator: "\n\n")
        #endif
        copied = true
    }
}
