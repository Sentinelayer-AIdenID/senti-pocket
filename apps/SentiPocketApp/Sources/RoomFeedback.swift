import AudioToolbox
import Foundation
import SwiftUI
import UIKit

/// What an open room tells the phone to sound and vibrate for.
enum RoomFeedbackEvent: Hashable, Sendable {
    /// Your message reached the room.
    case sent
    /// Someone else posted or replied in the room on screen.
    case received
    /// Someone mentioned you (or @all) in the room on screen.
    case mentioned
}

/// The sounds and taps of the room on screen, as in WhatsApp: a soft swish when your message is sent, a soft pop
/// when a message arrives, and the web's chime with a stronger tap when it mentions you. The sounds are system
/// sounds, so the silent switch silences them; the taps are haptics, which still play on silent. A burst of messages
/// sounds once. Each can be switched off in Settings.
@MainActor
final class RoomFeedback {
    static let shared = RoomFeedback()

    @AppStorage("pocket.inapp.sounds") var sounds = true
    @AppStorage("pocket.inapp.haptics") var haptics = true

    private var soundIds: [RoomFeedbackEvent: SystemSoundID] = [:]
    private var lastPlayed: [RoomFeedbackEvent: Date] = [:]

    /// The least time between two of the same, so a burst sounds once.
    static func spacing(_ event: RoomFeedbackEvent) -> TimeInterval {
        switch event {
        case .sent: return 0.25
        case .received: return 1.5
        case .mentioned: return 3
        }
    }

    static func shouldPlay(_ event: RoomFeedbackEvent, last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= spacing(event)
    }

    func play(_ event: RoomFeedbackEvent, now: Date = Date()) {
        guard Self.shouldPlay(event, last: lastPlayed[event], now: now) else { return }
        lastPlayed[event] = now
        if sounds, let id = soundId(for: event) { AudioServicesPlaySystemSound(id) }
        guard haptics else { return }
        switch event {
        case .sent:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .received:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .mentioned:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func soundId(for event: RoomFeedbackEvent) -> SystemSoundID? {
        if let id = soundIds[event] { return id }
        let name: String
        switch event {
        case .sent: name = "send"
        case .received: name = "receive"
        case .mentioned: name = "chime"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        soundIds[event] = id
        return id
    }
}
