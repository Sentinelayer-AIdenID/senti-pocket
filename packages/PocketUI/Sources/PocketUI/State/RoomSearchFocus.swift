import Foundation

/// The single message opened from search. Its identity also distinguishes opening the same result again.
public struct RoomSearchFocus: Equatable, Sendable {
    public let sequenceId: Int64
    public let query: String
    public let id: UUID

    public init(sequenceId: Int64, query: String, id: UUID = UUID()) {
        self.sequenceId = sequenceId
        self.query = query
        self.id = id
    }

    public var anchor: String { "search-match-\(id.uuidString)" }
}

/// Literal, case- and accent-insensitive word matches. Query text is never interpreted as markup or a pattern.
public enum RoomSearchText {
    public struct Fragment: Equatable, Sendable {
        public let text: String
        public let isMatch: Bool
    }

    public static func fragments(_ text: String, query: String) -> [Fragment] {
        let words = Set(query.split(whereSeparator: \.isWhitespace).map(String.init))
        var ranges: [Range<String.Index>] = []
        for word in words {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: start..<text.endIndex), !range.isEmpty {
                ranges.append(range)
                start = range.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result: [Fragment] = []
        var cursor = text.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                result.append(Fragment(text: String(text[cursor..<range.lowerBound]), isMatch: false))
            }
            result.append(Fragment(text: String(text[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result.append(Fragment(text: String(text[cursor...]), isMatch: false)) }
        return result
    }
}
