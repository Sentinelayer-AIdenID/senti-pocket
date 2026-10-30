import Foundation
import SwiftUI

/// Reads a box's events stream and keeps its terminal lines. New lines reach the screen in batches a few times a
/// second, never one redraw per printed line, so a chatty build cannot keep the main thread busy.
@MainActor
final class BoxShellFeed: ObservableObject {
    enum Status: Equatable {
        case connecting, live, unavailable
    }

    @Published private(set) var lines: [BoxShellLine] = []
    @Published private(set) var status: Status = .connecting
    private var task: Task<Void, Never>?

    /// No cache, no cookies: the view token is in the link, and nothing is kept after the panel closes.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func start(_ url: URL) {
        guard task == nil else { return }
        // Reading and parsing run off the main thread (a box's stream also carries file captures, which can be
        // large); only finished batches come back to it.
        task = Task.detached(priority: .utility) { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let delivered = await Self.read(url) { batch, reset in
                    await self?.apply(batch, reset: reset)
                }
                guard !Task.isCancelled else { return }
                failures = delivered ? 0 : failures + 1
                if failures >= 3 { await self?.markUnavailable() }
                // The stream replays from the start on each connection.
                try? await Task.sleep(nanoseconds: UInt64(min(30, 2 << min(failures, 4))) * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func apply(_ batch: [BoxShellLine], reset: Bool) {
        status = .live
        lines = Array(((reset ? [] : lines) + batch).suffix(BoxShell.keptLines))
    }

    private func markUnavailable() {
        status = .unavailable
    }

    /// One connection, read to its end; true when it delivered anything.
    nonisolated private static func read(
        _ url: URL,
        deliver: @Sendable ([BoxShellLine], _ reset: Bool) async -> Void
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        var fresh: [BoxShellLine] = []
        var nextId = 0
        var lastFlush = Date()
        var delivered = false
        await deliver([], true)
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let parsed = BoxShell.lines(fromFrame: String(line.dropFirst(5)), firstId: nextId)
                nextId += parsed.count
                fresh += parsed
                if !fresh.isEmpty, fresh.count >= 80 || Date().timeIntervalSince(lastFlush) > 0.3 {
                    await deliver(fresh, false)
                    fresh.removeAll()
                    lastFlush = Date()
                    delivered = true
                }
            }
        } catch {}
        if !fresh.isEmpty {
            await deliver(fresh, false)
            delivered = true
        }
        return delivered
    }
}

/// The box's terminal in the Flight record: commands, their output (errors in red), and how each ended, following
/// the newest line.
struct BoxShellView: View {
    let eventsURL: URL
    @StateObject private var feed = BoxShellFeed()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(feed.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: feed.lines.last?.id) { last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        .environment(\.colorScheme, .dark)
        .onAppear { feed.start(eventsURL) }
        .onDisappear { feed.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The box's shell")
    }

    private var statusLine: String {
        switch feed.status {
        case .connecting: return "Connecting to the box's shell…"
        case .live: return feed.lines.isEmpty ? "Live · nothing printed yet" : "Live · \(feed.lines.count) lines"
        case .unavailable: return "The box's shell can't be reached right now. Trying again."
        }
    }

    private func color(_ kind: BoxShellLine.Kind) -> Color {
        switch kind {
        case .command: return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .output: return .white.opacity(0.88)
        case .error: return Color(red: 1.0, green: 0.48, blue: 0.45)
        case .exit: return .white.opacity(0.5)
        }
    }
}
