import Foundation

/// Whether this build shows emoji reactions: the `SentiEmojiReactions` Info.plist boolean. Off unless it is set to
/// true, as on the web, so the feature stays out of sight until it is turned on.
public enum RoomEmojiReactions {
    /// The Info.plist key.
    public static let infoKey = "SentiEmojiReactions"

    /// The app's own setting, read once.
    public static let isEnabled = isEnabled(in: Bundle.main.infoDictionary)

    /// The setting in `info`: on only for a boolean true. A missing key, or any value that is not a boolean, is off.
    public static func isEnabled(in info: [String: Any]?) -> Bool {
        guard let value = info?[infoKey] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
}
