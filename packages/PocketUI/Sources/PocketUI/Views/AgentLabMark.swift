import SwiftUI

/// A lab's mark in the lab's colour, solid, in a square of `size` points: its logo where the app carries one, else its
/// initial, else a chip for a lab not known. The room's who-is-here row draws it at 21 points, an agent's name in its
/// messages at 14, and its card larger. Only a picture: what it says is read with the name it sits by.
struct AgentLabMark: View {
    let lab: AgentLab
    let size: CGFloat

    var body: some View {
        let (red, green, blue) = lab.tint
        mark
            .foregroundStyle(Color(red: red, green: green, blue: blue))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if let asset = lab.logoAsset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else if let initial = lab.initial {
            Text(initial).font(.system(size: glyphSize, weight: .heavy, design: .rounded))
        } else {
            Image(systemName: "cpu").font(.system(size: glyphSize, weight: .semibold))
        }
    }

    /// The letter's or the chip's size: 15 points in the who-is-here row's 21-point square, in proportion elsewhere.
    private var glyphSize: CGFloat { size * 15 / 21 }
}

/// An agent's lab mark right after its name (ticket 00bcfcef), as a room's messages show it: a small square of fixed
/// size, drawn over room kept after the name, so the line stays exactly as tall as the name alone and nothing under it
/// moves. VoiceOver reads the name and the mark as one: "forge, Claude agent". Nothing for a person or a lab not known
/// (`AgentLab.badge` gives nil for them).
struct AgentNameBadge: ViewModifier {
    let lab: AgentLab?
    let name: String

    /// The mark's side, and the room between the name and it, in points.
    static let size: CGFloat = 14
    static let gap: CGFloat = 4

    @ViewBuilder
    func body(content: Content) -> some View {
        if let lab {
            content
                .padding(.trailing, Self.size + Self.gap)
                .overlay(alignment: .trailing) {
                    AgentLabMark(lab: lab, size: Self.size)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(AgentLab.spokenName(name, lab: lab))
        } else {
            content
        }
    }
}
