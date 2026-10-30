#if canImport(SwiftUI)
import SwiftUI

/// Whom to talk with (Carter, 10-30: pick several agents): tick one or more and call them together, or call everyone
/// here as a meeting. With more than one agent, the first to answer each turn has the floor.
public struct VoiceCallPicker: View {
    private let partners: [String]
    private let onCall: ([String]) -> Void
    private let onCancel: () -> Void
    @State private var pick = VoiceCallPick()

    /// `partners` is whom the call can ring now; `onCall` gets the agents ticked, or none for a meeting with everyone.
    public init(partners: [String], onCall: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.partners = partners
        self.onCall = onCall
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if partners.isEmpty {
                        Text("No agent here can answer right now.")
                            .foregroundStyle(PocketPalette.textSecondary)
                            .accessibilityIdentifier("pocket.voice.pick.none")
                    }
                    ForEach(partners, id: \.self) { agent in
                        row(agent)
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("You talk; they answer in the room and the phone reads each answer in that agent's voice. The whole conversation stays in the room as the call's card.")
                }
                .listRowBackground(PocketPalette.raised)

                Section {
                    Button { onCall(pick.agents(of: partners)) } label: {
                        Label(pick.callTitle(of: partners), systemImage: "phone.fill")
                            .font(.headline)
                    }
                    .disabled(pick.agents(of: partners).isEmpty)
                    .accessibilityIdentifier("pocket.voice.pick.call")
                    Button { onCall([]) } label: {
                        Label("Everyone (a meeting)", systemImage: "person.3")
                    }
                    .accessibilityIdentifier("pocket.voice.pick.everyone")
                }
                .listRowBackground(PocketPalette.raised)
            }
            .scrollContentBackground(.hidden)
            .pocketCanvas()
            .navigationTitle("Talk with")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .accessibilityIdentifier("pocket.voice.picker")
    }

    private func row(_ agent: String) -> some View {
        let picked = pick.isPicked(agent)
        return Button { pick.toggle(agent) } label: {
            HStack(spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? PocketPalette.accent : PocketPalette.textSecondary)
                Text(agent)
                    .foregroundStyle(PocketPalette.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("pocket.voice.pick.\(agent)")
    }
}
#endif
