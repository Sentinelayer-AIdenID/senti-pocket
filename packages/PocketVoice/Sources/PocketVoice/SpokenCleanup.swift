import Foundation

/// What you said, tidied before it is posted (Carter, #55058: "eliminate weird things and duplicates"): the
/// recognizer's fillers ("um", "uh") go, and a word or a short phrase said twice in a row is kept once. Nothing is
/// reworded; anything it cannot tell apart from a real word is left as it was.
public enum SpokenCleanup {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm"]
    /// The longest phrase whose immediate repeat is folded ("can you can you hear me").
    static let longestRepeat = 4

    public static func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words.removeAll { fillers.contains(core($0)) }
        var index = 0
        while index < words.count {
            var folded = false
            for length in stride(from: min(longestRepeat, (words.count - index) / 2), through: 1, by: -1) {
                let first = words[index..<(index + length)].map(core)
                let second = words[(index + length)..<(index + 2 * length)].map(core)
                // A phrase said twice in a row is kept once; its second copy keeps the punctuation that ends it.
                if !first.contains(""), first == second {
                    words.removeSubrange(index..<(index + length))
                    folded = true
                    break
                }
            }
            if !folded { index += 1 }
        }
        var result = words.joined(separator: " ")
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// A word without its case or the punctuation around it, for comparing.
    static func core(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
