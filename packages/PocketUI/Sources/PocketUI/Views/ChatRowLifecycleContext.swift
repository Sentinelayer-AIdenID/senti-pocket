#if canImport(SwiftUI)
import SwiftUI

/// The app's live row permissions and a request for confirmation. A row never performs the network write itself.
public struct ChatRowLifecycleContext {
    private let choices: [String: ChatRowLifecycleAction]
    private let request: (String, ChatRowLifecycleAction) -> Void

    public init(choices: [String: ChatRowLifecycleAction], request: @escaping (String, ChatRowLifecycleAction) -> Void) {
        self.choices = choices
        self.request = request
    }

    public func action(for roomId: String) -> ChatRowLifecycleAction? { choices[roomId] }
    public func ask(for roomId: String, action requested: ChatRowLifecycleAction? = nil) {
        guard let available = choices[roomId] else { return }
        let action = requested ?? available
        guard available.permits(action) else { return }
        request(roomId, action)
    }
}

private struct ChatRowLifecycleContextKey: EnvironmentKey {
    static let defaultValue: ChatRowLifecycleContext? = nil
}

extension EnvironmentValues {
    public var chatRowLifecycle: ChatRowLifecycleContext? {
        get { self[ChatRowLifecycleContextKey.self] }
        set { self[ChatRowLifecycleContextKey.self] = newValue }
    }
}
#endif
