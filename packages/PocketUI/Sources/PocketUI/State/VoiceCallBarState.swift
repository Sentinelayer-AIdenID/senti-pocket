import Foundation

/// What the bar of a minimized call shows (`VoiceCallBar`): who the call is with, its time, and whether you are muted.
/// Minimizing hides only the call screen; the call goes on, and this bar is how you reach it.
public struct VoiceCallBarState: Equatable, Sendable {
    /// "forge", "forge and ada", or "everyone", as the call screen says it.
    public var title: String
    public var startedAt: Date
    /// Nobody has picked up yet.
    public var isRinging: Bool
    public var isMuted: Bool
    /// The call is hanging up: its buttons ask nothing more of it.
    public var isEnding: Bool

    public init(title: String, startedAt: Date, isRinging: Bool = false, isMuted: Bool = false,
                isEnding: Bool = false) {
        self.title = title
        self.startedAt = startedAt
        self.isRinging = isRinging
        self.isMuted = isMuted
        self.isEnding = isEnding
    }

    /// A voice room's bar, from what its call screen shows.
    public init(_ call: VoiceRoomState) {
        self.init(title: call.title, startedAt: call.startedAt, isRinging: call.isRinging, isMuted: call.isMuted,
                  isEnding: call.phase == .ending || call.phase == .ended)
    }

    /// Minutes and seconds since the call started ("2:31"), as the call screen's clock shows them.
    public static func clock(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The time on the bar: the call's clock, or what the call is doing before it has one.
    public func time(at now: Date) -> String {
        if isEnding { return "Ending…" }
        if isRinging { return "Ringing…" }
        return Self.clock(from: startedAt, to: now)
    }

    /// What VoiceOver reads for the bar: "Call with forge, 2:31", and ", muted" while you are muted.
    public func spokenLabel(at now: Date) -> String {
        let time = isEnding ? "ending" : isRinging ? "ringing" : Self.clock(from: startedAt, to: now)
        return "Call with \(title), \(time)" + (isMuted ? ", muted" : "")
    }

    /// What the bar's Mute button says, as the call screen's does.
    public var muteLabel: String { isMuted ? "Unmute" : "Mute" }

    /// What a tap on the bar asks of the call: Mute and End, as on the call screen. A tap on the rest of the bar opens
    /// the call screen and asks the call nothing, and nothing is asked of a call already hanging up.
    public func intent(for action: VoiceCallBarAction) -> VoiceRoomIntent? {
        guard !isEnding else { return nil }
        switch action {
        case .open: return nil
        case .toggleMute: return .setMuted(!isMuted)
        case .end: return .hangUp
        }
    }
}

public enum VoiceCallBarAction: Equatable, Sendable {
    /// Bring the call screen back.
    case open
    case toggleMute
    case end
}
