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
struct RoomSummary: Equatable, Sendable {
    let title: String?
    let text: String
    /// Written by a model, or by the API's own fallback when no model answered.
    let isFallback: Bool

    /// The API's answer: `{"ok": true, "summary": {"summary": "…", "title": "…", "model": "…"}, …}`.
    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = object["summary"] as? [String: Any],
              let text = (summary["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        self.text = text
        let title = (summary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
        isFallback = (summary["model"] as? String) == "deterministic-fallback"
    }
}

protocol RoomSummaryGenerating: Sendable {
    func generateSummary(sessionId: String) async throws -> RoomSummary
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
    /// The summary can take up to the API's 60 seconds, longer than the live requests' deadline, so it gets its own
    /// session: no cache, no cookies, the bearer per request.
    func generateSummary(sessionId: String) async throws -> RoomSummary {
        let (data, http) = try await postAnswer(sessionId: sessionId, path: "summary/generate",
                                                idempotencyKey: "summary-" + UUID().uuidString.lowercased(),
                                                body: [:], session: Self.summarySession)
        if http.statusCode == 401 { throw RoomSendError.reauthenticationRequired }
        guard (200..<300).contains(http.statusCode) else {
            let requestId = http.value(forHTTPHeaderField: "X-Request-Id").flatMap { $0.isEmpty ? nil : $0 }
            throw RoomSummaryFailure(status: http.statusCode, requestId: requestId)
        }
        guard let summary = RoomSummary(json: data) else { throw RoomSendError.rejected }
        return summary
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

/// The summary sheet: it says it is working while the room is read, then shows the summary with Listen and Copy.
struct RoomSummarySheet: View {
    let sessionId: String
    let roomTitle: String
    let generator: any RoomSummaryGenerating
    @ObservedObject var reader: MessageReader
    var onClose: () -> Void
    /// Posts a failure's report line to the room, when the room lets you post.
    var onReport: ((String) -> Void)?

    private enum Phase: Equatable {
        case working
        case ready(RoomSummary)
        case failed(String, report: String?)
    }

    @State private var phase: Phase = .working
    @State private var copied = false
    @State private var reported = false

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
                            Text(title).font(.title3.weight(.semibold))
                        }
                        HStack(spacing: 12) {
                            Button {
                                if reader.readingId == readId {
                                    reader.stop()
                                } else {
                                    ReadAloudSource.shared.reading(in: sessionId)
                                    _ = reader.read(id: readId, markdown: summary.text, title: "Room summary")
                                }
                            } label: {
                                Label(reader.readingId == readId ? "Stop" : "Listen",
                                      systemImage: reader.readingId == readId ? "stop.fill" : "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pocket.room.summary.listen")
                            Button {
                                copy(summary)
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pocket.room.summary.copy")
                        }
                        ChatMarkdownView(text: summary.text, ownHandles: [])
                            .accessibilityIdentifier("pocket.room.summary.text")
                        if summary.isFallback {
                            Text("Written without a model this time: the summary service did not answer, so this is the room's own outline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let message, let report):
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("pocket.room.summary.failure")
                        HStack(spacing: 12) {
                            Button("Try again") { Task { await load() } }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
        .task { await load() }
        .onDisappear {
            if reader.readingId == readId { reader.stop() }
        }
    }

    private var readId: String { "summary:\(sessionId)" }

    private static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
    }

    private func load() async {
        phase = .working
        do {
            phase = .ready(try await generator.generateSummary(sessionId: sessionId))
        } catch RoomSendError.reauthenticationRequired {
            phase = .failed("Sign in again to summarize this room.", report: nil)
        } catch let failure as RoomSummaryFailure {
            CrashReporter.shared.note("summary failed \(failure.status)")
            phase = .failed(failure.message, report: failure.report(build: Self.build))
        } catch {
            phase = .failed("The summary could not be made just now. Check your connection and try again.", report: nil)
        }
    }

    private func copy(_ summary: RoomSummary) {
        #if canImport(UIKit)
        UIPasteboard.general.string = [summary.title, summary.text].compactMap { $0 }.joined(separator: "\n\n")
        #endif
        copied = true
    }
}
