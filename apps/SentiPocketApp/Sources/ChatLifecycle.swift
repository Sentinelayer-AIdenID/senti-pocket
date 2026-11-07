import Foundation
import SwiftUI
import PocketSyncClient
import PocketUI

enum ChatLifecycleFeatures {
    /// The leave route is a later server release. An absent key is off in every shipping build.
    static var leaveEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SENTI_CHAT_LEAVE_ENABLED") as? Bool ?? false
    }
}

/// Resolve the account using the very bearer the mutation will send. A refresh retries this read once; it does
/// not turn the bearer into an account identifier or change the shared authenticated-request implementation.
struct ChatLifecycleAccountCredentials: Sendable {
    let apiBaseURL: URL?
    let urlSession: URLSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    func current() async throws -> ChatLifecycleCredential {
        for _ in 0..<2 {
            guard let token = tokenProvider(), !token.isEmpty else { throw ChatLifecycleError.reauthenticationRequired }
            let identity = HTTPAccountIdentity(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: { token })
            let account = await identity.currentAccount()
            guard tokenProvider() == token else { continue }
            guard let accountId = account?.accountId else { throw ChatLifecycleError.network }
            return ChatLifecycleCredential(accountId: accountId, token: token)
        }
        throw ChatLifecycleError.accountChanged
    }
}

/// Holds one confirmation, bound to its chat and action. A fresh role check runs at confirmation, and only an
/// acknowledged network write removes the chat from the screen. Its alerts observe it; the room's root does not.
@MainActor
final class ChatLifecycleCenter: ObservableObject {
    struct Confirmation: Identifiable, Equatable {
        let id: UUID
        let roomId: String
        let action: ChatRowLifecycleAction
        let accountId: String
    }

    @Published var confirmation: Confirmation?
    @Published var notice: String?
    @Published private(set) var isSaving = false
    private var accountId: String?
    private var pendingId: UUID?
    private let client: (any ChatLifecycleServing)?
    private let lookup: @MainActor (String) -> ChatRowLifecycleAction?
    private let onReauthenticationRequired: @MainActor () -> Void
    let leaveEnabled: Bool

    init(client: (any ChatLifecycleServing)?, leaveEnabled: Bool = false,
         lookup: @escaping @MainActor (String) -> ChatRowLifecycleAction?,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.leaveEnabled = leaveEnabled
        self.lookup = lookup
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func context(rows: [SessionRowPresentation]) -> ChatRowLifecycleContext? {
        guard client != nil, accountId != nil else { return nil }
        var choices: [String: ChatRowLifecycleAction] = [:]
        for row in rows {
            choices[row.sessionId] = ChatRowLifecycleAction.available(
                membershipRole: row.membershipRole, status: row.status, leaveEnabled: leaveEnabled)
        }
        return ChatRowLifecycleContext(choices: choices) { [weak self] roomId, action in
            self?.request(roomId, action: action)
        }
    }

    func request(_ roomId: String, action requested: ChatRowLifecycleAction? = nil) {
        guard client != nil, !isSaving, let accountId, let available = lookup(roomId) else { return }
        let action = requested ?? available
        guard available.permits(action), action != .leave || leaveEnabled else { return }
        let pending = Confirmation(id: UUID(), roomId: roomId, action: action, accountId: accountId)
        pendingId = pending.id
        confirmation = pending
    }

    func cancel() {
        pendingId = nil
        confirmation = nil
    }

    func setAccountId(_ value: String?) {
        guard accountId != value else { return }
        accountId = value
        cancel()
        notice = nil
    }

    /// The alert passes its captured value: SwiftUI may clear its presentation binding before the button runs.
    /// Only that single-use confirmation can write, even if a stale alert callback fires again.
    func confirm(_ pending: Confirmation) async -> Bool {
        guard pendingId == pending.id, pending.accountId == accountId, !isSaving, let client else { return false }
        cancel()
        guard lookup(pending.roomId)?.permits(pending.action) == true, pending.action != .leave || leaveEnabled else {
            notice = "This chat changed. Refresh your chats and try again."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            switch pending.action {
            case .archive: try await client.archiveChat(pending.roomId, accountId: pending.accountId)
            case .end: try await client.endChat(pending.roomId, accountId: pending.accountId)
            case .leave: try await client.leaveChat(pending.roomId, accountId: pending.accountId)
            }
            return pending.accountId == accountId
        } catch ChatLifecycleError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch ChatLifecycleError.accountChanged {
            // A response to another sign-in must not change this account's screen or display its result.
        } catch ChatLifecycleError.notAllowed {
            notice = "You no longer have permission to do that. Refresh your chats and try again."
        } catch ChatLifecycleError.gone {
            notice = "This chat is no longer available. Refresh your chats."
        } catch {
            notice = "The change could not be confirmed. Check your connection and refresh your chats before trying again."
        }
        return false
    }
}

struct ChatLifecycleAlerts: ViewModifier {
    @ObservedObject var center: ChatLifecycleCenter
    let onChanged: (String) -> Void

    func body(content: Content) -> some View {
        content
            .alert(center.confirmation?.action.confirmationTitle ?? "", isPresented: Binding(
                get: { center.confirmation != nil },
                set: { if !$0 { center.confirmation = nil } }
            ), presenting: center.confirmation) { pending in
                Button(pending.action.confirmLabel, role: .destructive) {
                    Task {
                        if await center.confirm(pending) { onChanged(pending.roomId) }
                    }
                }
                Button("Cancel", role: .cancel) { center.cancel() }
            } message: { pending in
                Text(pending.action.confirmationMessage)
            }
            .alert("Could not confirm change", isPresented: Binding(
                get: { center.notice != nil },
                set: { if !$0 { center.notice = nil } }
            )) {
                Button("OK", role: .cancel) { center.notice = nil }
            } message: {
                Text(center.notice ?? "")
            }
    }
}
