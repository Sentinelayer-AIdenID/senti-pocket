import Foundation
import PocketSyncClient
import PocketUI

@MainActor
extension RoomFoldersCenter {
    func setPinned(_ folderId: String, pinned: Bool) async {
        guard RoomFolderPinsPresentation.isAvailable(items ?? []),
              folders?.contains(where: { $0.id == folderId }) == true else { return }
        await changePins { pins, accountId in
            if pinned { _ = try await pins.pinFolder(folderId, accountId: accountId) }
            else { try await pins.unpinFolder(folderId, accountId: accountId) }
        }
    }

    func reorderPins(_ folderIds: [String]) async {
        let current = RoomFolderPinsPresentation.ordered(items ?? []).map(\.id)
        guard RoomFolderPinsPresentation.isAvailable(items ?? []),
              folderIds.count == current.count, Set(folderIds).count == folderIds.count,
              Set(folderIds) == Set(current) else { return }
        await changePins { try await $0.reorderFolderPins(folderIds, accountId: $1) }
    }

    /// One pin write at a time, with no local pin membership to drift. Even a conflict reads the server's order.
    private func changePins(_ operation: (any RoomFolderPinsServing, String) async throws -> Void) async {
        guard !isPinSaving, let pinClient, let accountId = pinAccountId else { return }
        isPinSaving = true
        if notice != nil { notice = nil }
        defer { isPinSaving = false }
        let outcome: PinOutcome
        do {
            try await operation(pinClient, accountId)
            outcome = .saved
        } catch RoomFolderError.accountChanged {
            // A write from the previous sign-in must not start a read with the next person's credentials.
            return
        } catch RoomFolderError.reauthenticationRequired {
            if pinAccountId == accountId { onReauthenticationRequired() }
            return
        } catch RoomFolderError.pinLimit {
            outcome = .limit
        } catch RoomFolderError.pinsChanged {
            outcome = .changed
        } catch RoomFolderError.unavailable {
            outcome = .unavailable
        } catch {
            outcome = .failed
        }

        guard pinAccountId == accountId else { return }
        let loaded: Bool
        do { loaded = try await refreshPins(accountId: accountId) }
        catch RoomFolderError.accountChanged { return }
        catch RoomFolderError.reauthenticationRequired {
            if pinAccountId == accountId { onReauthenticationRequired() }
            return
        } catch { loaded = false }
        guard pinAccountId == accountId else { return }
        switch outcome {
        case .saved:
            if !loaded { notice = "Saved, but couldn't refresh your folders. Try again." }
        case .limit:
            notice = RoomFolderPinsPresentation.limitMessage
        case .changed:
            notice = loaded ? "Your pinned folders changed. The latest order is shown."
                : "Your pinned folders changed. Couldn't refresh the list; try again."
        case .unavailable:
            break
        case .failed:
            notice = "Couldn't save your pinned folders. Check your connection and try again."
        }
    }

    private enum PinOutcome { case saved, limit, changed, unavailable, failed }
}
