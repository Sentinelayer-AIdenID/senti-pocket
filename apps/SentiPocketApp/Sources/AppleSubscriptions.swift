import Combine
import Foundation
import StoreKit
import UIKit

// MARK: - The server

/// A plan the server sells in the app: the App Store product and the account tier it gives.
struct AppleSubscriptionPlan: Equatable, Sendable {
    let productId: String
    let tier: String
}

/// The account's plan as `GET /api/v1/billing/status` tells it.
struct AppleSubscriptionsAccountStatus: Equatable, Sendable {
    /// `membership_tier`: the account's plan, however it was bought or granted.
    let tier: String?
    /// `active_subscription` is set: a subscription billed through the Senti website is running.
    let hasWebSubscription: Bool
    /// `apple_subscription` is set: this account's own App Store subscription is running, on any Apple ID.
    let hasAppleSubscription: Bool
}

/// Why a call to the server's in-app plans gave no answer the app can use. The transaction refusals follow the
/// server's codes (`{"detail": {"error": {"code"}}}`); only three of them finish the transaction.
enum AppleSubscriptionsServerError: Error, Equatable {
    /// 404 (the route is missing: the feature is off or not deployed), or no API configured: the app shows nothing.
    case off
    /// 401, or 403 `APPLE_IAP_SIGNED_IN_SESSION_REQUIRED`: sign in again.
    case reauthenticationRequired
    /// Another account signed in while the call was out, so its answer belongs to nobody on screen.
    case accountChanged
    /// `APPLE_IAP_ACCOUNT_TOKEN_MISMATCH` (another account's token) or `APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH` (Apple's
    /// subscription already belongs to another Senti account).
    case linkedToAnotherAccount
    /// 409 `APPLE_IAP_OWNERSHIP_CONFLICT`: the server's ownership records disagree; a support case.
    case ownershipConflict
    /// 409 `APPLE_IAP_ACCOUNT_NOT_FOUND`: the signed-in account is missing or deleted.
    case accountNotFound
    /// 403 `APPLE_IAP_SANDBOX_NOT_ALLOWED`: a test purchase from an account not allowed to make them. Recorded, and
    /// credited if the account is allowed later and the app sends it again.
    case sandboxNotAllowed
    /// 403 `APPLE_IAP_FAMILY_SHARING_NOT_SUPPORTED`: recorded; never grants a plan.
    case familySharingNotSupported
    /// 400 `APPLE_IAP_PRODUCT_NOT_ALLOWED`: recorded; never grants a plan.
    case productNotAllowed
    /// 400 `APPLE_IAP_INVALID_TRANSACTION`: never grants a plan.
    case invalidTransaction
    /// Any other 4xx: the server would not take it.
    case refused
    /// Network, 408, 425, 429 or 5xx, or an answer the app could not read: nothing changed; try again later.
    case unavailable

    /// Whether a transaction the server answered this way is finished. Only when the server says it will never grant
    /// a plan (family sharing, a product not sold, an invalid transaction), so the App Store stops delivering it. Every
    /// other answer leaves it unfinished, so it comes back: a test purchase is credited once the account is allowed,
    /// and a support case keeps its transaction.
    var finishesTransaction: Bool {
        switch self {
        case .familySharingNotSupported, .productNotAllowed, .invalidTransaction:
            return true
        case .sandboxNotAllowed, .ownershipConflict, .accountNotFound, .linkedToAnotherAccount, .refused:
            return false
        case .off, .reauthenticationRequired, .accountChanged, .unavailable:
            return false
        }
    }
}

/// The server half of in-app plans, as the signed-in person. A protocol so the coordinator is testable without a
/// network.
protocol AppleSubscriptionsServing: Sendable {
    /// The plans the server sells here, in its order. Throws `.off` when it sells none.
    func plans() async throws -> [AppleSubscriptionPlan]
    /// This account's own purchase token. It goes into every purchase, so the server can tell whose a transaction is.
    func accountToken() async throws -> UUID
    /// Hands a verified transaction's signed form to the server. Returns the account's tier after it; an answer that
    /// carries no readable entitlement throws, because only that answer means the server applied the transaction.
    func submit(signedTransactionInfo: String) async throws -> String
    /// The account's plan now, and which subscriptions are running.
    func accountStatus() async throws -> AppleSubscriptionsAccountStatus
}

/// `/api/v1/billing/apple/*` with the user's own bearer, built as `HTTPAccountIdentity` builds its request: the path set
/// on the API origin, and the answer used only if the same token is still signed in. Requests go through the protected
/// read session, as the app's other authenticated reads do: no URL cache, cookies or credential store.
final class HTTPAppleSubscriptionsServer: AppleSubscriptionsServing, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.protectedReadSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    /// `GET /api/v1/billing/apple/products` → `[{"productId": "...", "tier": "pro"}]`. An answer that is not that list
    /// reads as off: the app never offers a purchase the server did not plainly list.
    func plans() async throws -> [AppleSubscriptionPlan] {
        let data = try await send("GET", path: "/api/v1/billing/apple/products")
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppleSubscriptionsServerError.off
        }
        return rows.compactMap { row in
            guard let productId = row["productId"] as? String, !productId.isEmpty,
                  let tier = row["tier"] as? String, !tier.isEmpty else { return nil }
            return AppleSubscriptionPlan(productId: productId, tier: tier.lowercased())
        }
    }

    /// `GET /api/v1/billing/apple/account-token` → `{"appAccountToken": "<uuid>"}`.
    func accountToken() async throws -> UUID {
        let data = try await send("GET", path: "/api/v1/billing/apple/account-token")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["appAccountToken"] as? String,
              let token = UUID(uuidString: text) else {
            throw AppleSubscriptionsServerError.unavailable
        }
        return token
    }

    /// `POST /api/v1/billing/apple/transactions` `{"signedTransactionInfo": "<JWS>"}`. The server answers with the
    /// account's entitlements (`EntitlementsResponse`, `tier` at the top), the same 200 when the transaction was already
    /// applied to this account. A 2xx without a readable `tier` is not taken as applied: it reads as unavailable, so
    /// the transaction stays unfinished and is sent again.
    func submit(signedTransactionInfo: String) async throws -> String {
        let data = try await send("POST", path: "/api/v1/billing/apple/transactions",
                                  body: ["signedTransactionInfo": signedTransactionInfo])
        guard let tier = Self.entitlementTier(in: data) else { throw AppleSubscriptionsServerError.unavailable }
        return tier
    }

    /// `GET /api/v1/billing/status` → `membership_tier`; `active_subscription` (web) and `apple_subscription` (App
    /// Store), each an object while that subscription is running and null otherwise.
    func accountStatus() async throws -> AppleSubscriptionsAccountStatus {
        let data = try await send("GET", path: "/api/v1/billing/status")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppleSubscriptionsServerError.unavailable
        }
        let tier = (object["membership_tier"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return AppleSubscriptionsAccountStatus(
            tier: tier,
            hasWebSubscription: object["active_subscription"] is [String: Any],
            hasAppleSubscription: object["apple_subscription"] is [String: Any]
        )
    }

    /// The `tier` of an entitlements answer, or nil when the answer carries none.
    static func entitlementTier(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier = object["tier"] as? String, !tier.isEmpty else { return nil }
        return tier.lowercased()
    }

    /// A 4xx answer, by the server's code. The three codes that finish a transaction count only with the status the
    /// server sends them with; any other pairing is a plain refusal, which leaves the transaction unfinished.
    static func refusal(status: Int, code: String?) -> AppleSubscriptionsServerError {
        switch (status, code ?? "") {
        case (_, "APPLE_IAP_SIGNED_IN_SESSION_REQUIRED"): return .reauthenticationRequired
        case (_, "APPLE_IAP_ACCOUNT_TOKEN_MISMATCH"), (_, "APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH"):
            return .linkedToAnotherAccount
        case (_, "APPLE_IAP_OWNERSHIP_CONFLICT"): return .ownershipConflict
        case (_, "APPLE_IAP_ACCOUNT_NOT_FOUND"): return .accountNotFound
        case (_, "APPLE_IAP_SANDBOX_NOT_ALLOWED"): return .sandboxNotAllowed
        case (403, "APPLE_IAP_FAMILY_SHARING_NOT_SUPPORTED"): return .familySharingNotSupported
        case (400, "APPLE_IAP_PRODUCT_NOT_ALLOWED"): return .productNotAllowed
        case (400, "APPLE_IAP_INVALID_TRANSACTION"): return .invalidTransaction
        default: return .refused
        }
    }

    /// The code of an error answer: `{"detail": {"error": {"code": ...}}}`.
    static func errorCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              let error = detail["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    private func send(_ method: String, path: String, body: [String: String]? = nil) async throws -> Data {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw AppleSubscriptionsServerError.off
        }
        guard let token = tokenProvider(), !token.isEmpty else {
            throw AppleSubscriptionsServerError.reauthenticationRequired
        }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw AppleSubscriptionsServerError.off }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppleSubscriptionsServerError.unavailable
        }
        guard tokenProvider() == token else { throw AppleSubscriptionsServerError.accountChanged }
        guard let http = response as? HTTPURLResponse else { throw AppleSubscriptionsServerError.unavailable }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw AppleSubscriptionsServerError.reauthenticationRequired
        case 404: throw AppleSubscriptionsServerError.off
        case 408, 425, 429, 500..<600: throw AppleSubscriptionsServerError.unavailable
        default: throw Self.refusal(status: http.statusCode, code: Self.errorCode(in: data))
        }
    }
}

// MARK: - The App Store

/// An App Store product as the plans screen shows it. The price is only ever the App Store's own `displayPrice`.
struct AppleStoreProduct: Equatable, Sendable {
    /// How often a plan renews: one month is `Period(unit: .month, value: 1)`.
    struct Period: Hashable, Sendable {
        enum Unit: String, Hashable, Sendable { case day, week, month, year }
        let unit: Unit
        let value: Int
    }

    let id: String
    let displayName: String
    let description: String
    let displayPrice: String
    /// For ordering the plans, never shown.
    let price: Decimal
    let period: Period?
}

/// A transaction from the App Store: its signed form for the server, whether this device verified it, and the way to
/// finish it. A finished transaction is never delivered again; an unfinished one comes back.
struct AppleStoreTransaction: Sendable {
    let id: UInt64
    let productId: String
    /// The JWS the server verifies itself (`VerificationResult.jwsRepresentation`).
    let signedTransactionInfo: String
    /// StoreKit checked the signature on this device. Unverified transactions are never sent and never finished.
    let isVerified: Bool
    let finish: @Sendable () async -> Void
}

enum AppleStorePurchaseOutcome: Sendable {
    case purchased(AppleStoreTransaction)
    /// Waiting on someone else, such as Ask to Buy: the transaction arrives later through the updates.
    case pending
    case cancelled
}

enum AppleStoreError: Error, Equatable {
    /// The person closed the App Store's sheet.
    case cancelled
    /// The App Store did not have the product.
    case productUnavailable
}

/// The few StoreKit 2 calls the plans need, behind a protocol so the coordinator is testable with fakes.
protocol AppleStoreFront: Sendable {
    func products(for ids: [String]) async throws -> [AppleStoreProduct]
    func purchase(productId: String, appAccountToken: UUID) async throws -> AppleStorePurchaseOutcome
    /// `Transaction.updates`: renewals, Ask to Buy approvals, refunds and purchases made elsewhere.
    func updates() -> AsyncStream<AppleStoreTransaction>
    /// `Transaction.unfinished`: anything left unfinished, such as a purchase the server could not be told about.
    func unfinished() async -> [AppleStoreTransaction]
    /// `Transaction.currentEntitlements`.
    func currentEntitlements() async -> [AppleStoreTransaction]
    /// `AppStore.sync()`. Throws `AppleStoreError.cancelled` when the person cancels the App Store sign-in.
    func sync() async throws
}

struct StoreKitAppleStore: AppleStoreFront {
    func products(for ids: [String]) async throws -> [AppleStoreProduct] {
        try await Product.products(for: ids).map(AppleStoreProduct.init)
    }

    func purchase(productId: String, appAccountToken: UUID) async throws -> AppleStorePurchaseOutcome {
        guard let product = try await Product.products(for: [productId]).first else {
            throw AppleStoreError.productUnavailable
        }
        do {
            switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
            case .success(let result): return .purchased(AppleStoreTransaction(result))
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .cancelled
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        }
    }

    func updates() -> AsyncStream<AppleStoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in StoreKit.Transaction.updates {
                    continuation.yield(AppleStoreTransaction(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unfinished() async -> [AppleStoreTransaction] {
        var transactions: [AppleStoreTransaction] = []
        for await result in StoreKit.Transaction.unfinished { transactions.append(AppleStoreTransaction(result)) }
        return transactions
    }

    func currentEntitlements() async -> [AppleStoreTransaction] {
        var transactions: [AppleStoreTransaction] = []
        for await result in StoreKit.Transaction.currentEntitlements { transactions.append(AppleStoreTransaction(result)) }
        return transactions
    }

    func sync() async throws {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            throw AppleStoreError.cancelled
        }
    }
}

extension AppleStoreProduct {
    init(_ product: Product) {
        var period: Period?
        if let subscriptionPeriod = product.subscription?.subscriptionPeriod {
            switch subscriptionPeriod.unit {
            case .day: period = Period(unit: .day, value: subscriptionPeriod.value)
            case .week: period = Period(unit: .week, value: subscriptionPeriod.value)
            case .month: period = Period(unit: .month, value: subscriptionPeriod.value)
            case .year: period = Period(unit: .year, value: subscriptionPeriod.value)
            @unknown default: period = nil
            }
        }
        self.init(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            period: period
        )
    }
}

extension AppleStoreTransaction {
    init(_ result: VerificationResult<StoreKit.Transaction>) {
        let transaction = result.unsafePayloadValue
        let isVerified: Bool
        if case .verified = result { isVerified = true } else { isVerified = false }
        self.init(
            id: transaction.id,
            productId: transaction.productID,
            signedTransactionInfo: result.jwsRepresentation,
            isVerified: isVerified,
            finish: { await transaction.finish() }
        )
    }
}

// MARK: - The coordinator

/// A plan on the plans screen: what it is called, what it adds, and the App Store's price for it.
struct AppleSubscriptionOffer: Equatable, Identifiable, Sendable {
    let productId: String
    let tier: String
    let name: String
    let summary: String
    let displayPrice: String
    let period: AppleStoreProduct.Period?

    var id: String { productId }

    /// "$29.00 per month", from the App Store's own price and subscription period.
    var priceLine: String {
        guard let period else { return displayPrice }
        let unit = period.unit.rawValue
        return period.value == 1 ? "\(displayPrice) per \(unit)" : "\(displayPrice) every \(period.value) \(unit)s"
    }

    /// When plans renew, from the App Store's subscription periods: "every month" when they share one period, else
    /// "at the end of each period".
    static func renewal(of offers: [AppleSubscriptionOffer]) -> String {
        guard Set(offers.map(\.period)).count == 1, let period = offers.first?.period else {
            return "at the end of each period"
        }
        let unit = period.unit.rawValue
        return period.value == 1 ? "every \(unit)" : "every \(period.value) \(unit)s"
    }

    init(plan: AppleSubscriptionPlan, product: AppleStoreProduct) {
        productId = plan.productId
        tier = plan.tier
        name = Self.names[plan.tier] ?? product.displayName
        summary = Self.summaries[plan.tier] ?? product.description
        displayPrice = product.displayPrice
        period = product.period
    }

    private static let names = ["pro": "Pro", "max": "Max"]
    /// What each plan adds, as the pricing page lists it.
    private static let summaries = [
        "pro": "Up to 3 rooms at a time with 6 agents in each, 10 code audits a month, and 7 days of room history.",
        "max": "Up to 15 rooms at a time with 20 agents in each, unlimited code audits, 30 days of room history, "
            + "and priority support.",
    ]
}

/// Why the plans screen sells nothing right now, or `.open` when a plan above the account's can be bought.
enum AppleSubscriptionsStanding: Equatable, Sendable {
    /// Nothing is running and the account's plan was read: plans above it are for sale.
    case open
    /// The account's plan could not be read: nothing is sold until it is (a web subscriber must never be sold a
    /// second plan because a status call failed).
    case unknown
    /// This account's own App Store subscription is running (the server's word, on any Apple ID).
    case appleSubscription
    /// A subscription billed through the Senti website is running.
    case webSubscription
    /// This Apple ID holds a subscription to these plans that the server does not list for this account.
    case appleIDHoldsAnother
}

/// The plans on screen, the account's tier, and what may be bought.
struct AppleSubscriptionsPlans: Equatable, Sendable {
    let offers: [AppleSubscriptionOffer]
    let currentTier: String?
    let standing: AppleSubscriptionsStanding

    /// Only a plan above the account's tier, and only while nothing is running and the plan was read. A Team or
    /// Enterprise seat, or an admin-set tier, never buys a plan it already has or exceeds.
    func canBuy(_ offer: AppleSubscriptionOffer) -> Bool {
        standing == .open && Self.rank(offer.tier) > Self.rank(currentTier)
    }

    /// The plan is the account's own tier, or below it.
    func isIncluded(_ offer: AppleSubscriptionOffer) -> Bool {
        Self.rank(offer.tier) <= Self.rank(currentTier)
    }

    /// Free (or none) 0, Pro 1, Max 2. Any other paid tier (Team, Enterprise, one this app does not know) ranks above
    /// every plan sold here.
    static func rank(_ tier: String?) -> Int {
        switch (tier ?? "").lowercased() {
        case "", "free": return 0
        case "pro": return 1
        case "max": return 2
        default: return Int.max
        }
    }
}

/// In-app plans for the signed-in account. The server decides whether there is anything to sell: until it lists
/// plans, the state stays hidden and the app shows nothing. Every verified transaction (a purchase here, an update
/// from the App Store, a restore, anything left unfinished) goes to the server, and is finished only once the server
/// answered with the account's entitlements, or said it will never grant a plan.
@MainActor
final class AppleSubscriptionsCoordinator: ObservableObject {
    enum State: Equatable {
        /// Nothing to show: the server sells no plans here, or has not said yet.
        case hidden
        case loading
        case ready(AppleSubscriptionsPlans)
        /// A purchase or restore is with the App Store or the server; the plans stay on screen.
        case purchasing(AppleSubscriptionsPlans)
        case failed(message: String)
    }

    /// What happened to one transaction handed to the server.
    enum Delivery: Equatable {
        case accepted
        case unverified
        /// The server would not apply it, with its reason.
        case refused(AppleSubscriptionsServerError)
        case unavailable
        case off
        case signedOut
        /// The same transaction is already on its way.
        case alreadyDelivering
    }

    /// One plain line on the plans screen after the server refused a transaction.
    enum Line: Equatable {
        case linkedToAnotherAccount
        case ownershipConflict
        case accountNotFound
        case sandboxNotAllowed
        case familySharingNotSupported
        case notApplied

        init?(_ error: AppleSubscriptionsServerError) {
            switch error {
            case .linkedToAnotherAccount: self = .linkedToAnotherAccount
            case .ownershipConflict: self = .ownershipConflict
            case .accountNotFound: self = .accountNotFound
            case .sandboxNotAllowed: self = .sandboxNotAllowed
            case .familySharingNotSupported: self = .familySharingNotSupported
            case .productNotAllowed, .invalidTransaction, .refused: self = .notApplied
            case .off, .reauthenticationRequired, .accountChanged, .unavailable: return nil
            }
        }

        var text: String {
            switch self {
            case .linkedToAnotherAccount:
                return "This Apple ID's subscription is linked to another Senti account. Contact help@plexaura.io."
            case .ownershipConflict:
                return "This purchase needs a look from support. Contact help@plexaura.io."
            case .accountNotFound:
                return "Senti couldn't find your account to apply this purchase. Sign in again, then tap Restore purchases."
            case .sandboxNotAllowed:
                return "Test purchases aren't enabled for this account."
            case .familySharingNotSupported:
                return "Family Sharing isn't supported for Senti plans. Subscribe with your own Apple ID."
            case .notApplied:
                return "Senti couldn't apply this purchase. If you were charged, contact help@plexaura.io."
            }
        }
    }

    @Published private(set) var state: State = .hidden
    /// The server's last refusal, said in one line on the plans screen.
    @Published private(set) var line: Line?
    /// A word after a purchase or restore (waiting for approval, restored, not reached), shown once.
    @Published private(set) var notice: String?

    private let server: any AppleSubscriptionsServing
    private let store: any AppleStoreFront
    private let notificationCenter: NotificationCenter
    private let foregroundNotification: Notification.Name
    private let onReauthenticationRequired: @MainActor () -> Void
    private var accountToken: UUID?
    private var offers: [AppleSubscriptionOffer] = []
    private var currentTier: String?
    private var statusKnown = false
    private var hasWebSubscription = false
    private var hasAppleSubscription = false
    private var appleIDHoldsPlan = false
    private var delivering: Set<UInt64> = []
    /// Transactions the server refused, or this device could not verify, this session: never sent again.
    private var notTaken: [UInt64: Delivery] = [:]
    private var isRefreshing = false
    private var updatesTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    init(
        server: any AppleSubscriptionsServing,
        store: any AppleStoreFront,
        notificationCenter: NotificationCenter = .default,
        foregroundNotification: Notification.Name = UIApplication.willEnterForegroundNotification,
        onReauthenticationRequired: @escaping @MainActor () -> Void = {}
    ) {
        self.server = server
        self.store = store
        self.notificationCenter = notificationCenter
        self.foregroundNotification = foregroundNotification
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// Whether Settings shows its Plan row: only once the server has listed plans.
    var isOffered: Bool { state != .hidden }

    private var standing: AppleSubscriptionsStanding {
        if !statusKnown { return .unknown }
        if hasAppleSubscription { return .appleSubscription }
        if hasWebSubscription { return .webSubscription }
        if appleIDHoldsPlan { return .appleIDHoldsAnother }
        return .open
    }

    private var plans: AppleSubscriptionsPlans {
        AppleSubscriptionsPlans(offers: offers, currentTier: currentTier, standing: standing)
    }

    /// From sign-in on: the App Store's updates go to the server, the plans load, and anything left unfinished is sent
    /// again now and each time the app comes back to the front.
    func start() {
        guard updatesTask == nil else { return }
        let updates = store.updates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.deliver(transaction)
            }
        }
        foregroundObserver = notificationCenter.addObserver(forName: foregroundNotification, object: nil, queue: nil) {
            [weak self] _ in
            Task { @MainActor [weak self] in await self?.retryUnfinished() }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.retryUnfinished()
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        if let foregroundObserver { notificationCenter.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    /// Sends what the App Store still holds unfinished, such as a purchase the server could not be reached for.
    func retryUnfinished() async {
        for transaction in await store.unfinished() {
            await deliver(transaction)
        }
    }

    /// Asks the server what it sells, then the App Store for those products. Off, or never heard from, is hidden.
    func refresh() async {
        if case .purchasing = state { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let wasShown = state != .hidden
        if case .failed = state { state = .loading }
        do {
            let plans = try await server.plans()
            guard !plans.isEmpty else { return hide() }
            let products = try await store.products(for: plans.map(\.productId))
            let offers = plans
                .compactMap { plan in products.first { $0.id == plan.productId }.map { (plan, $0) } }
                .sorted { $0.1.price < $1.1.price }
                .map { AppleSubscriptionOffer(plan: $0.0, product: $0.1) }
            guard !offers.isEmpty else { return fail(Self.storeUnavailable) }
            self.offers = offers
            await refreshAccount()
            state = .ready(self.plans)
        } catch let error as AppleSubscriptionsServerError {
            switch error {
            case .unavailable where wasShown:
                fail("Could not reach Senti. Check your connection and try again.")
            case .reauthenticationRequired:
                hide()
                onReauthenticationRequired()
            default:
                hide()
            }
        } catch {
            fail(Self.storeUnavailable)
        }
    }

    func subscribe(to productId: String) async {
        guard case .ready(let shown) = state,
              let offer = shown.offers.first(where: { $0.productId == productId }) else { return }
        state = .purchasing(shown)
        defer { settle() }
        // Read again right before the App Store is asked: a plan bought since the screen loaded (on the web or another
        // device), or a status that cannot be read, stops the sale. The screen then says why.
        await refreshAccount()
        guard plans.canBuy(offer) else { return }
        do {
            let token = try await purchaseToken()
            switch try await store.purchase(productId: productId, appAccountToken: token) {
            case .purchased(let transaction):
                let delivery = await deliver(transaction)
                notice = Self.notice(after: [delivery], restoring: false)
            case .pending:
                notice = "Waiting for approval. Your plan changes once the purchase is approved."
            case .cancelled:
                break
            }
        } catch let error as AppleSubscriptionsServerError {
            handleServerError(error)
        } catch AppleStoreError.cancelled {
        } catch {
            notice = "The App Store could not complete the purchase. Try again."
        }
    }

    /// Restore purchases: `AppStore.sync`, then every current entitlement goes to the server.
    func restore() async {
        guard case .ready(let shown) = state else { return }
        state = .purchasing(shown)
        defer { settle() }
        do {
            try await store.sync()
        } catch AppleStoreError.cancelled {
            return
        } catch {
            notice = "Could not reach the App Store. Try again."
            return
        }
        var deliveries: [Delivery] = []
        for transaction in await store.currentEntitlements() {
            deliveries.append(await deliver(transaction))
        }
        notice = Self.notice(after: deliveries, restoring: true)
    }

    func dismissNotice() {
        notice = nil
    }

    /// Hands one transaction to the server. It is finished only once the server answered with the account's
    /// entitlements, or said it will never grant a plan.
    @discardableResult
    func deliver(_ transaction: AppleStoreTransaction) async -> Delivery {
        // Refused by the server, or unverifiable on this device, earlier this session: never sent again.
        if let earlier = notTaken[transaction.id] { return earlier }
        // The device could not show it came from the App Store: never sent, never finished.
        guard transaction.isVerified else {
            notTaken[transaction.id] = .unverified
            return .unverified
        }
        guard delivering.insert(transaction.id).inserted else { return .alreadyDelivering }
        defer { delivering.remove(transaction.id) }
        do {
            let tier = try await server.submit(signedTransactionInfo: transaction.signedTransactionInfo)
            await transaction.finish()
            await refreshAccount()
            currentTier = tier
            showAccount()
            return .accepted
        } catch let error as AppleSubscriptionsServerError {
            switch error {
            case .off:
                // During a purchase or restore the screen stays and says what happened; otherwise the feature is off.
                if case .purchasing = state {} else { hide() }
                return .off
            case .reauthenticationRequired:
                onReauthenticationRequired()
                return .signedOut
            case .accountChanged:
                return .signedOut
            case .unavailable:
                return .unavailable
            case .linkedToAnotherAccount, .ownershipConflict, .accountNotFound, .sandboxNotAllowed,
                 .familySharingNotSupported, .productNotAllowed, .invalidTransaction, .refused:
                if error.finishesTransaction { await transaction.finish() }
                notTaken[transaction.id] = .refused(error)
                line = Line(error)
                return .refused(error)
            }
        } catch {
            return .unavailable
        }
    }

    /// The account's plan and what is running: the server's status (web and App Store subscriptions), and this Apple
    /// ID's own verified entitlements to these plans. A status that cannot be read sells nothing.
    private func refreshAccount() async {
        do {
            let status = try await server.accountStatus()
            currentTier = status.tier
            hasWebSubscription = status.hasWebSubscription
            hasAppleSubscription = status.hasAppleSubscription
            statusKnown = true
        } catch {
            statusKnown = false
            if (error as? AppleSubscriptionsServerError) == .reauthenticationRequired { onReauthenticationRequired() }
        }
        let offered = Set(offers.map(\.productId))
        appleIDHoldsPlan = await store.currentEntitlements().contains { $0.isVerified && offered.contains($0.productId) }
    }

    private func purchaseToken() async throws -> UUID {
        if let accountToken { return accountToken }
        let token = try await server.accountToken()
        accountToken = token
        return token
    }

    private func handleServerError(_ error: AppleSubscriptionsServerError) {
        switch error {
        case .off: hide()
        case .reauthenticationRequired: onReauthenticationRequired()
        case .accountChanged: break
        case .unavailable: notice = "Could not reach Senti. Check your connection and try again."
        default: notice = "Purchases aren't available for this account right now."
        }
    }

    private static func notice(after deliveries: [Delivery], restoring: Bool) -> String? {
        if deliveries.contains(.signedOut) { return nil }
        // A refusal is said in one line on the plans screen, not in an alert.
        if deliveries.contains(where: { if case .refused = $0 { return true } else { return false } }) { return nil }
        if deliveries.contains(.off) {
            return restoring
                ? "Senti can't apply purchases right now. Try again later."
                : "Your purchase went through, but Senti can't apply it right now. It stays with the App Store and is "
                    + "applied once Senti is back."
        }
        if deliveries.contains(.unavailable) {
            return "Senti could not be reached to apply your purchase. It is kept with the App Store and applied the "
                + "next time Pocket opens, or when you restore purchases."
        }
        if deliveries.contains(.unverified) {
            return "The App Store could not confirm a purchase, so it was not applied. Try Restore purchases later."
        }
        if deliveries.contains(.alreadyDelivering) {
            return "A purchase is still being applied. Check again in a moment."
        }
        guard restoring else { return nil }
        return deliveries.isEmpty ? "No subscription to restore for this Apple ID." : "Your purchases are restored."
    }

    private static let storeUnavailable = "Plans could not be loaded from the App Store. Try again later."

    private func hide() {
        state = .hidden
    }

    /// A failed refresh leaves plans already on screen where they are.
    private func fail(_ message: String) {
        if case .ready = state { return }
        state = .failed(message: message)
    }

    private func showAccount() {
        switch state {
        case .ready: state = .ready(plans)
        case .purchasing: state = .purchasing(plans)
        case .hidden, .loading, .failed: break
        }
    }

    /// After a purchase or restore, back to the plans with the account as it is now.
    private func settle() {
        if case .purchasing = state { state = .ready(plans) }
    }
}
