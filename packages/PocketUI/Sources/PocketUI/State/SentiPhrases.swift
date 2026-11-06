import Foundation

/// What Senti shows while it prepares an answer, and the lines a new, empty room opens with (Carter, #61720: quirky
/// 2-5 word phrases while Senti thinks, and fun ways to open a room, model agnostic and open to people). The app
/// ships the file the web publishes and may take a newer copy of it once a day (`SentiPhrasesStore`); a copy is used
/// only when `checked` accepts it.
public struct SentiPhrases: Equatable, Sendable {
    public let version: Int
    /// Shown one at a time while Senti prepares an answer.
    public let phrases: [String]
    /// One shown at the top of a new, empty room.
    public let roomIntros: [String]

    /// The longest line taken, in characters.
    public static let longestLine = 80
    /// The most lines of each kind taken: a file far larger than the one published is not this file.
    public static let mostLines = 500

    public init(version: Int, phrases: [String], roomIntros: [String]) {
        self.version = version
        self.phrases = phrases
        self.roomIntros = roomIntros
    }

    /// Used only if even the app's own copy cannot be read.
    public static let fallback = SentiPhrases(version: 0, phrases: ["Thinking it through"],
                                              roomIntros: ["Room's empty. Not for long."])

    private struct File: Decodable {
        let version: Int
        let phrases: [String]
        let roomIntros: [String]
    }

    /// The file, if it parses, its version is at least `minimumVersion`, it has lines of both kinds, and every line is
    /// 1 to 80 characters with no control characters (a line break, a tab, an escape...). Anything else is nil, and the
    /// copy already in use stays.
    public static func checked(_ data: Data, minimumVersion: Int) -> SentiPhrases? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version >= minimumVersion,
              (1...mostLines).contains(file.phrases.count), (1...mostLines).contains(file.roomIntros.count),
              (file.phrases + file.roomIntros).allSatisfy(isUsable) else { return nil }
        return SentiPhrases(version: file.version, phrases: file.phrases, roomIntros: file.roomIntros)
    }

    static func isUsable(_ line: String) -> Bool {
        guard (1...longestLine).contains(line.count),
              !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !line.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
        }
    }

    /// The phrase shown at the given turn: the first is chosen by `seed` (so two answers don't start alike), then each
    /// turn shows the next.
    public func phrase(turn: Int, seed: Int) -> String {
        guard !phrases.isEmpty else { return Self.fallback.phrases[0] }
        let count = phrases.count
        return phrases[((seed % count) + count + turn % count) % count]
    }

    /// The line a new room opens with: chosen at random for each room, and the same for that room all day, so it never
    /// changes while it is on screen or when the room is opened again that day.
    public func roomIntro(roomId: String, on day: Date, calendar: Calendar = .current) -> String {
        guard !roomIntros.isEmpty else { return Self.fallback.roomIntros[0] }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let key = "\(roomId)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        return roomIntros[Int(Self.stableHash(key) % UInt64(roomIntros.count))]
    }

    /// FNV-1a: the same on every launch, unlike `Hasher`.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

#if canImport(SwiftUI)
import SwiftUI

private struct SentiPhrasesKey: EnvironmentKey {
    static let defaultValue = SentiPhrases.fallback
}

extension EnvironmentValues {
    /// The phrases the room shows while Senti thinks, and its new-room lines (the app sets them from its copy).
    public var sentiPhrases: SentiPhrases {
        get { self[SentiPhrasesKey.self] }
        set { self[SentiPhrasesKey.self] = newValue }
    }
}
#endif
