import Combine
import Foundation
import StoreKit

// MARK: - The server

/// A plan the server sells in the app: the App Store product and the account tier it gives.
struct AppleSubscriptionPlan: Equatable, Sendable {
    let productId: String
    let tier: String
}

/// Why a call to the server's in-app plans gave no answer the app can use.
enum AppleSubscriptionsServerError: Error, Equatable {
    /// 404, the feature off, or no API configured: purchases are off, so the app shows nothing.
    case off
    /// 401: the sign-in is no longer valid.
    case reauthenticationRequired
    /// Another account signed in while the call was out, so its answer belongs to nobody on screen.
    case accountChanged
    /// The server read the request and would not take it (another account's purchase, a signature it refused).
    case refused
    /// Network, 429 or 5xx, or an answer the app could not read: nothing changed; try again later.
    case unavailable
}

/// The server half of in-app plans, as the signed-in person. A protocol so the coordinator is testable without a
/// network.
protocol AppleSubscriptionsServing: Sendable {
    /// The plans the server sells here, in its order. Throws `.off` when it sells none.
    func plans() async throws -> [AppleSubscriptionPlan]
    /// This account's own purchase token. It goes into every purchase, so the server can tell whose a transaction is.
    func accountToken() async throws -> UUID
    /// Hands a verified transaction's signed form to the server; returns the account's tier after it, when named.
    func submit(signedTransactionInfo: String) async throws -> String?
    /// The account's tier now, however it was bought.
    func currentTier() async throws -> String?
}

/// `/api/v1/billing/apple/*` with the user's own bearer, built as `HTTPAccountIdentity` builds its request: the path set
/// on the API origin, the live session's deadlines, and the answer used only if the same token is still signed in.
final class HTTPAppleSubscriptionsServer: AppleSubscriptionsServing, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
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

    /// `POST /api/v1/billing/apple/transactions` `{"signedTransactionInfo": "<JWS>"}`. Any 2xx means the server has the
    /// transaction; the tier it answers with is read when the answer names one.
    func submit(signedTransactionInfo: String) async throws -> String? {
        let data = try await send("POST", path: "/api/v1/billing/apple/transactions",
                                  body: ["signedTransactionInfo": signedTransactionInfo])
        return Self.tier(in: data)
    }

    /// `GET /api/v1/billing/status` → `membership_tier`, the account's plan whether bought here, on the web or granted.
    func currentTier() async throws -> String? {
        Self.tier(in: try await send("GET", path: "/api/v1/billing/status"))
    }

    /// The tier an answer names: `tier` or `membership_tier`, at the top or under `entitlement`.
    static func tier(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for candidate in [object, object["entitlement"] as? [String: Any] ?? [:]] {
            for key in ["tier", "membership_tier", "membershipTier"] {
                if let tier = candidate[key] as? String, !tier.isEmpty { return tier.lowercased() }
            }
        }
        return nil
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
        default: throw AppleSubscriptionsServerError.refused
        }
    }
}

// MARK: - The App Store

/// An App Store product as the plans screen shows it. The price is only ever the App Store's own `displayPrice`.
struct AppleStoreProduct: Equatable, Sendable {
    /// How often a plan renews: one month is `Period(unit: .month, value: 1)`.
    struct Period: Equatable, Sendable {
        enum Unit: String, Equatable, Sendable { case day, week, month, year }
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

    /// "$29.00 per month", from the App Store's own price.
    var priceLine: String {
        guard let period else { return displayPrice }
        let unit = period.unit.rawValue
        return period.value == 1 ? "\(displayPrice) per \(unit)" : "\(displayPrice) every \(period.value) \(unit)s"
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

/// In-app plans for the signed-in account. The server decides whether there is anything to sell: until it lists
/// plans, the state stays hidden and the app shows nothing. Every verified transaction (a purchase here, an update
/// from the App Store, a restore) goes to the server, and is finished only once the server has accepted it, so one
/// the server never got comes back until it does.
@MainActor
final class AppleSubscriptionsCoordinator: ObservableObject {
    enum State: Equatable {
        /// Nothing to show: the server sells no plans here, or has not said yet.
        case hidden
        case loading
        case ready(offers: [AppleSubscriptionOffer], currentTier: String?)
        /// A purchase or restore is with the App Store or the server; the plans stay on screen.
        case purchasing(offers: [AppleSubscriptionOffer], currentTier: String?)
        case failed(message: String)
    }

    /// What happened to one transaction handed to the server.
    enum Delivery: Equatable {
        case accepted
        case unverified
        case refused
        case unavailable
        case off
        case signedOut
        /// The same transaction is already on its way.
        case alreadyDelivering
    }

    @Published private(set) var state: State = .hidden
    /// A word after a purchase or restore (waiting for approval, restored, not applied), shown once.
    @Published private(set) var notice: String?

    private let server: any AppleSubscriptionsServing
    private let store: any AppleStoreFront
    private let onReauthenticationRequired: @MainActor () -> Void
    private var accountToken: UUID?
    private var currentTier: String?
    private var delivering: Set<UInt64> = []
    private var isRefreshing = false
    private var updatesTask: Task<Void, Never>?

    init(
        server: any AppleSubscriptionsServing,
        store: any AppleStoreFront,
        onReauthenticationRequired: @escaping @MainActor () -> Void = {}
    ) {
        self.server = server
        self.store = store
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// Whether Settings shows its Plan row: only once the server has listed plans.
    var isOffered: Bool { state != .hidden }

    /// From sign-in on: the App Store's updates and anything left unfinished go to the server, and the plans load.
    func start() {
        guard updatesTask == nil else { return }
        let updates = store.updates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.deliver(transaction)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            for transaction in await self.store.unfinished() {
                await self.deliver(transaction)
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
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
            if let tier = try? await server.currentTier() { currentTier = tier }
            state = .ready(offers: offers, currentTier: currentTier)
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
        guard case .ready(let offers, let tier) = state,
              offers.contains(where: { $0.productId == productId }) else { return }
        state = .purchasing(offers: offers, currentTier: tier)
        defer { settle() }
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
        guard case .ready(let offers, let tier) = state else { return }
        state = .purchasing(offers: offers, currentTier: tier)
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

    /// Hands one transaction to the server, and finishes it only once the server accepted it.
    @discardableResult
    func deliver(_ transaction: AppleStoreTransaction) async -> Delivery {
        // The device could not show it came from the App Store: never sent, never finished.
        guard transaction.isVerified else { return .unverified }
        guard delivering.insert(transaction.id).inserted else { return .alreadyDelivering }
        defer { delivering.remove(transaction.id) }
        do {
            let tier = try await server.submit(signedTransactionInfo: transaction.signedTransactionInfo)
            await transaction.finish()
            if let tier {
                currentTier = tier
            } else if let tier = try? await server.currentTier() {
                currentTier = tier
            }
            showCurrentTier()
            return .accepted
        } catch let error as AppleSubscriptionsServerError {
            switch error {
            case .off:
                hide()
                return .off
            case .reauthenticationRequired:
                onReauthenticationRequired()
                return .signedOut
            case .accountChanged:
                return .signedOut
            case .refused:
                return .refused
            case .unavailable:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
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
        case .refused: notice = "Purchases aren't available for this account."
        case .unavailable: notice = "Could not reach Senti. Check your connection and try again."
        }
    }

    private static func notice(after deliveries: [Delivery], restoring: Bool) -> String? {
        if deliveries.contains(.off) || deliveries.contains(.signedOut) { return nil }
        if deliveries.contains(.refused) {
            return "A purchase could not be added to this account. Restore it while signed in to the account that bought it."
        }
        if deliveries.contains(.unavailable) {
            return "Senti could not be reached to apply your purchase. It is kept with the App Store and applied the "
                + "next time Pocket opens, or when you restore purchases."
        }
        if deliveries.contains(.unverified) {
            return "The App Store could not confirm a purchase, so it was not applied. Try Restore purchases later."
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

    private func showCurrentTier() {
        switch state {
        case .ready(let offers, _): state = .ready(offers: offers, currentTier: currentTier)
        case .purchasing(let offers, _): state = .purchasing(offers: offers, currentTier: currentTier)
        case .hidden, .loading, .failed: break
        }
    }

    /// After a purchase or restore, back to the plans with the tier as it is now.
    private func settle() {
        if case .purchasing(let offers, _) = state { state = .ready(offers: offers, currentTier: currentTier) }
    }
}
