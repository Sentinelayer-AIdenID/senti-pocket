import Foundation
import PocketUI

/// The app's theme, kept in UserDefaults under "pocket.theme" and published only when that value really changes.
///
/// The root used to hold it as `@AppStorage`. That redrew the root on a UserDefaults change notice that changed no
/// theme while the key was unset: UIKit posts one when a class first registers its defaults, as the first TextKit 2 text
/// view laid out in the process does (`-[NSUserDefaults registerDefaults:]` from a `+initialize`, under
/// `-[NSTextLayoutManager textSelectionNavigation]`). A root drawn again rebuilds what it holds, the room screen under
/// it included (ticket cfb0383e, #382). Key-value observing cannot watch this key on its own (the dot in "pocket.theme"
/// makes it a key path), so the store hears every change notice, on the main queue, and compares the value it holds.
/// Used on the main thread only: by the root, and the notices are delivered on the main queue.
final class PocketThemeStore: ObservableObject {
    static let key = "pocket.theme"

    @Published private(set) var preference: PocketThemePreference
    private let defaults: UserDefaults
    private var notices: NSObjectProtocol?

    /// Reads the stored theme once; afterwards only a change notice reads it again.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = Self.preference(in: defaults)
        notices = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                         queue: .main) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let notices { NotificationCenter.default.removeObserver(notices) }
    }

    /// A pick (the side panel's Appearance picker): written only when it differs, then published.
    func set(_ new: PocketThemePreference) {
        if defaults.string(forKey: Self.key) != new.rawValue {
            defaults.set(new.rawValue, forKey: Self.key)
        }
        refresh()
    }

    /// Publishes the stored value only when it is not the one held: a notice that changed no theme changes nothing.
    private func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let stored = Self.preference(in: defaults)
        if stored != preference { preference = stored }
    }

    private static func preference(in defaults: UserDefaults) -> PocketThemePreference {
        defaults.string(forKey: key).flatMap(PocketThemePreference.init(rawValue:)) ?? .system
    }
}
