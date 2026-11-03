import Foundation

/// One emoji as a reaction: what an emoji reaction may carry, sent to the API and read back from it.
public enum ReactionEmoji {
    /// The most code points one reaction may have (so at most 32 bytes of UTF-8).
    public static let maximumScalars = 8

    /// Whether `text` is exactly one emoji: a pictograph (with skin tones, variation selectors and joined parts), a
    /// flag or a keycap. Never letters, digits, "@" or hidden tag text, and never more than one.
    public static func isValid(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard text.count == 1, let first = scalars.first, scalars.count <= maximumScalars else { return false }
        if subdivisionFlags.contains(text) { return true }
        // A keycap: a digit, "#" or "*", then the keycap mark, with or without the emoji selector between.
        if first.isASCII {
            return keycapBases.contains(first)
                && (scalars == [first, keycapMark] || scalars == [first, emojiSelector, keycapMark])
        }
        // A flag: two regional indicators, never one alone.
        if regionalIndicators.contains(first.value) {
            return scalars.count == 2 && regionalIndicators.contains(scalars[1].value)
        }
        return isPictograph(first) && scalars.dropFirst().allSatisfy { scalar in
            isPictograph(scalar) || scalar == joiner || scalar == emojiSelector
        }
    }

    private static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && !letters.contains(scalar.properties.generalCategory)
    }

    private static let keycapBases = Set("0123456789#*".unicodeScalars)
    private static let keycapMark: Unicode.Scalar = "\u{20E3}"
    private static let emojiSelector: Unicode.Scalar = "\u{FE0F}"
    private static let joiner: Unicode.Scalar = "\u{200D}"
    private static let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
    private static let letters: Set<Unicode.GeneralCategory> = [
        .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter
    ]
    /// The flags written with tag characters (England, Scotland, Wales): the only tag text a reaction may hold.
    private static let subdivisionFlags: Set<String> = [
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"
    ]
}
