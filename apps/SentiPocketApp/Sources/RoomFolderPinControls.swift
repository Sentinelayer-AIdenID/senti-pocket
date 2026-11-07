import SwiftUI

/// Only the side panel observes pin progress and account readiness. These changes never notify the room's root.
@MainActor
final class RoomFolderPinControls: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var isAvailable = false

    func setSaving(_ value: Bool) {
        if isSaving != value { isSaving = value }
    }

    func setAvailable(_ value: Bool) {
        if isAvailable != value { isAvailable = value }
    }
}

/// Keeps the observer below the root while retaining the existing side panel and its folder behavior.
@MainActor
struct RoomFolderPinControlsView<Content: View>: View {
    @ObservedObject private var controls: RoomFolderPinControls
    private let content: (Bool, Bool) -> Content

    init(controls: RoomFolderPinControls, @ViewBuilder content: @escaping (Bool, Bool) -> Content) {
        _controls = ObservedObject(wrappedValue: controls)
        self.content = content
    }

    var body: some View {
        content(controls.isSaving, controls.isAvailable)
    }
}
