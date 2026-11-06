#if canImport(SwiftUI)
import SwiftUI

public struct SessionCheckpointListView: View {
    /// Saved summaries, once "Room checkpoints" (Carter, 2026-11-06), in plain words that keep what each line
    /// promises: with a signing service, a summary's signature is checked before any of it shows; without one, it is
    /// shown as saved and never called checked (#266).
    static let exactCheckpointOpenHint =
        "Checks this summary's signature before showing any of it."
    static let trustBoundaryMessage =
        "You see these summaries because you're in this chat. Each one's signature is checked before any of it is shown."
    /// While this build verifies nothing, the list says what opening one does (#266).
    static let serverCheckpointOpenHint =
        "Opens this summary as it was saved. It isn't signed yet."
    static let serverTrustBoundaryMessage =
        "You see these summaries because you're in this chat. They aren't signed yet, so the app doesn't call them checked."

    private let state: SessionCheckpointListPresentationState
    private let verifies: Bool
    private let send: (PocketProductIntent) -> Void

    /// `verifies` is whether this build checks signed checkpoints; without it the list never promises verification.
    public init(
        state: SessionCheckpointListPresentationState,
        verifies: Bool = true,
        send: @escaping (PocketProductIntent) -> Void
    ) {
        self.state = state
        self.verifies = verifies
        self.send = send
    }

    public var body: some View {
        Group {
            if state.rows.isEmpty {
                emptyOrFailure
            } else {
                checkpointList
            }
        }
        .navigationTitle("Saved summaries")
        .accessibilityIdentifier("pocket.session-checkpoints.screen")
        .pocketCanvas()
    }

    private var checkpointList: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: state.provenance)
                trustBoundaryNotice
            }
            .listRowBackground(PocketPalette.raised)

            if let failure = state.failure {
                Section {
                    Label(failure.detail, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
                .listRowBackground(PocketPalette.raised)
            }

            Section("Summaries") {
                ForEach(state.rows) { row in
                    Button {
                        send(.openCheckpoint(sessionId: row.sessionId, checkpointId: row.checkpointId))
                    } label: {
                        SessionCheckpointRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(checkpointAccessibilityID(row))
                    .accessibilityHint(verifies ? Self.exactCheckpointOpenHint : Self.serverCheckpointOpenHint)
                    .listRowBackground(PocketPalette.raised)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { send(.refreshCheckpoints(sessionId: state.sessionId)) }
        .overlay {
            if state.isRefreshing {
                ProgressView("Loading")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pocket.session-checkpoints.refreshing")
            }
        }
    }

    private var emptyOrFailure: some View {
        ScrollView {
            VStack(spacing: 16) {
                SessionProvenanceBanner(provenance: state.provenance)

                Image(systemName: state.failure == nil ? "tray.full" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)

                Text(state.failure?.title ?? "No saved summaries yet")
                    .font(.title2.bold())
                Text(state.failure?.detail ?? "Summaries saved in this chat show up here.")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                trustBoundaryNotice

                Button("Try again") {
                    send(.refreshCheckpoints(sessionId: state.sessionId))
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.accent)
                .accessibilityIdentifier("pocket.session-checkpoints.retry")
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var trustBoundaryNotice: some View {
        Label {
            Text(verifies ? Self.trustBoundaryMessage : Self.serverTrustBoundaryMessage)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "person.2")
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .foregroundStyle(PocketPalette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.session-checkpoints.trust-notice")
    }

    private func checkpointAccessibilityID(_ row: SessionCheckpointRowPresentation) -> String {
        let session = row.sessionId
        let checkpoint = row.checkpointId
        return "pocket.session-checkpoints.row.\(session.utf8.count):\(session).\(checkpoint.utf8.count):\(checkpoint)"
    }
}

private struct SessionCheckpointRow: View {
    let row: SessionCheckpointRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 10)
                    kind
                }
                VStack(alignment: .leading, spacing: 5) {
                    title
                    kind
                }
            }

            if let summary = row.summary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(4)
            }

            grade

            ViewThatFits(in: .horizontal) {
                HStack {
                    creator
                    Spacer(minLength: 8)
                    timestamp
                }
                VStack(alignment: .leading, spacing: 5) {
                    creator
                    timestamp
                }
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)

            Text(row.trustNotice)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text(row.title)
            .font(.headline)
            .foregroundStyle(PocketPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var kind: some View {
        Text(row.kindLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketPalette.accent)
    }

    private var grade: some View {
        Label(row.gradeLabel, systemImage: "chart.bar.doc.horizontal")
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
    }

    private var creator: some View {
        Text("Saved by \(row.createdBy)")
    }

    /// When it was saved: "3h ago", "just now"; nothing rather than the server's text when the phone cannot read it.
    @ViewBuilder
    private var timestamp: some View {
        if let date = row.createdAt.date {
            AgoText(date: date)
        }
    }
}
#endif
