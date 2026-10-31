#if canImport(SwiftUI)
import SwiftUI

/// "Plan & billing": your plan, this period's usage and what's left, as the web's Billing page shows them. Upgrading
/// and managing the subscription happen on sentinelayer.com, on the same account as the web (Carter, 10-31).
public struct BillingView: View {
    private let state: BillingState
    private let send: (BillingIntent) -> Void
    private let close: () -> Void

    public init(state: BillingState, send: @escaping (BillingIntent) -> Void, close: @escaping () -> Void) {
        self.state = state
        self.send = send
        self.close = close
    }

    public var body: some View {
        NavigationStack {
            List {
                if !state.isAvailable {
                    Text(state.isLoading ? "Looking…" : "Your plan shows here once the server answers.")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .listRowBackground(PocketPalette.raised)
                        .accessibilityIdentifier("pocket.billing.unavailable")
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.planName)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(PocketPalette.textPrimary)
                                .accessibilityIdentifier("pocket.billing.plan")
                            if let line = state.dateLine() {
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundStyle(state.endsAtPeriodEnd ? PocketPalette.warning : PocketPalette.textSecondary)
                            }
                            if state.status == "past_due" {
                                Text("Your last payment didn't go through. Update it in Manage subscription.")
                                    .font(.footnote)
                                    .foregroundStyle(PocketPalette.warning)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Plan")
                    }
                    .listRowBackground(PocketPalette.raised)

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: state.fraction)
                                .tint(state.fraction >= 0.9 ? PocketPalette.warning : PocketPalette.accent)
                                .accessibilityLabel("Usage this period")
                                .accessibilityValue("\(Int((state.fraction * 100).rounded())) percent used")
                            HStack {
                                Text("\(state.used.formatted()) used")
                                Spacer()
                                Text("\(state.available.formatted()) left")
                            }
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(PocketPalette.textSecondary)
                            if state.overageCents > 0 {
                                Text("Over the plan this period: \((Double(state.overageCents) / 100).formatted(.currency(code: "USD")))")
                                    .font(.footnote)
                                    .foregroundStyle(PocketPalette.warning)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("This period")
                    }
                    .listRowBackground(PocketPalette.raised)

                    Section {
                        if let next = state.nextPlanCode {
                            Button { send(.upgrade(plan: next)) } label: {
                                Label("Upgrade to \(BillingPlans.name(next))", systemImage: "arrow.up.circle")
                            }
                            .accessibilityIdentifier("pocket.billing.upgrade")
                        }
                        if state.canManage {
                            Button { send(.manage) } label: {
                                Label("Manage subscription", systemImage: "creditcard")
                            }
                            .accessibilityIdentifier("pocket.billing.manage")
                        }
                        Button { send(.plans) } label: {
                            Label("Plans and prices", systemImage: "list.bullet.rectangle")
                        }
                        .accessibilityIdentifier("pocket.billing.plans")
                    } footer: {
                        Text("These open sentinelayer.com in Safari. Payment uses the same account as the web.")
                    }
                    .listRowBackground(PocketPalette.raised)
                }
                if let notice = state.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.warning)
                        .listRowBackground(PocketPalette.raised)
                        .accessibilityIdentifier("pocket.billing.notice")
                }
            }
            .scrollContentBackground(.hidden)
            .pocketCanvas()
            .refreshable { send(.refresh) }
            .navigationTitle("Plan & billing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
        .accessibilityIdentifier("pocket.billing.screen")
    }
}
#endif
