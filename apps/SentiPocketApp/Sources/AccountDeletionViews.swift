import SwiftUI

/// The Settings row that opens the deletion screen, under Sign out. It shows unless the server says it does not offer
/// deletion (404), so App Review always finds it.
struct AccountDeletionRow: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator
    let onSignOut: @MainActor () -> Void
    @State private var presentsSheet = false

    var body: some View {
        if coordinator.isOffered {
            Button("Delete account", role: .destructive) {
                coordinator.resetRequest()
                presentsSheet = true
            }
            .accessibilityIdentifier("settings.account.delete")
            .sheet(isPresented: $presentsSheet) {
                AccountDeletionSheet(coordinator: coordinator, onSignOut: onSignOut)
            }
        }
    }
}

/// Says in plain words what deleting the account does, and asks twice before asking the server: "Delete my account"
/// only brings up the confirmation, and only the confirmation's own button sends the request.
struct AccountDeletionSheet: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator
    let onSignOut: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The confirmation on screen. The view's own: however iOS closes it, it never decides what is sent.
    @State private var confirms = false

    private var sending: Bool { coordinator.request == .sending }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(AccountDeletionCopy.sheetTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("account.delete.title")
                    part(AccountDeletionCopy.rightAwayTitle, AccountDeletionCopy.rightAway, id: "right-away")
                    part(AccountDeletionCopy.laterTitle, AccountDeletionCopy.later(graceDays: coordinator.graceDays),
                         id: "later")
                    part(AccountDeletionCopy.staysTitle, AccountDeletionCopy.stays, id: "stays")
                    part(AccountDeletionCopy.keepTitle, AccountDeletionCopy.keep, id: "keep")
                    if case .failed(let message) = coordinator.request {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("account.delete.failure")
                    }
                    Button(role: .destructive) {
                        coordinator.askToDelete()
                        confirms = true
                    } label: {
                        Group {
                            if sending {
                                ProgressView()
                            } else {
                                Text(AccountDeletionCopy.deleteButton)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sending)
                    .accessibilityLabel(AccountDeletionCopy.deleteButton)
                    .accessibilityHint(AccountDeletionCopy.deleteHint)
                    .accessibilityIdentifier("account.delete.request")
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sending)
                        .accessibilityIdentifier("account.delete.cancel")
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .alert(AccountDeletionCopy.confirmTitle, isPresented: $confirms) {
            Button(AccountDeletionCopy.deleteButton, role: .destructive) {
                _ = coordinator.confirmDeletion(signOut: onSignOut)
            }
            Button("Cancel", role: .cancel) {
                coordinator.dismissConfirmation()
            }
        } message: {
            Text(AccountDeletionCopy.confirmMessage(graceDays: coordinator.graceDays))
        }
    }

    /// One part of what deleting does: its heading (a VoiceOver heading), then its words.
    private func part(_ title: String, _ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.delete.\(id)")
        }
    }
}

/// Shown over the sign-in screen once a deletion request went through: the date, and how to keep the account. It
/// scrolls when the largest text sizes make it taller than the screen.
struct AccountDeletionScheduledView: View {
    let scheduled: AccountDeletionScheduled
    let onDone: @MainActor () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AccountDeletionCopy.scheduledTitle(deleteAfter: scheduled.deleteAfter))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("account.scheduled.title")
                    Text(AccountDeletionCopy.scheduledDetail(deleteAfter: scheduled.deleteAfter))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.scheduled.detail")
                    Spacer(minLength: 0)
                    Button(action: onDone) {
                        Text("OK").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("account.scheduled.done")
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}

/// The date a deletion was scheduled for, over the sign-in screen once the request went through. It watches the
/// deletion's state itself, so the app's root is not drawn again for it.
struct AccountDeletionScheduledOverlay: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)
            if let scheduled = coordinator.scheduled {
                AccountDeletionScheduledView(scheduled: scheduled) { coordinator.dismissScheduled() }
            }
        }
    }
}

/// The notice over the signed-in root while the account is scheduled for deletion. It watches the deletion's state
/// itself, so the root is not drawn again for it; when the notice comes up, `onShown` puts away whatever the root had
/// open over it.
struct AccountDeletionPendingOverlay: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator
    let onShown: @MainActor () -> Void
    let onContinue: @MainActor () -> Void
    let onSignOut: @MainActor () -> Void

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)
            if let notice = coordinator.pending {
                AccountDeletionPendingView(
                    notice: notice,
                    onKeepAccount: {
                        Task { await coordinator.keepAccount(onContinue: onContinue) }
                    },
                    onSignOut: onSignOut
                )
            }
        }
        .onAppear {
            if coordinator.pending != nil { onShown() }
        }
        .onChange(of: coordinator.pending != nil) { isPending in
            if isPending { onShown() }
        }
    }
}

/// Shown over the whole app while the account is scheduled for deletion: the date, Keep my account until then, and
/// Sign out. It scrolls when the largest text sizes make it taller than the screen.
struct AccountDeletionPendingView: View {
    let notice: AccountDeletionPendingNotice
    let onKeepAccount: @MainActor () -> Void
    let onSignOut: @MainActor () -> Void

    private var keeping: Bool { notice.phase == .keeping }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 52))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(notice.offersKeepAccount
                         ? AccountDeletionCopy.pendingTitle(deleteAfter: notice.deleteAfter)
                         : AccountDeletionCopy.deadlinePassedTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("account.pending.title")
                    Text(notice.offersKeepAccount
                         ? AccountDeletionCopy.pendingDetail
                         : AccountDeletionCopy.deadlinePassedDetail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.pending.detail")
                    if case .failed(let message) = notice.phase {
                        Text(message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("account.pending.failure")
                    }
                    Spacer(minLength: 0)
                    if notice.offersKeepAccount {
                        Button(action: onKeepAccount) {
                            Group {
                                if keeping {
                                    ProgressView()
                                } else {
                                    Text("Keep my account")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(keeping)
                        .accessibilityLabel("Keep my account")
                        .accessibilityHint("Stops the deletion.")
                        .accessibilityIdentifier("account.pending.keep")
                    }
                    Button(action: onSignOut) {
                        Text("Sign out").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(keeping)
                    .accessibilityIdentifier("account.pending.sign-out")
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}
