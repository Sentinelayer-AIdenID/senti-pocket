import Foundation
import XCTest
@testable import PocketUI

/// Carter (10-31): "Pocket and web should use same stripe billing key. Everything should be the same." The plan and
/// usage are worked out the way the web's Billing page works them out.
final class BillingPresentationTests: XCTestCase {
    func test_the_plan_in_force_follows_the_webs_rule() {
        XCTAssertEqual(BillingPlans.activePlanCode(subscriptionPlan: "max", subscriptionStatus: "active",
                                                   accountPlan: "pro", membershipTier: "free"), "max")
        XCTAssertEqual(BillingPlans.activePlanCode(subscriptionPlan: "pro", subscriptionStatus: "trialing",
                                                   accountPlan: nil, membershipTier: nil), "pro")
        XCTAssertEqual(BillingPlans.activePlanCode(subscriptionPlan: "max", subscriptionStatus: "canceled",
                                                   accountPlan: "pro", membershipTier: "team"), "pro",
                       "a subscription not in force gives way to the account's plan")
        XCTAssertEqual(BillingPlans.activePlanCode(subscriptionPlan: nil, subscriptionStatus: nil,
                                                   accountPlan: " ", membershipTier: "Team"), "team")
        XCTAssertEqual(BillingPlans.activePlanCode(subscriptionPlan: nil, subscriptionStatus: nil,
                                                   accountPlan: nil, membershipTier: nil), "free")
    }

    func test_usage_is_the_webs_gauge_and_the_upgrade_goes_one_step_up() {
        let state = BillingState(planCode: "pro", used: 34, available: 86)
        XCTAssertEqual(state.fraction, 34.0 / 120.0, accuracy: 0.0001)
        XCTAssertEqual(BillingState(used: 0, available: 0).fraction, 0, "nothing granted, nothing used: empty, not NaN")
        XCTAssertEqual(state.planName, "Pro")
        XCTAssertEqual(state.nextPlanCode, "max")
        XCTAssertEqual(BillingPlans.next(after: "trial"), "pro")
        XCTAssertEqual(BillingPlans.next(after: "max"), "team")
        XCTAssertNil(BillingPlans.next(after: "team"))
        XCTAssertNil(BillingPlans.next(after: "enterprise"))
    }

    func test_the_links_go_to_the_webs_billing_and_pricing_pages() {
        let web = URL(string: "https://sentinelayer.com")!
        XCTAssertEqual(BillingPlans.upgradeURL(webBase: web, plan: "max")?.absoluteString,
                       "https://sentinelayer.com/dashboard/billing?plan=max")
        XCTAssertEqual(BillingPlans.plansURL(webBase: web)?.absoluteString, "https://sentinelayer.com/pricing")
    }

    func test_the_date_line_says_renews_ends_or_trial() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let end = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!
        XCTAssertEqual(BillingState(planCode: "pro", status: "active", periodEnd: end)
            .dateLine(calendar: calendar, locale: locale), "Renews Nov 15")
        XCTAssertEqual(BillingState(planCode: "pro", status: "active", periodEnd: end, endsAtPeriodEnd: true)
            .dateLine(calendar: calendar, locale: locale), "Ends Nov 15")
        XCTAssertEqual(BillingState(planCode: "trial", trialEndsAt: end).dateLine(calendar: calendar, locale: locale),
                       "Trial ends Nov 15")
        XCTAssertNil(BillingState(planCode: "free").dateLine(calendar: calendar, locale: locale))
        XCTAssertNil(BillingState(planCode: "pro", status: "canceled", periodEnd: end)
            .dateLine(calendar: calendar, locale: locale), "a canceled subscription renews nothing")
    }
}
