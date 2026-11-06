import Foundation

/// An option offered as a one-tap answer that is posted as the person: what is tapped must be exactly what is posted
/// (warden, #298 review). Shared by "Waiting on you" and a ticket's decision.
public enum AnswerOption {
    /// The longest option offered as a one-tap answer: shown whole on a phone.
    public static let maxLength = 80

    /// The option as it can be answered in one tap, or nil. One line with single spaces, without invisible format
    /// characters (zero-width or direction marks) and without "@" (an option never mentions anyone). A longer one is
    /// left out rather than cut, since a cut answer can say something else; it is answered in the room instead.
    public static func answerable(_ raw: String) -> String? {
        let visible = raw.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            // Format characters and every other invisible one (variation selectors too): not shown, not counted.
            if scalar.properties.generalCategory == .format || scalar.properties.isDefaultIgnorableCodePoint { return nil }
            return scalar.value < 32 || scalar.value == 127 ? " " : scalar
        }
        let oneLine = String(String.UnicodeScalarView(visible)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let option = oneLine.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !option.isEmpty, option.count <= maxLength else { return nil }
        return option
    }
}
