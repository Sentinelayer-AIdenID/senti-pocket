import Combine
import Foundation
import PocketSyncClient
import PocketUI

/// Search sessions last for this signed-in root only. Nothing is written to disk.
@MainActor
final class RoomSearchSessions: ObservableObject {
    private var models: [String: RoomSearchModel] = [:]
    private let onReauthenticationRequired: @MainActor () -> Void

    init(onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func model(for sessionId: String, searcher: any RoomSearching,
               isBlocked: @escaping @MainActor (String) -> Bool = { _ in false }) -> RoomSearchModel {
        model(for: sessionId) {
            RoomSearchModel(sessionId: sessionId, searcher: searcher, isBlocked: isBlocked,
                            onReauthenticationRequired: { [weak self] in self?.invalidateAuthentication() })
        }
    }

    func model(for sessionId: String, make: () -> RoomSearchModel) -> RoomSearchModel {
        if let model = models[sessionId] { return model }
        let model = make()
        models[sessionId] = model
        return model
    }

    func clear() {
        for model in models.values { model.send(.clear) }
        models.removeAll()
    }

    func invalidateAuthentication() {
        clear()
        onReauthenticationRequired()
    }
}
