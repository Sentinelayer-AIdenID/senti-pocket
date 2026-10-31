import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// What the billing API says, as "Plan & billing" needs it: the web Billing page's two reads, `GET
/// /billing/v2/status` (plan, usage, balances) and `GET /billing/status` (the legacy membership tier and whether a
/// subscription exists to manage).
struct BillingSnapshot: Equatable, Sendable {
    var subscriptionPlan: String?
    var subscriptionStatus: String?
    var periodEnd: Date?
    var cancelAtPeriodEnd = false
    var accountPlan: String?
    var trialEndsAt: Date?
    var used = 0
    var available = 0
    var overageCents = 0
    var membershipTier: String?
    var hasActiveSubscription = false

    /// Reads the two answers; a field the server leaves out is simply absent.
    init(v2: JSONValue, v1: JSONValue?) {
        let subscription = v2["subscription"]
        subscriptionPlan = subscription?["plan_code"]?.stringValue
        subscriptionStatus = subscription?["status"]?.stringValue
        periodEnd = subscription?["current_period_end"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date }
        cancelAtPeriodEnd = subscription?["cancel_at_period_end"]?.boolValue ?? false
        accountPlan = v2["account"]?["current_plan_code"]?.stringValue
        trialEndsAt = v2["account"]?["trial_ends_at"]?.stringValue.flatMap { ParsedSessionTimestamp($0).date }
        let usage = v2["usage"]
        // Used is what the web's gauge counts: included, trial, wallet and overage units.
        used = ["included_ru_used", "trial_ru_used", "wallet_ru_used", "overage_ru_used"]
            .reduce(0) { $0 + max(0, usage?[$1]?.intValue ?? 0) }
        available = max(0, v2["balances"]?["total"]?.intValue ?? 0)
        overageCents = max(0, usage?["overage_cost_cents"]?.intValue ?? 0)
        membershipTier = v1?["membership_tier"]?.stringValue
        // The web enables Manage subscription when the legacy status carries a subscription.
        hasActiveSubscription = v1?["active_subscription"]?.objectValue != nil
            || ["active", "trialing", "past_due"].contains(subscriptionStatus ?? "")
    }

    init() {}

    var state: BillingState {
        BillingState(
            planCode: BillingPlans.activePlanCode(subscriptionPlan: subscriptionPlan, subscriptionStatus: subscriptionStatus,
                                                  accountPlan: accountPlan, membershipTier: membershipTier),
            status: subscriptionStatus,
            periodEnd: periodEnd,
            trialEndsAt: trialEndsAt,
            endsAtPeriodEnd: cancelAtPeriodEnd,
            used: used,
            available: available,
            overageCents: overageCents,
            canManage: hasActiveSubscription,
            isAvailable: true
        )
    }
}

/// The billing API, as the signed-in person. A protocol so the coordinator is testable without a network.
protocol BillingAPI: Sendable {
    func status() async throws -> BillingSnapshot
    /// A Stripe customer portal link for the person's subscription.
    func portalURL() async throws -> URL
}

struct BillingClient: BillingAPI {
    let apiBaseURL: URL?
    var urlSession: URLSession = SentiHTTPTransportPolicy.liveSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    enum Failure: Error, Equatable { case notConfigured, signedOut, refused(Int), unreachable, unreadable }

    func status() async throws -> BillingSnapshot {
        let v2Data = try await send("GET", path: "/api/v1/billing/v2/status", body: nil)
        guard let v2 = try? JSONDecoder().decode(JSONValue.self, from: v2Data), v2.objectValue != nil else {
            throw Failure.unreadable
        }
        // The legacy status adds the membership tier and the subscription to manage; without it the plan still shows.
        var v1: JSONValue?
        if let data = try? await send("GET", path: "/api/v1/billing/status", body: nil) {
            v1 = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        return BillingSnapshot(v2: v2, v1: v1)
    }

    func portalURL() async throws -> URL {
        // The return path is the web's Billing page: the API only returns to its own web address.
        let data = try await send("POST", path: "/api/v1/billing/portal-session", body: ["return_path": "/dashboard/billing"])
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let link = json["url"]?.stringValue, let url = URL(string: link), url.scheme == "https" else {
            throw Failure.unreadable
        }
        return url
    }

    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw Failure.notConfigured
        }
        guard let bearer = tokenProvider(), !bearer.isEmpty else { throw Failure.signedOut }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status) }
        return data
    }
}

/// "Plan & billing" (Carter, 10-31: "Pocket and web should use same stripe billing key. Everything should be the
/// same"): the same reads as the web's Billing page, and its links. Upgrading opens the web's Billing page with the
/// plan chosen, and Manage opens Stripe's portal, both in Safari: Pocket never takes a payment itself (the App Store
/// allows a link out to web checkout in the US).
@MainActor
final class BillingCoordinator: ObservableObject {
    @Published private(set) var state = BillingState()

    private let api: any BillingAPI
    private let webBase: URL
    /// Opens a link in the browser (Safari), outside the app.
    private let openExternally: @MainActor (URL) -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    init(api: any BillingAPI, webBase: URL = URL(string: "https://sentinelayer.com")!,
         openExternally: @escaping @MainActor (URL) -> Void,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.api = api
        self.webBase = webBase
        self.openExternally = openExternally
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func send(_ intent: BillingIntent) {
        switch intent {
        case .refresh:
            Task { await refresh() }
        case .upgrade(let plan):
            if let url = BillingPlans.upgradeURL(webBase: webBase, plan: plan) { openExternally(url) }
        case .plans:
            if let url = BillingPlans.plansURL(webBase: webBase) { openExternally(url) }
        case .manage:
            Task { await openPortal() }
        }
    }

    func refresh() async {
        state.isLoading = true
        do {
            let snapshot = try await api.status()
            state = snapshot.state
        } catch BillingClient.Failure.signedOut, BillingClient.Failure.refused(401) {
            state.isLoading = false
            onReauthenticationRequired()
            return
        } catch {
            state.notice = state.isAvailable
                ? "Could not update your plan. Pull to try again."
                : "Your plan could not be read just now. Pull to try again."
        }
        state.isLoading = false
    }

    private func openPortal() async {
        do {
            openExternally(try await api.portalURL())
        } catch BillingClient.Failure.signedOut, BillingClient.Failure.refused(401) {
            onReauthenticationRequired()
        } catch {
            state.notice = "Manage subscription could not open. Try again, or use the web's Billing page."
        }
    }
}
