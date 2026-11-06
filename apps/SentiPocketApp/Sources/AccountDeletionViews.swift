import SwiftUI

/// The Settings row that opens the deletion sheet, shown only once the server says it offers deletion.
struct AccountDeletionRow: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator
    let onSignOut: @MainActor () -> Void
    @State private var presentsSheet = false

    var body: some View {
        if coordinator.isOffered {
            Button("Delete account", role: .destructive) {
                coordinator.clearRequestFailure()
                presentsSheet = true
            }
            .accessibilityIdentifier("settings.account.delete")
            .sheet(isPresented: $presentsSheet) {
                AccountDeletionSheet(coordinator: coordinator, onSignOut: onSignOut)
            }
        }
    }
}

/// Says in plain words what deleting the account does, and asks twice before asking the server.
struct AccountDeletionSheet: View {
    @ObservedObject var coordinator: AccountDeletionCoordinator
    let onSignOut: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirms = false

    private var sending: Bool { coordinator.request == .sending }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Delete your account?")
                        .font(.title2.bold())
                    ForEach(AccountDeletionCopy.consequences, id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .labelStyle(AccountDeletionBulletStyle())
                    }
                    if case .failed(let message) = coordinator.request {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account.delete.failure")
                    }
                    Button(role: .destructive) {
                        confirms = true
                    } label: {
                        Group {
                            if sending {
                                ProgressView()
                            } else {
                                Text("Delete my account")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sending)
                    .accessibilityIdentifier("account.delete.request")
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sending)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .alert("Delete your account?", isPresented: $confirms) {
            Button("Delete", role: .destructive) {
                Task { await coordinator.requestDeletion(signOut: onSignOut) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be signed out on every device now.")
        }
    }
}

/// A small dot before each line of the confirmation sheet.
private struct AccountDeletionBulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

/// Shown over the sign-in screen once a deletion request went through: the date, and how to keep the account.
struct AccountDeletionScheduledView: View {
    let scheduled: AccountDeletionScheduled
    let onDone: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Your account will be deleted")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(AccountDeletionCopy.scheduled(deleteAfter: scheduled.deleteAfter))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onDone) {
                Text("OK").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("account.scheduled.done")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Shown over the whole app while the account is scheduled for deletion.
struct AccountDeletionPendingView: View {
    let notice: AccountDeletionPendingNotice
    let onKeepAccount: @MainActor () -> Void
    let onSignOut: @MainActor () -> Void

    private var keeping: Bool { notice.phase == .keeping }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 52))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(notice.offersKeepAccount
                 ? AccountDeletionCopy.pendingTitle(deleteAfter: notice.deleteAfter)
                 : AccountDeletionCopy.deadlinePassedTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(notice.offersKeepAccount ? AccountDeletionCopy.pendingDetail : AccountDeletionCopy.deadlinePassedDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if case .failed(let message) = notice.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}
