#if canImport(SwiftUI)
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Senti web's colour themes (sentinelayer-web `src/styles/globals.css`, `:root` and `.dark`), as HSL pairs that
/// follow the phone's light or dark appearance, so the app and the web look like one product.
enum PocketPalette {
    /// Page background: warm off-white in light, deep navy in dark.
    static let canvas = themed(light: (32, 40, 97), dark: (222, 24, 8))
    /// Cards, sheets and the composer field.
    static let raised = themed(light: (0, 0, 100), dark: (222, 22, 11))
    /// Wells inside a card (the web's muted).
    static let inset = themed(light: (210, 16, 92), dark: (217, 18, 16))
    static let separator = themed(light: (215, 20, 86), dark: (217, 16, 22))

    // Action and conversational state colours. Green is deliberately absent from actions:
    // it is reserved for verified cryptographic state and signed receipts.
    /// Senti orange (the web's primary): buttons, links, the send arrow, mentions.
    static let accent = themed(light: (18, 90, 55), dark: (18, 92, 62))
    /// A deeper orange for text on light tints, where the primary is too light to read.
    static let accentStrong = themed(light: (18, 90, 43), dark: (18, 90, 62))
    /// Senti teal (the web's accent): listening, live and secondary highlights.
    static let listening = themed(light: (189, 70, 40), dark: (189, 70, 45))
    static let verified = themed(light: (146, 62, 38), dark: (146, 62, 45))
    static let warning = themed(light: (38, 92, 50), dark: (38, 92, 55))
    static let danger = themed(light: (0, 84, 60), dark: (0, 84, 64))
    static let recording = Color(red: 0.72, green: 0.08, blue: 0.10)

    // Epistemic categories are not trust verdicts.
    static let fact = Color.secondary
    static let inference = themed(light: (189, 70, 40), dark: (189, 70, 52))
    static let recommendation = Color.purple

    static let textPrimary = themed(light: (222, 47, 11), dark: (32, 20, 94))
    static let textSecondary = themed(light: (215, 25, 32), dark: (215, 20, 70))

    // Message bubbles, by who wrote them (the web's bubble tints).
    static let humanBubble = themed(light: (30, 60, 94.5), dark: (28, 22, 12))
    static let agentBubble = themed(light: (0, 0, 100), dark: (222, 22, 11))
    static let ticketerBubble = themed(light: (262, 45, 96.5), dark: (262, 18, 12.5))
    static let orchestratorBubble = themed(light: (178, 38, 95), dark: (178, 20, 11))

    /// One colour per appearance from HSL (hue in degrees, saturation and lightness in percent).
    static func themed(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let (h, s, l) = traits.userInterfaceStyle == .dark ? dark : light
            let rgb = rgb(hue: h, saturation: s, lightness: l)
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        let rgb = rgb(hue: light.0, saturation: light.1, lightness: light.2)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        #endif
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let s = saturation / 100
        let l = lightness / 100
        let chroma = (1 - abs(2 * l - 1)) * s
        let sector = (hue.truncatingRemainder(dividingBy: 360)) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0..<1: (r, g, b) = (chroma, x, 0)
        case 1..<2: (r, g, b) = (x, chroma, 0)
        case 2..<3: (r, g, b) = (0, chroma, x)
        case 3..<4: (r, g, b) = (0, x, chroma)
        case 4..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = l - chroma / 2
        return (r + m, g + m, b + m)
    }
}

struct PocketCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.72), lineWidth: 0.5)
            }
    }
}

extension View {
    func pocketCard() -> some View {
        modifier(PocketCardModifier())
    }

    func pocketCanvas() -> some View {
        background(PocketPalette.canvas.ignoresSafeArea())
    }
}
#endif
