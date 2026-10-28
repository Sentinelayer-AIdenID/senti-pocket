#if canImport(SwiftUI)
import SwiftUI

/// Agents asking to join the room. The owner can only NARROW what an agent asked for: drop actions, or pick a
/// shorter duration. The agent's goal is its own words and is labelled as such.
public struct AdmissionsView: View {
    private let state: AdmissionsPresentationState
    private let send: (AdmissionsIntent) -> Void

    public init(state: AdmissionsPresentationState, send: @escaping (AdmissionsIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        List {
            if let failure = state.failure {
                Text(failure.detail).foregroundStyle(PocketPalette.warning)
            }
            if let error = state.errorText {
                Text(error).font(.footnote).foregroundStyle(PocketPalette.danger)
            }
            Section("Waiting for you") {
                if state.pending.isEmpty {
                    Text(state.isLoading ? "Loading…" : "No agents are waiting.")
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                ForEach(state.pending) { row in
                    AdmissionRequestCard(row: row, isDeciding: state.deciding.contains(row.id), send: send)
                }
            }
            if !state.live.isEmpty {
                Section("Admitted") {
                    ForEach(state.live) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.agentId).font(.body.weight(.semibold))
                            Text(row.grantedActions.map(AdmissionRow.actionLabel).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(PocketPalette.textSecondary)
                            if let expires = row.grantedExpires {
                                (Text("Expires ") + Text(expires, format: .relative(presentation: .named, unitsStyle: .wide)))
                                    .font(.caption)
                                    .foregroundStyle(PocketPalette.textSecondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text(state.mode == "required"
                    ? "This room requires agents to be admitted before they act."
                    : "This room still accepts agents posting under your account without a request.")
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .refreshable { send(.refresh) }
        .navigationTitle("Agent requests")
        .accessibilityIdentifier("pocket.admissions.screen")
    }
}

private struct AdmissionRequestCard: View {
    let row: AdmissionRow
    let isDeciding: Bool
    let send: (AdmissionsIntent) -> Void

    @State private var selectedActions: Set<String>
    @State private var ttlSeconds: Int

    init(row: AdmissionRow, isDeciding: Bool, send: @escaping (AdmissionsIntent) -> Void) {
        self.row = row
        self.isDeciding = isDeciding
        self.send = send
        _selectedActions = State(initialValue: Set(row.requestedActions))
        _ttlSeconds = State(initialValue: row.requestedTTLSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agentId).font(.headline)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(PocketPalette.textSecondary)
                }
            }
            if !row.goalSummary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In the agent's words")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PocketPalette.warning)
                    Text(row.goalSummary).font(.subheadline)
                    ForEach(row.deliverables, id: \.self) { item in
                        Label(item, systemImage: "shippingbox").font(.caption)
                    }
                    ForEach(row.stopConditions, id: \.self) { item in
                        Label(item, systemImage: "stop.circle").font(.caption)
                    }
                }
                .padding(8)
                .background(PocketPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow").font(.caption.weight(.semibold)).foregroundStyle(PocketPalette.textSecondary)
                ForEach(row.requestedActions, id: \.self) { action in
                    Toggle(AdmissionRow.actionLabel(action), isOn: Binding(
                        get: { selectedActions.contains(action) },
                        set: { on in if on { selectedActions.insert(action) } else { selectedActions.remove(action) } }
                    ))
                    .font(.subheadline)
                }
            }
            let ttlOptions = AdmissionRow.ttlOptions(forRequested: row.requestedTTLSeconds)
            if !ttlOptions.isEmpty {
                Picker("For", selection: $ttlSeconds) {
                    ForEach(ttlOptions, id: \.self) { option in
                        Text(AdmissionRow.durationLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                Button(role: .destructive) {
                    send(.deny(id: row.id))
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    send(.approve(
                        id: row.id,
                        actions: row.requestedActions.filter(selectedActions.contains),
                        ttlSeconds: row.grantedTTL(choosing: ttlSeconds)
                    ))
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.accent)
                .disabled(selectedActions.isEmpty)
            }
            .disabled(isDeciding)
            if isDeciding {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("pocket.admissions.request.\(row.id)")
    }
}

#endif
