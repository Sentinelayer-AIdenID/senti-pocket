#if canImport(SwiftUI)
import SwiftUI

/// The same pin action in a folder's existing menu and its long-press menu.
struct RoomFolderPinMenuAction: View {
    let folder: RoomFolderItem
    let available: Bool
    let isSaving: Bool
    let send: (RoomFolderIntent) -> Void

    var body: some View {
        if available {
            Button {
                send(.setPinned(folderId: folder.id, pinned: folder.pinnedPosition == nil))
            } label: {
                Label(folder.pinnedPosition == nil ? "Pin to top" : "Unpin",
                      systemImage: folder.pinnedPosition == nil ? "pin" : "pin.slash")
            }
            .disabled(isSaving)
            .accessibilityIdentifier("pocket.drawer.folder.\(folder.id).pinAction")
        }
    }
}

struct RoomFolderPinContextMenu: ViewModifier {
    let folder: RoomFolderItem
    let available: Bool
    let isSaving: Bool
    let send: ((RoomFolderIntent) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if available, let send {
            content.contextMenu {
                RoomFolderPinMenuAction(folder: folder, available: true, isSaving: isSaving, send: send)
            }
        } else {
            content
        }
    }
}

/// A bounded, scrollable group of shortcuts. Opening one reveals the same folder in the existing room tree.
struct PinnedRoomFolders: View {
    @ObservedObject var placement: SidePanelPlacement
    let isSaving: Bool
    let send: (RoomFolderIntent) -> Void
    let scrollTo: (String) -> Void
    @State private var dropTarget: String?

    var body: some View {
        let shown = placement.shown.layout.pinnedFolders
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pinned").font(.caption.weight(.semibold))
                    Spacer()
                    if isSaving { ProgressView().accessibilityLabel("Saving pinned folders") }
                }
                .foregroundStyle(PocketPalette.textSecondary)
                .padding(.horizontal, 18)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(shown) { folder in
                            pinRow(folder, shown: shown)
                        }
                    }
                }
                .frame(height: min(CGFloat(shown.count) * 48, 240))
                .accessibilityIdentifier("pocket.drawer.pinnedFolders.scroll")
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pinned folders")
            .accessibilityIdentifier("pocket.drawer.pinnedFolders")
        }
    }

    private func pinRow(_ folder: RoomFolderItem, shown: [RoomFolderItem]) -> some View {
        let ids = shown.map(\.id)
        return HStack(spacing: 4) {
            Button { reveal(folder.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(PocketPalette.accentStrong)
                    Text(folder.name).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open pinned folder \(folder.name)")
            Menu {
                RoomFolderPinMenuAction(folder: folder, available: true, isSaving: isSaving, send: send)
                Button("Move up") { move(folder.id, by: -1, in: ids) }
                    .disabled(isSaving || ids.first == folder.id)
                Button("Move down") { move(folder.id, by: 1, in: ids) }
                    .disabled(isSaving || ids.last == folder.id)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("\(folder.name) pinned folder menu")
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .draggable(folder.id)
                .allowsHitTesting(!isSaving)
                .accessibilityLabel("Reorder \(folder.name)")
                .accessibilityHint("Drag to change its place in Pinned")
                .accessibilityAction(named: "Move up") { if !isSaving { move(folder.id, by: -1, in: ids) } }
                .accessibilityAction(named: "Move down") { if !isSaving { move(folder.id, by: 1, in: ids) } }
        }
        .padding(.leading, 18)
        .padding(.trailing, 2)
        .background(dropTarget == folder.id ? PocketPalette.accentStrong.opacity(0.12) : Color.clear)
        .modifier(RoomFolderPinContextMenu(folder: folder, available: true, isSaving: isSaving, send: send))
        .dropDestination(for: String.self) { dragged, _ in
            guard !isSaving, dragged.count == 1, let source = dragged.first, ids.contains(source) else { return false }
            if source != folder.id {
                send(.reorderPins(folderIds: RoomFolderPinsPresentation.reordered(ids, moving: source, to: folder.id)))
            }
            dropTarget = nil
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? folder.id : (dropTarget == folder.id ? nil : dropTarget)
        }
        .accessibilityIdentifier("pocket.drawer.pinnedFolder.\(folder.id)")
    }

    private func move(_ id: String, by delta: Int, in ids: [String]) {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        send(.reorderPins(folderIds: RoomFolderPinsPresentation.reordered(ids, moving: id, to: ids[index + delta])))
    }

    private func reveal(_ id: String) {
        var seen = Set<String>()
        var current: String? = id
        while let folderId = current, seen.insert(folderId).inserted {
            if placement.folded.contains(folderId) { placement.toggleFolded(folderId) }
            current = placement.shown.layout.tree.node(folderId)?.parentId
        }
        DispatchQueue.main.async { scrollTo(id) }
    }
}
#endif
