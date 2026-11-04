#if DEBUG
import Foundation
import SwiftUI

/// DEBUG-only plans preview: `-PocketPlansPreview` opens the real plans screen and coordinator on sample offers, so the
/// screen can be run and screenshotted on a simulator, which has no App Store products. `-PocketPlansCurrentTier pro`
/// marks a current plan; `-PocketPlansSettingsPreview` opens Settings with its Plan row, the plans reaching it through
/// the environment as they do after sign-in. Never compiled into Release, where every price is StoreKit's own.
enum PlansPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketPlansPreview") || isSettingsRequested
    }

    static var isSettingsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketPlansSettingsPreview")
    }

    @MainActor
    private static let coordinator = AppleSubscriptionsCoordinator(
        server: PlansPreviewServer(tier: UserDefaults.standard.string(forKey: "PocketPlansCurrentTier")),
        store: PlansPreviewStore()
    )

    @MainActor
    @ViewBuilder
    static func rootView(whisperModel: WhisperModelProvisioningCoordinator) -> some View {
        if isSettingsRequested {
            PlansPreviewSettingsHost(whisperModel: whisperModel, coordinator: coordinator)
        } else {
            NavigationStack {
                SubscriptionsView(coordinator: coordinator)
            }
        }
    }
}

/// Settings presented as a sheet, the plans set on the environment outside it, as the signed-in root does.
private struct PlansPreviewSettingsHost: View {
    @ObservedObject var whisperModel: WhisperModelProvisioningCoordinator
    let coordinator: AppleSubscriptionsCoordinator
    @State private var presentsSettings = false

    var body: some View {
        Color.clear
            .sheet(isPresented: $presentsSettings) {
                WhisperModelSettingsView(coordinator: whisperModel, onSignOut: {})
            }
            .environment(\.appleSubscriptions, coordinator)
            .task {
                await coordinator.refresh()
                presentsSettings = true
            }
    }
}

private struct PlansPreviewServer: AppleSubscriptionsServing {
    let tier: String?

    func plans() async throws -> [AppleSubscriptionPlan] {
        [
            AppleSubscriptionPlan(productId: "com.plexaura.sentipocket.max.monthly", tier: "max"),
            AppleSubscriptionPlan(productId: "com.plexaura.sentipocket.pro.monthly", tier: "pro"),
        ]
    }

    func accountToken() async throws -> UUID { UUID() }

    func submit(signedTransactionInfo: String) async throws -> String? { nil }

    func currentTier() async throws -> String? { tier }
}

/// Sample products standing in for the App Store's, which a simulator without a StoreKit configuration cannot load.
private struct PlansPreviewStore: AppleStoreFront {
    func products(for ids: [String]) async throws -> [AppleStoreProduct] {
        [
            AppleStoreProduct(id: "com.plexaura.sentipocket.pro.monthly", displayName: "Pro", description: "",
                              displayPrice: "$29.00", price: 29, period: .init(unit: .month, value: 1)),
            AppleStoreProduct(id: "com.plexaura.sentipocket.max.monthly", displayName: "Max", description: "",
                              displayPrice: "$99.00", price: 99, period: .init(unit: .month, value: 1)),
        ].filter { ids.contains($0.id) }
    }

    func purchase(productId: String, appAccountToken: UUID) async throws -> AppleStorePurchaseOutcome { .cancelled }

    func updates() -> AsyncStream<AppleStoreTransaction> { AsyncStream { _ in } }

    func unfinished() async -> [AppleStoreTransaction] { [] }

    func currentEntitlements() async -> [AppleStoreTransaction] { [] }

    func sync() async throws {}
}
#endif
