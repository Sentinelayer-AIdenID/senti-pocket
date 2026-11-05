#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

/// "Move to…" for a folder and "Move to folder…" for a room: your folders as a tree, each level stepped in, with only
/// the places it can go (`RoomFolderTree.destinations`). Where it is now is ticked and cannot be picked. What the server
/// said about the last pick (a 409, in plain words) shows at the top, and the sheet stays open to pick again.
public struct RoomFolderPickerSheet: View {
    private let title: String
    private let destinations: [RoomFolderDestination]
    private let problem: String?
    private let isSaving: Bool
    private let onPick: (String?) -> Void
    private let onNewFolder: (() -> Void)?
    private let onCancel: () -> Void

    /// - Parameters:
    ///   - onPick: the folder picked, or nil for the top level.
    ///   - onNewFolder: "New folder…", where the thing moved can go into a folder made for it.
    public init(title: String, destinations: [RoomFolderDestination], problem: String?, isSaving: Bool,
                onPick: @escaping (String?) -> Void, onNewFolder: (() -> Void)? = nil,
                onCancel: @escaping () -> Void) {
        self.title = title
        self.destinations = destinations
        self.problem = problem
        self.isSaving = isSaving
        self.onPick = onPick
        self.onNewFolder = onNewFolder
        self.onCancel = onCancel
    }

    /// What VoiceOver says for a place: "Studio, level 2, here now".
    static func accessibilityLabel(_ destination: RoomFolderDestination) -> String {
        [destination.name, destination.depth > 0 ? "level \(destination.depth)" : nil,
         destination.isCurrent ? "here now" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    public var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Section {
                        Text(problem)
                            .foregroundStyle(PocketPalette.danger)
                            .accessibilityIdentifier("pocket.folderPicker.problem")
                    }
                }
                let top = destinations.filter { $0.folderId == nil }
                if !top.isEmpty {
                    Section {
                        ForEach(top) { row($0) }
                    }
                }
                Section {
                    let folders = destinations.filter { $0.folderId != nil }
                    if folders.isEmpty {
                        Text("No folder it can go in.")
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    ForEach(folders) { row($0) }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Folders go \(RoomFolderName.maximumDepth) levels deep at most.")
                }
                if let onNewFolder {
                    Section {
                        Button(action: onNewFolder) {
                            Label("New folder…", systemImage: "folder.badge.plus")
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("pocket.folderPicker.new")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                if isSaving {
                    ToolbarItem(placement: .confirmationAction) { ProgressView() }
                }
            }
        }
        .accessibilityIdentifier("pocket.folderPicker")
    }

    private func row(_ destination: RoomFolderDestination) -> some View {
        Button {
            onPick(destination.folderId)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.folderId == nil ? "tray" : (destination.depth == 1 ? "folder.fill" : "folder"))
                    .foregroundStyle(PocketPalette.accentStrong)
                    .accessibilityHidden(true)
                Text(destination.name)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if destination.isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, PocketSidePanel.indent(destination.depth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(destination.isCurrent || isSaving)
        .accessibilityLabel(Self.accessibilityLabel(destination))
        .accessibilityIdentifier("pocket.folderPicker.\(destination.id)")
    }
}
#endif
