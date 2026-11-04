#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Who is working on a message, under it (Carter, #61655): one compact row per agent, live ones first and newest
/// first, at most three and then "+N working". A live row is a pulsing dot, the agent's name and its newest step in a few
/// words on one line; a finished one says how long it worked. Tapping a row shows every step with its time; tapping
/// again folds them. The rows keep one line's height whether live or finished, so a reader above them is never moved.
struct RoomWorkingRows: View {
    /// The message they work on.
    let sequenceId: Int64
    let sessions: [RoomWorkSession]
    /// Tells the room which agent's steps are open (the app reads a box's own record while they are), or nil.
    var onOpen: (String?) -> Void = { _ in }

    /// Steps a box's own record adds, by lowercased name, read while its row is open.
    @Environment(\.roomBoxSteps) private var boxSteps
    @State private var open: Set<String> = []
    @State private var showsAll = false

    var body: some View {
        #if DEBUG
        let _ = RoomRenderProbe.note(RoomRenderProbe.workingRows)
        #endif
        let shown = showsAll ? sessions : Array(sessions.prefix(RoomWorkSession.shownLimit))
        let hidden = sessions.dropFirst(shown.count)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { session in
                row(session)
                if open.contains(session.id) {
                    steps(of: session)
                }
            }
            if !hidden.isEmpty {
                Button {
                    showsAll = true
                } label: {
                    Text(Self.moreLabel(hidden: Array(hidden)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pocket.room.working.\(sequenceId).more")
            }
        }
        .padding(.top, 4)
    }

    /// "+2 working", and the finished ones after it: "+2 working · 1 done", "+1 done".
    static func moreLabel(hidden: [RoomWorkSession]) -> String {
        let live = hidden.filter(\.isLive).count
        let done = hidden.count - live
        let parts = [live > 0 ? "\(live) working" : nil, done > 0 ? "\(done) done" : nil].compactMap { $0 }
        return "+" + parts.joined(separator: " · ")
    }

    private func row(_ session: RoomWorkSession) -> some View {
        let isOpen = open.contains(session.id)
        return Button {
            if isOpen {
                open.remove(session.id)
            } else {
                open.insert(session.id)
            }
            // The box read for is the one just opened, or another still open.
            onOpen(isOpen ? open.first : session.id)
        } label: {
            HStack(spacing: 6) {
                if session.isLive {
                    LayerMotion(.pulse) {
                        Circle().fill(PocketPalette.listening)
                    }
                    .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Text(session.agentId)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(session.isLive ? session.latestStep : session.workedFor.map(RoomWorkSession.workedForLabel) ?? "Done")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(session))
        .accessibilityHint(isOpen ? "Hides the steps" : "Shows every step")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("pocket.room.working.\(sequenceId).\(session.id)")
    }

    static func accessibilityLabel(_ session: RoomWorkSession) -> String {
        if session.isLive { return "\(session.agentId) is working: \(session.latestStep)" }
        if let worked = session.workedFor { return "\(session.agentId) worked for \(RoomWorkSession.spokenDuration(worked))" }
        return "\(session.agentId) is done"
    }

    private func steps(of session: RoomWorkSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.allSteps(session, record: boxSteps[session.id] ?? [])) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let at = step.at {
                        Text(at, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                    }
                    Text(step.text)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.room.working.\(sequenceId).\(session.id).steps")
    }

    /// Its notes and, for a box, its own record's narration while it worked on this message, in time order.
    static func allSteps(_ session: RoomWorkSession, record: [RoomWorkSession.Step]) -> [RoomWorkSession.Step] {
        guard !record.isEmpty, let start = session.startedAt else { return session.steps }
        let end = session.endedAt ?? .distantFuture
        let notes = Set(session.steps.map(\.text))
        let narration = record.filter { step in
            guard let at = step.at else { return false }
            return at >= start && at <= end && !notes.contains(step.text)
        }
        return (session.steps + narration).sorted { ($0.at ?? .distantPast, $0.id) < ($1.at ?? .distantPast, $1.id) }
    }
}

/// Senti preparing an answer (Carter, #61679, #61720): its avatar moving a little, and one of its thinking phrases at a
/// time, the next about every 2 s, until its message lands. VoiceOver reads "Senti is thinking", never each phrase.
struct SentiThinkingLine: View {
    @Environment(\.sentiPhrases) private var phrases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomIsCovered) private var roomIsCovered
    @Environment(\.scenePhase) private var scenePhase
    @State private var turn = 0
    /// Where in the phrases this answer starts, so two answers don't open alike.
    @State private var seed = Int.random(in: 0..<10_000)

    static let interval: TimeInterval = 2
    static let accessibilityText = "Senti is thinking"

    var body: some View {
        #if DEBUG
        let _ = RoomRenderProbe.note(RoomRenderProbe.sentiThinking)
        #endif
        let phrase = phrases.phrase(turn: turn, seed: seed)
        HStack(spacing: 8) {
            LayerMotion(.breathe) {
                RoomAvatar(name: "Senti", isHuman: false)
            }
            .frame(width: 26, height: 26)
            LayerMotion(.still, fadeKey: turn) {
                Text(phrase + "…")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText)
        .accessibilityIdentifier("pocket.room.sentiThinking")
        // The next phrase every 2 s while the room can be seen; nothing turns while it is covered or the app is away.
        .task(id: !roomIsCovered && scenePhase == .active) {
            guard !roomIsCovered, scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                turn += 1
            }
        }
    }
}

#if DEBUG
/// Counts how often a view's body runs, so a test can show that motion never redraws it frame by frame.
public enum RoomRenderProbe {
    public static let workingRows = "RoomWorkingRows"
    public static let sentiThinking = "SentiThinkingLine"

    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int] = [:]
    }

    private static let counts = Counts()

    static func note(_ name: String) {
        counts.lock.lock()
        counts.values[name, default: 0] += 1
        counts.lock.unlock()
    }

    public static func count(_ name: String) -> Int {
        counts.lock.lock()
        defer { counts.lock.unlock() }
        return counts.values[name] ?? 0
    }

    public static func reset() {
        counts.lock.lock()
        counts.values = [:]
        counts.lock.unlock()
    }

    #if os(iOS)
    /// Whether each view moved by Core Animation under `view` is moving now (`LayerMotion`).
    @MainActor
    public static func motions(in view: UIView) -> [Bool] {
        var found: [Bool] = []
        var pending = [view]
        while let next = pending.popLast() {
            if let moved = next as? LayerMotionView { found.append(moved.isMoving) }
            pending.append(contentsOf: next.subviews)
        }
        return found
    }
    #endif
}
#endif

private struct RoomBoxStepsKey: EnvironmentKey {
    static let defaultValue: [String: [RoomWorkSession.Step]] = [:]
}

extension EnvironmentValues {
    /// Steps read from boxes' own records while their Working rows are open, by lowercased name (the app sets them).
    public var roomBoxSteps: [String: [RoomWorkSession.Step]] {
        get { self[RoomBoxStepsKey.self] }
        set { self[RoomBoxStepsKey.self] = newValue }
    }
}
#endif
