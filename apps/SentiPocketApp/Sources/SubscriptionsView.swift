import SwiftUI

/// The in-app plans: each plan's name, what it adds and its App Store price per month with a Subscribe button, the
/// current plan marked, Restore purchases, how renewal works, and the Terms of Use and Privacy Policy.
struct SubscriptionsView: View {
    @ObservedObject var coordinator: AppleSubscriptionsCoordinator

    /// Apple's standard license agreement.
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://sentinelayer.com/privacy")!
    static let renewalTerms = "Payment is charged to your Apple ID when you confirm the purchase. Your plan renews "
        + "every month at the price shown unless you cancel at least 24 hours before the current period ends; the "
        + "renewal is charged within the 24 hours before it ends. Manage or cancel your plan in Settings, under your "
        + "name, then Subscriptions."

    var body: some View {
        List {
            switch coordinator.state {
            case .ready(let offers, let currentTier), .purchasing(let offers, let currentTier):
                plans(offers, currentTier: currentTier)
            case .loading:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading plans")
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Text(message)
                    Button("Try again") { Task { await coordinator.refresh() } }
                        .accessibilityIdentifier("plans.retry")
                }
            case .hidden:
                Section {
                    Text("Plans aren't offered in the app right now.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Restore purchases") { Task { await coordinator.restore() } }
                    .disabled(!canAct)
                    .accessibilityIdentifier("plans.restore")
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.renewalTerms)
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: Self.termsOfUseURL)
                            .accessibilityIdentifier("plans.terms")
                        Link("Privacy Policy", destination: Self.privacyPolicyURL)
                            .accessibilityIdentifier("plans.privacy")
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refresh() }
        .alert("Plans", isPresented: noticeIsPresented) {
            Button("OK") { coordinator.dismissNotice() }
        } message: {
            Text(coordinator.notice ?? "")
        }
    }

    @ViewBuilder
    private func plans(_ offers: [AppleSubscriptionOffer], currentTier: String?) -> some View {
        if isPurchasing {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for the App Store")
                        .foregroundStyle(.secondary)
                }
            }
        }
        ForEach(offers) { offer in
            Section {
                planRow(offer, isCurrent: offer.tier == currentTier)
            }
        }
    }

    private func planRow(_ offer: AppleSubscriptionOffer, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(offer.name)
                    .font(.title3.bold())
                if isCurrent {
                    Text("Current plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .accessibilityIdentifier("plans.current.\(offer.tier)")
                }
                Spacer(minLength: 8)
                Text(offer.priceLine)
                    .font(.headline)
                    .multilineTextAlignment(.trailing)
            }
            Text(offer.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await coordinator.subscribe(to: offer.productId) }
            } label: {
                Text(isCurrent ? "Your plan" : "Subscribe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCurrent || !canAct)
            .accessibilityIdentifier("plans.subscribe.\(offer.tier)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plans.offer.\(offer.tier)")
    }

    private var canAct: Bool {
        if case .ready = coordinator.state { return true }
        return false
    }

    private var isPurchasing: Bool {
        if case .purchasing = coordinator.state { return true }
        return false
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { coordinator.notice != nil },
            set: { if !$0 { coordinator.dismissNotice() } }
        )
    }
}

/// Settings' Plan section: one row to the plans, there only while the server offers them.
struct PlanSettingsSection: View {
    @Environment(\.appleSubscriptions) private var subscriptions

    var body: some View {
        if let subscriptions {
            PlanSettingsRow(coordinator: subscriptions)
        }
    }
}

private struct PlanSettingsRow: View {
    @ObservedObject var coordinator: AppleSubscriptionsCoordinator

    var body: some View {
        if coordinator.isOffered {
            Section("Plan") {
                NavigationLink {
                    SubscriptionsView(coordinator: coordinator)
                } label: {
                    Label("Plans", systemImage: "star.circle")
                }
                .accessibilityIdentifier("settings.plan")
            }
        }
    }
}

private struct AppleSubscriptionsKey: EnvironmentKey {
    static let defaultValue: AppleSubscriptionsCoordinator? = nil
}

extension EnvironmentValues {
    /// The signed-in account's in-app plans. Nil (signed out, the fixture flow) shows no Plan section.
    var appleSubscriptions: AppleSubscriptionsCoordinator? {
        get { self[AppleSubscriptionsKey.self] }
        set { self[AppleSubscriptionsKey.self] = newValue }
    }
}
