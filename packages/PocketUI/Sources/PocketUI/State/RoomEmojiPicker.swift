import Foundation
import PocketContracts

/// What the emoji picker offers: common reactions, and your recently used ones, kept on the phone.
public enum RoomEmojiPicker {
    /// The common reactions, in the picker's grid.
    public static let common: [String] = [
        "👍", "👎", "❤️", "😂", "🎉", "🙏",
        "👀", "🔥", "✅", "❌", "🚀", "💯",
        "😄", "😮", "😢", "😡", "🤔", "👏",
        "🙌", "💡", "⚠️", "🐛", "🛠️", "☕"
    ]
    /// How many recently used emoji the picker shows: one row of its grid.
    public static let recentLimit = 6
    static let recentKey = "pocket.emoji.recent"

    /// Your recently used emoji, newest first.
    public static func recent(in defaults: UserDefaults = .standard) -> [String] {
        Array((defaults.stringArray(forKey: recentKey) ?? []).filter(ReactionEmoji.isValid).prefix(recentLimit))
    }

    /// Notes an emoji you reacted with: first in the recent row, and there once.
    public static func noteUsed(_ emoji: String, in defaults: UserDefaults = .standard) {
        let kept = [emoji] + recent(in: defaults).filter { $0 != emoji }
        defaults.set(Array(kept.prefix(recentLimit)), forKey: recentKey)
    }

    /// Forgets the recent row at sign-out: whoever signs in next never sees what the last person reacted with.
    public static func forgetRecent(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: recentKey)
    }
}
