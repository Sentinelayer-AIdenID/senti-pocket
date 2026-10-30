import Foundation

/// A voice of its own for each agent in a voice room, so you can tell who is talking: the language of what it says
/// (else the phone's), then one of the best voices installed for that language, picked by the agent's id. The same
/// agent keeps the same voice on every call and every phone with the same voices.
public enum AgentVoices {
    /// How many of the best voices of a language the agents share out.
    static let poolSize = 6

    /// The voice identifier for `speaker` saying `text`, or nil when no voice speaks the language (the system's
    /// default then speaks).
    public static func identifier(
        for speaker: String,
        saying text: String,
        phoneLanguageTag: String = Locale.preferredLanguages.first ?? Locale.current.identifier
    ) -> String? {
        let language = VoicePicker.language(of: text, phoneLanguageTag: phoneLanguageTag)
        return identifier(for: speaker, language: language, phoneLanguageTag: phoneLanguageTag, from: VoiceOption.installed())
    }

    static func identifier(for speaker: String, language: String, phoneLanguageTag: String, from options: [VoiceOption]) -> String? {
        let pool = VoicePicker.ranked(for: language, phoneLanguageTag: phoneLanguageTag, from: options).prefix(poolSize)
        guard !pool.isEmpty else { return nil }
        let index = Int(stableHash(speaker.lowercased()) % UInt64(pool.count))
        return pool[pool.startIndex + index].identifier
    }

    /// FNV-1a over the UTF-8 bytes: the same on every launch, unlike `hashValue`.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
