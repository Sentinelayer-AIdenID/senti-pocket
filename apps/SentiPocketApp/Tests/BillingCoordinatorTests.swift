import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class FakeBilling: BillingAPI, @unchecked Sendable {
    var snapshot: Result<BillingSnapshot, BillingClient.Failure>
    var portal: Result<URL, BillingClient.Failure>

    init(snapshot: Result<BillingSnapshot, BillingClient.Failure>, portal: Result<URL, BillingClient.Failure>) {
        self.snapshot = snapshot
        self.portal = portal
    }

    func status() async throws -> BillingSnapshot { try snapshot.get() }
    func portalURL() async throws -> URL { try portal.get() }
}

/// Carter (10-31): "Pocket and web should use same stripe billing key. Everything should be the same." Pocket reads
/// the web Billing page's two answers and opens the web's payment pages in Safari; it never takes a payment itself.
@MainActor
final class BillingCoordinatorTests: XCTestCase {
    /// The two answers as the API shapes them (`schemas/billing.py`): v2 for plan, usage and balances, v1 for the
    /// membership tier and the subscription to manage.
    private func answers(status: String = "active", cancel: Bool = false) -> (JSONValue, JSONValue) {
        let v2 = """
        {"has_account": true, "metering_mode": "enforce", "billing_exempt": false,
         "account": {"id": "6f1c", "current_plan_code": "pro", "trial_ends_at": null, "wallet_state": "active"},
         "subscription": {"plan_code": "pro", "status": "\(status)", "current_period_start": "2026-10-15T00:00:00Z",
                          "current_period_end": "2026-11-15T00:00:00Z", "cancel_at_period_end": \(cancel)},
         "usage": {"included_ru_granted": 120, "included_ru_used": 30, "trial_ru_used": 0, "wallet_ru_used": 4,
                   "overage_ru_used": 0, "overage_cost_cents": 0},
         "balances": {"included": 86, "trial": 0, "wallet": 0, "total": 86}}
        """
        let v1 = """
        {"membership_tier": "pro", "active_subscription": {"status": "\(status)", "cancel_at_period_end": \(cancel)}}
        """
        return (try! JSONDecoder().decode(JSONValue.self, from: Data(v2.utf8)),
                try! JSONDecoder().decode(JSONValue.self, from: Data(v1.utf8)))
    }

    func test_the_plan_usage_and_renewal_read_as_the_web_reads_them() {
        let (v2, v1) = answers()
        let state = BillingSnapshot(v2: v2, v1: v1).state
        XCTAssertEqual(state.planCode, "pro")
        XCTAssertEqual(state.used, 34, "included, trial, wallet and overage units together")
        XCTAssertEqual(state.available, 86)
        XCTAssertTrue(state.canManage)
        XCTAssertFalse(state.endsAtPeriodEnd)
        XCTAssertEqual(state.periodEnd, ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z"))

        let (cancelling, legacy) = answers(cancel: true)
        XCTAssertTrue(BillingSnapshot(v2: cancelling, v1: legacy).state.endsAtPeriodEnd)

        let free = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"has_account": false}"#.utf8))
        let freeState = BillingSnapshot(v2: free, v1: nil).state
        XCTAssertEqual(freeState.planCode, "free", "no account and no subscription: free")
        XCTAssertFalse(freeState.canManage, "nothing to manage")
        XCTAssertEqual(freeState.nextPlanCode, "pro")
    }

    func test_upgrade_and_manage_open_the_webs_pages_in_the_browser() async {
        var opened: [URL] = []
        let portal = URL(string: "https://billing.stripe.com/p/session/test_portal")!
        let coordinator = BillingCoordinator(api: FakeBilling(snapshot: .success(BillingSnapshot()), portal: .success(portal)),
                                             openExternally: { opened.append($0) })
        coordinator.send(.upgrade(plan: "max"))
        XCTAssertEqual(opened.last?.absoluteString, "https://sentinelayer.com/dashboard/billing?plan=max")
        coordinator.send(.plans)
        XCTAssertEqual(opened.last?.absoluteString, "https://sentinelayer.com/pricing")
        coordinator.send(.manage)
        for _ in 0..<200 where opened.count < 3 { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(opened.last, portal, "Manage opens Stripe's portal link from the API")
    }

    func test_a_refresh_shows_the_plan_and_a_signed_out_answer_asks_to_sign_in_again() async {
        let (v2, v1) = answers()
        var reauth = 0
        let fake = FakeBilling(snapshot: .success(BillingSnapshot(v2: v2, v1: v1)), portal: .failure(.unreadable))
        let coordinator = BillingCoordinator(api: fake, openExternally: { _ in }, onReauthenticationRequired: { reauth += 1 })
        await coordinator.refresh()
        XCTAssertTrue(coordinator.state.isAvailable)
        XCTAssertEqual(coordinator.state.planName, "Pro")
        XCTAssertNil(coordinator.state.notice)

        coordinator.send(.manage)
        for _ in 0..<200 where coordinator.state.notice == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(coordinator.state.notice, "Manage subscription could not open. Try again, or use the web's Billing page.")

        fake.snapshot = .failure(.refused(401))
        await coordinator.refresh()
        XCTAssertEqual(reauth, 1)
        fake.snapshot = .failure(.refused(500))
        await coordinator.refresh()
        XCTAssertTrue(coordinator.state.isAvailable, "a failed refresh keeps the plan it had")
        XCTAssertEqual(coordinator.state.notice, "Could not update your plan. Pull to try again.")
    }
}
