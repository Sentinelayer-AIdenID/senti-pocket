import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Where a call's sound goes, as the person chose it (ticket b21646d8: calls were stuck on the loudspeaker).
public enum CallAudioRoute: String, Equatable, Sendable, CaseIterable {
    /// Chosen by the phone: the earpiece while the phone is held to the ear, the speaker otherwise.
    case automatic
    case speaker
    /// The phone's earpiece.
    case iPhone
}

/// The phone's own output a call is put on.
public enum CallAudioOutput: Equatable, Sendable {
    case speaker
    case iPhone
}

public enum CallAudioRouting {
    /// The phone's own output for a call, or nil to leave it to the system: headphones and Bluetooth take over the moment
    /// they connect, and the call goes back to the phone when they leave.
    ///
    /// Automatic is the speaker unless the phone is held to the ear: calls with agents are often taken looking at the
    /// screen, and held to the ear a call should sound like a phone call.
    public static func output(for route: CallAudioRoute, nearEar: Bool, external: Bool) -> CallAudioOutput? {
        if external { return nil }
        switch route {
        case .speaker: return .speaker
        case .iPhone: return .iPhone
        case .automatic: return nearEar ? .iPhone : .speaker
        }
    }

    #if os(iOS)
    /// Every call's session options: Bluetooth headsets, and never `.defaultToSpeaker`, which kept every call on the
    /// loudspeaker whatever the person wanted. The speaker is chosen per call (`output(for:nearEar:external:)`).
    public static let sessionOptions: AVAudioSession.CategoryOptions = [.allowBluetooth]

    /// The route plays somewhere other than the phone's own speaker and earpiece: headphones, a Bluetooth device, a car.
    public static func routesExternally(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
    }
    #endif
}
