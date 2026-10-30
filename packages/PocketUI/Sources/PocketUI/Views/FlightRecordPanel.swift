#if canImport(SwiftUI)
import SwiftUI

/// The Flight record, from the right: who is working on what in the room, live. Each box shows what it is doing now
/// in one line; tap it to see its thoughts and commands, newest first.
public struct FlightRecordPanel: View {
    private let state: FlightRecordState
    private let onClose: () -> Void
    private let onExpand: (String?) -> Void
    private let onOpenConsole: (URL) -> Void
    @State private var expanded: String?

    public init(
        state: FlightRecordState,
        onClose: @escaping () -> Void,
        onExpand: @escaping (String?) -> Void = { _ in },
        onOpenConsole: @escaping (URL) -> Void = { _ in }
    ) {
        self.state = state
        self.onClose = onClose
        self.onExpand = onExpand
        self.onOpenConsole = onOpenConsole
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flight record")
                        .font(.title3.bold())
                        .foregroundStyle(PocketPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the flight record")
                .accessibilityIdentifier("pocket.flight.close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let totals = state.totals {
                        FlightTotalsCard(totals: totals)
                            .padding(.horizontal, 12)
                    }
                    if let failure = state.failure, state.boxes.isEmpty {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.warning)
                            .padding(.horizontal, 18)
                    }
                    if state.isLoading && state.boxes.isEmpty {
                        ProgressView("Loading the flight record")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    if !state.boxes.isEmpty {
                        sectionTitle("Boxes")
                        ForEach(state.boxes) { box in boxRow(box) }
                    }
                    if !state.agents.isEmpty {
                        sectionTitle("Agents")
                        ForEach(state.agents) { agent in agentRow(agent) }
                    }
                    if !state.isLoading, state.boxes.isEmpty, state.agents.isEmpty, state.failure == nil {
                        Text("Nobody is working in this room right now.")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PocketPalette.canvas.ignoresSafeArea())
        // A grabber on the edge it closes toward: swipe right to put it away.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(PocketPalette.separator)
                .frame(width: 4, height: 36)
                .padding(.leading, 5)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.flight")
    }

    private var summary: String {
        let working = state.boxes.filter(\.isWorking).count
        var parts = ["\(state.boxes.count) \(state.boxes.count == 1 ? "box" : "boxes")"]
        if working > 0 { parts.append("\(working) working now") }
        if state.finishedBoxes > 0 { parts.append("\(state.finishedBoxes) finished") }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
            .padding(.horizontal, 18)
            .padding(.top, 4)
    }

    private func boxRow(_ box: FlightRecordState.Box) -> some View {
        let isOpen = expanded == box.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = isOpen ? nil : box.id }
                onExpand(isOpen ? nil : box.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoomAvatar(name: box.name, isHuman: false)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(box.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PocketPalette.textPrimary)
                                .lineLimit(1)
                            PhaseBadge(phase: box.phase, isWorking: box.isWorking)
                            Spacer(minLength: 0)
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PocketPalette.textSecondary)
                        }
                        if let job = box.job {
                            Text(job)
                                .font(.caption)
                                .foregroundStyle(PocketPalette.textSecondary)
                                .lineLimit(isOpen ? 3 : 1)
                        }
                        if let current = box.doneSummary ?? box.current {
                            LiveLine(text: current, isLive: box.isWorking && box.doneSummary == nil)
                        }
                        meta(box)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(box.name), \(box.phase). \(box.current ?? "")")
            .accessibilityHint(isOpen ? "Hides its steps" : "Shows what it is thinking and doing")
            .accessibilityIdentifier("pocket.flight.box.\(box.id)")

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(box.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: symbol(line))
                                .font(.caption)
                                .foregroundStyle(tint(line))
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text(line.text)
                                .font(line.isCommand ? .caption.monospaced() : .caption)
                                .foregroundStyle(line.isCommand ? PocketPalette.textSecondary : PocketPalette.textPrimary)
                                // Commands stay scannable; thoughts read in full up to a few lines.
                                .lineLimit(line.isCommand ? 2 : 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if box.lines.isEmpty {
                        Text("No steps recorded yet.")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    if let url = box.consoleURL {
                        Button {
                            onOpenConsole(url)
                        } label: {
                            Label("Open its console", systemImage: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PocketPalette.accentStrong)
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 36)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func meta(_ box: FlightRecordState.Box) -> some View {
        HStack(spacing: 8) {
            if !box.model.isEmpty { Text(box.model) }
            if let last = box.lastActivity {
                let age = PocketSidePanel.compactAge(of: last)
                Text(age == "now" ? "active now" : "active \(age) ago")
            }
            if let ends = box.expiresAt, ends > Date() { Text("ends in \(PocketSidePanel.compactAge(of: Date(), now: ends))") }
            if box.posts > 0 { Text("\(box.posts) posts") }
        }
        .font(.caption2)
        .foregroundStyle(PocketPalette.textSecondary)
        .lineLimit(1)
    }

    private func agentRow(_ agent: FlightRecordState.Agent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoomAvatar(name: agent.id, isHuman: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.id)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                    if agent.isHere {
                        Circle()
                            .fill(agent.isIdle ? PocketPalette.warning : PocketPalette.listening)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(agent.isIdle ? "idle" : "here")
                    }
                }
                if let status = agent.status {
                    LiveLine(text: status, isLive: !status.lowercased().hasPrefix("done"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ line: FlightRecordState.Line) -> String {
        guard line.isCommand else { return "text.bubble" }
        switch line.tone {
        case .ok: return "checkmark.circle"
        case .fail: return "xmark.circle"
        case .neutral: return "terminal"
        }
    }

    private func tint(_ line: FlightRecordState.Line) -> Color {
        switch line.tone {
        case .ok: return PocketPalette.listening
        case .fail: return PocketPalette.danger
        case .neutral: return PocketPalette.textSecondary
        }
    }
}

/// The room's figures in two rows of three, as the web's Flight record shows them, dense and in aligned numbers that
/// do not jitter as they count (Carter, #55014): minted, active, finished; hours worked, days saved, cost.
struct FlightTotalsCard: View {
    let totals: FlightRecordState.Totals

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        LazyVGrid(columns: columns, spacing: 6) {
            tile(count(totals.minted), label: "Minted")
            tile(count(totals.active), label: "Active")
            tile(count(totals.finished), label: "Finished")
            tile(worked, label: workedLabel)
            tile(saved, label: "Saved vs 1 engineer")
            tile(cost, label: costLabel)
        }
        .padding(8)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PocketPalette.separator.opacity(0.7), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Room totals")
        .accessibilityIdentifier("pocket.flight.totals")
    }

    private func count(_ value: Int) -> String { (totals.isMinimum ? "≥" : "") + "\(value)" }

    private var worked: String {
        guard let hours = totals.workedHours else { return "—" }
        return FlightRecordState.Totals.shown(hours, isMinimum: totals.workIsMinimum) + " h"
    }

    private var workedLabel: String {
        guard let hours = totals.workedHours else { return "Worked" }
        let days = hours / 24
        return "Worked · \(FlightRecordState.Totals.shown(days, isMinimum: totals.workIsMinimum)) \(FlightRecordState.Totals.dayUnit(days))"
    }

    private var saved: String {
        guard totals.workedHours != nil, let days = totals.savedDays else { return "—" }
        return "\(FlightRecordState.Totals.shown(days, isMinimum: totals.workIsMinimum)) \(FlightRecordState.Totals.dayUnit(days))"
    }

    private var cost: String {
        guard let usd = totals.costUsd else { return "—" }
        return (totals.isMinimum ? "≥" : "") + FlightRecordState.Totals.usd(usd)
    }

    private var costLabel: String {
        guard let percent = totals.costPercent else { return "Cost" }
        return "Cost · \(FlightRecordState.Totals.amount(percent))% of $80/h"
    }

    private func tile(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .tracking(-0.3)
                .monospacedDigit()
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(PocketPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(PocketPalette.inset.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A phase as a small coloured label: teal while working, orange when waiting, grey when done.
private struct PhaseBadge: View {
    let phase: String
    let isWorking: Bool

    var body: some View {
        Text(phase.isEmpty ? "unknown" : phase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isWorking ? PocketPalette.listening : PocketPalette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isWorking ? PocketPalette.listening : PocketPalette.textSecondary).opacity(0.12), in: Capsule())
    }
}

/// One live line: what an agent is doing now. It shimmers while the work is live (Reduce Motion keeps it still).
struct LiveLine: View {
    let text: String
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isLive {
                Circle()
                    .fill(PocketPalette.listening)
                    .frame(width: 6, height: 6)
                    .opacity(reduceMotion ? 1 : (phase > 0 ? 0.35 : 1))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(2)
        }
        .onAppear {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }
}
#endif
