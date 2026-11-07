import AVFoundation
import AVKit
import Combine
import PocketUI
import PocketVoice
import SwiftUI
import UIKit

/// Where a call's sound goes while a call is on (ticket b21646d8: calls were stuck on the loudspeaker). Automatic puts it
/// on the earpiece while the phone is held to the ear and on the speaker otherwise; the person can pick the speaker or
/// the earpiece instead, from the call screen. Headphones and Bluetooth take over the moment they connect, and the call
/// goes back to the phone when they leave. An agent's spoken answers play on the call's session, so they follow it.
@MainActor
final class CallAudioRouter: ObservableObject {
    static let shared = CallAudioRouter()

    @Published private(set) var route: CallAudioRoute = .automatic
    /// What plays the call now, as the phone names it: "Speaker", "iPhone", or the headphones' or device's own name.
    @Published private(set) var outputName = "Speaker"
    /// Headphones, a Bluetooth device or a car play the call.
    @Published private(set) var external = false

    private var isOn = false
    private var nearEar = false
    private var observers: [NSObjectProtocol] = []
    private var calls: AnyCancellable?

    /// Follows the calls the app knows of (`CallPresence`): on while one is.
    func followCalls(_ presence: CallPresence = .shared) {
        guard calls == nil else { return }
        calls = presence.$isOn.removeDuplicates().sink { [weak self] on in self?.setCall(on: on) }
    }

    /// The person's pick, from the call screen.
    func choose(_ route: CallAudioRoute) {
        self.route = route
        apply()
    }

    private func setCall(on: Bool) {
        guard on != isOn else { return }
        isOn = on
        let device = UIDevice.current
        if on {
            // Each call starts automatic: the speaker, or the earpiece at the ear.
            route = .automatic
            device.isProximityMonitoringEnabled = true
            nearEar = device.proximityState
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in
                        CallAudioRouter.shared.nearEar = UIDevice.current.proximityState
                        CallAudioRouter.shared.apply()
                    }
                },
                // Headphones in or out, a category set, an override made: where it plays is looked at again.
                center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor in CallAudioRouter.shared.apply() }
                }
            ]
            apply()
        } else {
            device.isProximityMonitoringEnabled = false
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    /// Puts the call's sound where it should be, if it is not there already (an override made again would only post
    /// another route change).
    func apply() {
        guard isOn else { return }
        let session = AVAudioSession.sharedInstance()
        let current = session.currentRoute
        external = CallAudioRouting.routesExternally(current)
        if let output = CallAudioRouting.output(for: route, nearEar: nearEar, external: external) {
            let onSpeaker = current.outputs.contains { $0.portType == .builtInSpeaker }
            if (output == .speaker) != onSpeaker {
                try? session.overrideOutputAudioPort(output == .speaker ? .speaker : .none)
            }
        }
        outputName = Self.name(of: session.currentRoute)
    }

    static func name(of route: AVAudioSessionRouteDescription) -> String {
        guard let output = route.outputs.first else { return "Speaker" }
        switch output.portType {
        case .builtInSpeaker: return "Speaker"
        case .builtInReceiver: return "iPhone"
        default: return output.portName
        }
    }
}

/// The call screen's sound control: Speaker, iPhone (the earpiece) or Automatic, and the system's own picker for
/// headphones, Bluetooth and AirPlay.
struct CallAudioRouteControl: View {
    @ObservedObject var router: CallAudioRouter = .shared

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(CallAudioRoute.allCases, id: \.self) { route in
                    Button {
                        router.choose(route)
                    } label: {
                        if router.route == route {
                            Label(Self.title(route), systemImage: "checkmark")
                        } else {
                            Text(Self.title(route))
                        }
                    }
                }
            } label: {
                Label(router.outputName, systemImage: router.external ? "headphones" : router.outputName == "iPhone"
                      ? "iphone" : "speaker.wave.2.fill")
                    .font(.caption2)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Sound: \(router.outputName)")
            .accessibilityHint("Choose the speaker or the iPhone's earpiece")
            .accessibilityIdentifier("pocket.voice.audioRoute")
            CallRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Other speakers and headphones")
                .accessibilityIdentifier("pocket.voice.audioRoutePicker")
        }
    }

    static func title(_ route: CallAudioRoute) -> String {
        switch route {
        case .automatic: return "Automatic (iPhone at your ear)"
        case .speaker: return "Speaker"
        case .iPhone: return "iPhone"
        }
    }
}

/// The system's route picker: headphones, Bluetooth and AirPlay devices.
private struct CallRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
