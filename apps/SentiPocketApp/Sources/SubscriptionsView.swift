import StoreKit
import SwiftUI

/// The in-app plans: each plan's name, what it adds and its App Store price per period with a Subscribe button, the
/// current plan marked, Restore purchases, how renewal works, and the Terms of Use and Privacy Policy. Nothing is for
/// sale while a subscription runs or the account's plan could not be read, and no plan at or below the account's.
struct SubscriptionsView: View {
    @ObservedObject var coordinator: AppleSubscriptionsCoordinator
    @State private var managesSubscription = false

    /// Apple's standard license agreement.
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://sentinelayer.com/privacy")!

    /// The renewal terms, the period taken from the App Store's products.
    static func renewalTerms(for offers: [AppleSubscriptionOffer]) -> String {
        "Payment is charged to your Apple ID when you confirm the purchase. Your plan renews "
            + "\(AppleSubscriptionOffer.renewal(of: offers)) at the price shown unless you cancel at least 24 hours "
            + "before the current period ends; the renewal is charged within the 24 hours before it ends. Manage or "
            + "cancel your plan in Settings, under your name, then Subscriptions."
    }

    /// Why nothing is for sale, in one plain line, or nil while plans above the account's can be bought.
    static func standingText(_ standing: AppleSubscriptionsStanding) -> String? {
        switch standing {
        case .open:
            return nil
        case .unknown:
            return "Couldn't check your plan. Try again."
        case .appleSubscription:
            return "Your plan is active. To change or cancel it, tap Manage subscription."
        case .webSubscription:
            return "Your plan is billed through the Senti website. Manage or cancel it there."
        case .appleIDHoldsAnother:
            return "This Apple ID already has a Senti subscription that isn't on this account. If you bought it for "
                + "this account, tap Restore purchases."
        }
    }

    /// What VoiceOver reads for a plan's button: the plan, its price, and what the button does.
    static func buttonLabel(for offer: AppleSubscriptionOffer, in plans: AppleSubscriptionsPlans) -> String {
        if offer.tier == plans.currentTier { return "\(offer.name), your plan, \(offer.priceLine)" }
        if plans.isIncluded(offer) { return "\(offer.name), included in your plan" }
        return "Subscribe to \(offer.name), \(offer.priceLine)"
    }

    var body: some View {
        List {
            if let line = coordinator.line {
                Section {
                    Text(line.text)
                        .accessibilityIdentifier("plans.line")
                }
            }
            switch coordinator.state {
            case .ready(let plans), .purchasing(let plans):
                planSections(plans)
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
                    Text(Self.renewalTerms(for: offersOnScreen))
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
        .manageSubscriptionsSheet(isPresented: $managesSubscription)
        .alert("Plans", isPresented: noticeIsPresented) {
            Button("OK") { coordinator.dismissNotice() }
        } message: {
            Text(coordinator.notice ?? "")
        }
    }

    @ViewBuilder
    private func planSections(_ plans: AppleSubscriptionsPlans) -> some View {
        if let text = Self.standingText(plans.standing) {
            Section {
                Text(text)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("plans.standing")
                if plans.standing == .unknown {
                    Button("Try again") { Task { await coordinator.refresh() } }
                        .disabled(!canAct)
                        .accessibilityIdentifier("plans.retry-status")
                }
                if plans.standing == .appleSubscription || plans.standing == .appleIDHoldsAnother {
                    Button("Manage subscription") { managesSubscription = true }
                        .accessibilityIdentifier("plans.manage")
                }
            }
        }
        if isPurchasing {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for the App Store")
                        .foregroundStyle(.secondary)
                }
            }
        }
        ForEach(plans.offers) { offer in
            Section {
                planRow(offer, in: plans)
            }
        }
    }

    private func planRow(_ offer: AppleSubscriptionOffer, in plans: AppleSubscriptionsPlans) -> some View {
        let isCurrent = offer.tier == plans.currentTier
        let isIncluded = plans.isIncluded(offer)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(offer.name)
                    .font(.title3.bold())
                if isCurrent {
                    Text("Current plan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
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
                Text(isCurrent ? "Your plan" : isIncluded ? "Included in your plan" : "Subscribe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!plans.canBuy(offer) || !canAct)
            .accessibilityLabel(Self.buttonLabel(for: offer, in: plans))
            .accessibilityIdentifier("plans.subscribe.\(offer.tier)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plans.offer.\(offer.tier)")
    }

    private var offersOnScreen: [AppleSubscriptionOffer] {
        switch coordinator.state {
        case .ready(let plans), .purchasing(let plans): return plans.offers
        case .hidden, .loading, .failed: return []
        }
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
