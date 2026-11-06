#if canImport(SwiftUI)
import SwiftUI
import PocketContracts   // ParsedSessionTimestamp (SessionAtlasTypes) — SessionActionRowPresentation.timestamp

public struct SessionActivityView: View {
    private let state: SessionActivityPresentationState
    private let send: (PocketProductIntent) -> Void

    public init(state: SessionActivityPresentationState, send: @escaping (PocketProductIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        Group {
            if state.events.isEmpty && state.actions.isEmpty {
                emptyOrFailure
            } else {
                activityList
            }
        }
        .navigationTitle("Activity")
        .accessibilityIdentifier("pocket.activity.screen")
        .pocketCanvas()
    }

    private var activityList: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: state.provenance)
            }
            .listRowBackground(PocketPalette.raised)

            if let failure = state.failure {
                Section {
                    Text(failure.detail)
                        .foregroundStyle(PocketPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }

            if !state.events.isEmpty {
                Section("Messages") {
                    ForEach(state.events) { event in
                        Button {
                            send(.openEvent(sessionId: event.sessionId, sequenceId: event.sequenceId))
                        } label: {
                            EventRow(event: event)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(activityAccessibilityID(
                            kind: "event",
                            sessionId: event.sessionId,
                            value: String(event.sequenceId)
                        ))
                        .listRowBackground(PocketPalette.raised)
                    }
                }
            }

            if !state.actions.isEmpty {
                Section("Reactions") {
                    ForEach(state.actions) { action in
                        Button {
                            send(.openAction(sessionId: action.sessionId, actionId: action.id.actionId))
                        } label: {
                            ActionRow(action: action)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(activityAccessibilityID(
                            kind: "action",
                            sessionId: action.sessionId,
                            value: action.id.actionId
                        ))
                        .listRowBackground(PocketPalette.raised)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { send(.refreshActivity(sessionId: state.sessionId)) }
        .overlay {
            if state.isRefreshing {
                ProgressView("Loading")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var emptyOrFailure: some View {
        ScrollView {
            VStack(spacing: 16) {
                SessionProvenanceBanner(provenance: state.provenance)
                Image(systemName: state.failure == nil ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)
                Text(state.failure?.title ?? "No activity yet")
                    .font(.title2.bold())
                Text(state.failure?.detail ?? "Messages and reactions in this chat show up here.")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { send(.refreshActivity(sessionId: state.sessionId)) }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.accent)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func activityAccessibilityID(kind: String, sessionId: String, value: String) -> String {
        "pocket.activity.\(kind).\(sessionId.utf8.count):\(sessionId).\(value.utf8.count):\(value)"
    }
}

private struct EventRow: View {
    let event: SessionEventRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            author
            Text(event.eventTypeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.accent)
            if let text = event.text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(5)
            }
            TimestampText(timestamp: event.timestamp)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var author: some View {
        Text(event.author).font(.headline)
    }
}

private struct ActionRow: View {
    let action: SessionActionRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    actorLabel
                    Spacer(minLength: 10)
                    target
                }
                VStack(alignment: .leading, spacing: 4) {
                    actorLabel
                    target
                }
            }
            Text(action.actionTypeLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PocketPalette.accent)
            if let note = action.note {
                Text(note)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TimestampText(timestamp: action.createdAt)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var actorLabel: some View {
        Text(action.actor).font(.headline)   // `action.actor` is a String field (fine); the bare `actor` VIEW property collided with Swift's contextual keyword
    }

    private var target: some View {
        Text(action.targetLabel)
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
    }
}

/// When it happened: "42m ago", "just now". A time the phone cannot read shows nothing rather than the server's text.
private struct TimestampText: View {
    let timestamp: ParsedSessionTimestamp

    var body: some View {
        Group {
            if let date = timestamp.date {
                AgoText(date: date)
            }
        }
        .font(.caption)
        .foregroundStyle(PocketPalette.textSecondary)
    }
}
#endif
