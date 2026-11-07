#if canImport(SwiftUI)
import SwiftUI

/// A minimized call: one thin floating bar with who the call is with and its time (a tap brings the call screen back),
/// Mute and End. The call goes on underneath while you read, scroll, open threads and type. VoiceOver reads the bar as
/// "Call with forge, 2:31", then Mute (or Unmute) and End call, each at least 44 pt.
public struct VoiceCallBar: View {
    private let state: VoiceCallBarState
    private let send: (VoiceCallBarAction) -> Void

    public init(state: VoiceCallBarState, send: @escaping (VoiceCallBarAction) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
            HStack(spacing: 2) {
                Button {
                    send(.open)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.listening)
                        Text(state.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(state.time(at: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.spokenLabel(at: context.date))
                .accessibilityHint("Opens the call screen")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("pocket.callBar.open")
                muteButton
                endButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
        }
        // Its text stops growing at the largest standard size, so it stays one thin line with its buttons on the
        // screen; VoiceOver still reads the whole name and time.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .pocketFloating(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.callBar")
    }

    /// As on the call screen: a crossed-out mic, filled while muted.
    private var muteButton: some View {
        Button { send(.toggleMute) } label: {
            Image(systemName: "mic.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state.isMuted ? PocketPalette.canvas : PocketPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(state.isMuted ? PocketPalette.textPrimary : PocketPalette.inset, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isEnding)
        .accessibilityLabel(state.muteLabel)
        .accessibilityIdentifier("pocket.callBar.mute")
    }

    private var endButton: some View {
        Button { send(.end) } label: {
            Image(systemName: "phone.down.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(PocketPalette.danger, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isEnding)
        .accessibilityLabel("End call")
        .accessibilityIdentifier("pocket.callBar.end")
    }
}
#endif
