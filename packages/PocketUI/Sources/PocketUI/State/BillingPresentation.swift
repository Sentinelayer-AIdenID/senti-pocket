import Foundation

/// "Plan & billing" (Carter, 10-31: "Pocket and web should use same stripe billing key. Everything should be the
/// same"): the plan, usage and balance the web's Billing page shows, worked out the way it works them out. Payment
/// happens on sentinelayer.com, on the same Stripe account; Pocket never holds a payment key.
public struct BillingState: Equatable, Sendable {
    /// The plan in force, as the web's `activePlanCode()` picks it: free, trial, pro, max, team or enterprise.
    public var planCode: String
    /// The subscription's own status (active, trialing, past_due, canceled, none), when there is one.
    public var status: String?
    public var periodEnd: Date?
    public var trialEndsAt: Date?
    /// The subscription stops at the end of this period instead of renewing.
    public var endsAtPeriodEnd: Bool
    /// Units used this period (included, trial, wallet and overage), and units still available.
    public var used: Int
    public var available: Int
    public var overageCents: Int
    /// A subscription Stripe's portal can manage (cancel, change card, invoices).
    public var canManage: Bool
    public var isLoading: Bool
    /// False until the server has answered with a plan.
    public var isAvailable: Bool
    public var notice: String?

    public init(planCode: String = "free", status: String? = nil, periodEnd: Date? = nil, trialEndsAt: Date? = nil,
                endsAtPeriodEnd: Bool = false, used: Int = 0, available: Int = 0, overageCents: Int = 0,
                canManage: Bool = false, isLoading: Bool = false, isAvailable: Bool = false, notice: String? = nil) {
        self.planCode = planCode
        self.status = status
        self.periodEnd = periodEnd
        self.trialEndsAt = trialEndsAt
        self.endsAtPeriodEnd = endsAtPeriodEnd
        self.used = used
        self.available = available
        self.overageCents = overageCents
        self.canManage = canManage
        self.isLoading = isLoading
        self.isAvailable = isAvailable
        self.notice = notice
    }

    public var planName: String { BillingPlans.name(planCode) }

    /// How much of this period's units are used, 0 to 1, as the web's gauge: used / (used + available).
    public var fraction: Double {
        Double(max(used, 0)) / Double(max(max(used, 0) + max(available, 0), 1))
    }

    /// The plan the Upgrade button offers, or nil at the top.
    public var nextPlanCode: String? { BillingPlans.next(after: planCode) }

    /// "Renews Nov 15", "Ends Nov 15", "Trial ends Nov 2", or nothing.
    public func dateLine(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        if planCode == "trial" || status == "trialing", let trialEndsAt {
            return "Trial ends \(formatter.string(from: trialEndsAt))"
        }
        guard let periodEnd, ["active", "trialing", "past_due"].contains(status ?? "") else { return nil }
        return (endsAtPeriodEnd ? "Ends " : "Renews ") + formatter.string(from: periodEnd)
    }
}

/// The plans as the API names them. Prices are not here: they live on the server, and the web's Billing page shows
/// them, so the phone never shows a price of its own.
public enum BillingPlans {
    /// Lowest to highest; a self-serve upgrade goes one step up.
    public static let order = ["free", "trial", "pro", "max", "team", "enterprise"]

    public static func name(_ code: String) -> String {
        switch code.lowercased() {
        case "free": return "Free"
        case "trial": return "Trial"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return code.isEmpty ? "Free" : code.prefix(1).uppercased() + code.dropFirst()
        }
    }

    /// The next self-serve plan: Pro from Free or a trial, then Max, then Team. Enterprise is by arrangement.
    public static func next(after code: String) -> String? {
        switch code.lowercased() {
        case "free", "trial", "": return "pro"
        case "pro": return "max"
        case "max": return "team"
        default: return nil
        }
    }

    /// The web's rule (`Billing.tsx` `activePlanCode`): the subscription's plan while it is active or trialing, else
    /// the account's plan, else the legacy membership tier, else free.
    public static func activePlanCode(subscriptionPlan: String?, subscriptionStatus: String?, accountPlan: String?,
                                      membershipTier: String?) -> String {
        func present(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
                return nil
            }
            return value
        }
        if let plan = present(subscriptionPlan), ["active", "trialing"].contains(present(subscriptionStatus) ?? "") {
            return plan
        }
        return present(accountPlan) ?? present(membershipTier) ?? "free"
    }

    /// The web's Billing page with a plan chosen, where checkout happens on the same Stripe account as the web.
    public static func upgradeURL(webBase: URL, plan: String) -> URL? {
        var components = URLComponents(url: webBase, resolvingAgainstBaseURL: false)
        components?.path = "/dashboard/billing"
        components?.queryItems = [URLQueryItem(name: "plan", value: plan)]
        return components?.url
    }

    /// The web's plans and prices.
    public static func plansURL(webBase: URL) -> URL? {
        var components = URLComponents(url: webBase, resolvingAgainstBaseURL: false)
        components?.path = "/pricing"
        components?.queryItems = nil
        return components?.url
    }
}

public enum BillingIntent: Equatable, Sendable {
    case refresh
    case upgrade(plan: String)
    case manage
    case plans
}
