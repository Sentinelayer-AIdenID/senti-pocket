#if DEBUG
import Foundation
import SwiftUI

/// DEBUG-only plans preview: `-PocketPlansPreview` opens the real plans screen and coordinator on sample offers, so the
/// screen can be run and screenshotted on a simulator, which has no App Store products.
/// - `-PocketPlansCurrentTier pro` sets the account's tier (any tier the server sends, `team` included).
/// - `-PocketPlansStanding web|apple|unknown|apple-id`: a web subscription, this account's App Store subscription, a
///   status that cannot be read, or this Apple ID holding a subscription that is not this account's.
/// - `-PocketPlansRefusal <server code>` has the server refuse an unfinished purchase with that code.
/// - `-PocketPlansSettingsPreview` opens Settings with its Plan row, the plans reaching it through the environment as
///   they do after sign-in.
/// Never compiled into Release, where every price is StoreKit's own.
enum PlansPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketPlansPreview") || isSettingsRequested
    }

    static var isSettingsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketPlansSettingsPreview")
    }

    private static var standing: String { UserDefaults.standard.string(forKey: "PocketPlansStanding") ?? "" }
    private static var refusal: String? { UserDefaults.standard.string(forKey: "PocketPlansRefusal") }

    @MainActor
    private static let coordinator = AppleSubscriptionsCoordinator(
        server: PlansPreviewServer(tier: UserDefaults.standard.string(forKey: "PocketPlansCurrentTier"),
                                   standing: standing, refusal: refusal),
        store: PlansPreviewStore(appleIDHoldsPlan: standing == "apple-id", hasUnfinishedPurchase: refusal != nil)
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
            .task { await coordinator.retryUnfinished() }
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
    let standing: String
    let refusal: String?

    func plans() async throws -> [AppleSubscriptionPlan] {
        [
            AppleSubscriptionPlan(productId: "com.plexaura.sentipocket.max.monthly", tier: "max"),
            AppleSubscriptionPlan(productId: "com.plexaura.sentipocket.pro.monthly", tier: "pro"),
        ]
    }

    func accountToken() async throws -> UUID { UUID() }

    func submit(signedTransactionInfo: String) async throws -> String {
        if let refusal {
            let status = ["APPLE_IAP_PRODUCT_NOT_ALLOWED": 400, "APPLE_IAP_INVALID_TRANSACTION": 400,
                          "APPLE_IAP_OWNERSHIP_CONFLICT": 409, "APPLE_IAP_ACCOUNT_NOT_FOUND": 409][refusal] ?? 403
            throw HTTPAppleSubscriptionsServer.refusal(status: status, code: refusal)
        }
        return tier ?? "free"
    }

    func accountStatus() async throws -> AppleSubscriptionsAccountStatus {
        if standing == "unknown" { throw AppleSubscriptionsServerError.unavailable }
        return AppleSubscriptionsAccountStatus(tier: tier, hasWebSubscription: standing == "web",
                                               hasAppleSubscription: standing == "apple")
    }
}

/// Sample products standing in for the App Store's, which a simulator without a StoreKit configuration cannot load.
private struct PlansPreviewStore: AppleStoreFront {
    let appleIDHoldsPlan: Bool
    let hasUnfinishedPurchase: Bool

    private static let sample = AppleStoreTransaction(id: 1, productId: "com.plexaura.sentipocket.pro.monthly",
                                                      signedTransactionInfo: "preview", isVerified: true, finish: {})

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

    func unfinished() async -> [AppleStoreTransaction] { hasUnfinishedPurchase ? [Self.sample] : [] }

    func currentEntitlements() async -> [AppleStoreTransaction] { appleIDHoldsPlan ? [Self.sample] : [] }

    func sync() async throws {}
}
#endif
