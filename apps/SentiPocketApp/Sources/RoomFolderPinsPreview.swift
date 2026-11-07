#if DEBUG
import Foundation
import PocketUI
import SwiftUI

/// The real side panel on one made-up folder. UI tests observe the intents emitted by its native menus.
enum RoomFolderPinsPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomFolderPinsPreview")
    }

    @MainActor
    static var rootView: some View {
        RoomFolderPinsPreviewScreen()
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ShotsDark") ? .dark : .light)
    }
}

@MainActor
private final class PreviewRoomFolderPins: ObservableObject {
    let placement: SidePanelPlacement
    let supported: Bool
    let accountReady: Bool
    @Published private(set) var calls = 0
    @Published private(set) var lastIntent = "No folder action"

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let supported = !arguments.contains("-PocketRoomFolderPinsUnsupported")
        self.supported = supported
        accountReady = !arguments.contains("-PocketRoomFolderPinsAccountPending")
        placement = SidePanelPlacement(rooms: [], folders: [Self.folder(pinned: false, supported: supported)])
    }

    func send(_ intent: RoomFolderIntent) {
        calls += 1
        switch intent {
        case let .setPinned(folderId, pinned):
            lastIntent = "\(pinned ? "pin" : "unpin"):\(folderId)"
            if folderId == "pin-fixture" {
                placement.update(rooms: [], folders: [Self.folder(pinned: pinned, supported: supported)])
            }
        default:
            lastIntent = "Another folder action"
        }
    }

    private static func folder(pinned: Bool, supported: Bool) -> RoomFolderItem {
        RoomFolderItem(id: "pin-fixture", name: "Planning", position: 0,
                       pinnedPosition: pinned ? 0 : nil, supportsPinning: supported)
    }
}

@MainActor
private struct RoomFolderPinsPreviewScreen: View {
    @StateObject private var model = PreviewRoomFolderPins()

    var body: some View {
        VStack(spacing: 0) {
            PocketSidePanel(
                placement: model.placement, currentRoomId: nil, unreadNotifications: 0, accountName: "Member",
                theme: .constant(.system), onSelectRoom: { _ in }, onAllRooms: {}, onNotifications: {}, onCalls: {},
                onActivity: {}, onSettings: {}, pinActionsAvailable: model.accountReady, onFolder: model.send
            )
            Divider()
            VStack(spacing: 4) {
                Text("Calls: \(model.calls)")
                    .accessibilityIdentifier("folder-pins.preview.calls")
                Text(model.lastIntent)
                    .accessibilityIdentifier("folder-pins.preview.lastIntent")
            }
            .font(.footnote)
            .padding(8)
        }
    }
}
#endif
