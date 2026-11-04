import Foundation
import XCTest
@testable import SentiPocketApp

private let proId = "com.plexaura.sentipocket.pro.monthly"
private let maxId = "com.plexaura.sentipocket.max.monthly"

/// What the fakes saw, in order, so a test can tell a finish came after the server took the transaction.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ event: String) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var posted: [String] { all.filter { $0.hasPrefix("post ") }.map { String($0.dropFirst(5)) } }
    var finished: [String] { all.filter { $0.hasPrefix("finish ") }.map { String($0.dropFirst(7)) } }
}

/// The server, scripted: what it sells, the account's token and status, and its answer to each transaction in turn.
private final class FakePlansServer: AppleSubscriptionsServing, @unchecked Sendable {
    let events: Events
    let token = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    var plansAnswer: Result<[AppleSubscriptionPlan], AppleSubscriptionsServerError> = .success([
        AppleSubscriptionPlan(productId: proId, tier: "pro"),
        AppleSubscriptionPlan(productId: maxId, tier: "max"),
    ])
    /// Answers to the transactions posted, first to last; past the end the server applies them and answers "pro".
    var submitAnswers: [Result<String, AppleSubscriptionsServerError>] = []
    /// `GET /billing/status`: the account's tier, and whether a subscription is running.
    var tier: String?
    var isActive = false
    private let lock = NSLock()

    init(events: Events) {
        self.events = events
    }

    func plans() async throws -> [AppleSubscriptionPlan] {
        try plansAnswer.get()
    }

    func accountToken() async throws -> UUID {
        events.append("token")
        return token
    }

    func submit(signedTransactionInfo: String) async throws -> String {
        events.append("post \(signedTransactionInfo)")
        lock.lock()
        let answer = submitAnswers.isEmpty ? .success("pro") : submitAnswers.removeFirst()
        lock.unlock()
        return try answer.get()
    }

    func accountStatus() async throws -> AppleSubscriptionsAccountStatus {
        AppleSubscriptionsAccountStatus(tier: tier, hasActiveSubscription: isActive)
    }
}

/// The App Store, scripted.
private final class FakeStore: AppleStoreFront, @unchecked Sendable {
    let events: Events
    var catalog: [AppleStoreProduct] = [
        AppleStoreProduct(id: maxId, displayName: "Max", description: "", displayPrice: "$99.00", price: 99,
                          period: .init(unit: .month, value: 1)),
        AppleStoreProduct(id: proId, displayName: "Pro", description: "", displayPrice: "$29.00", price: 29,
                          period: .init(unit: .month, value: 1)),
    ]
    var purchaseOutcome: AppleStorePurchaseOutcome = .cancelled
    var purchaseError: Error?
    var syncError: Error?
    var entitlements: [AppleStoreTransaction] = []
    var unfinishedTransactions: [AppleStoreTransaction] = []
    private(set) var productLoads = 0
    private(set) var purchases: [(productId: String, token: UUID)] = []
    private let stream: AsyncStream<AppleStoreTransaction>
    private let continuation: AsyncStream<AppleStoreTransaction>.Continuation

    init(events: Events) {
        self.events = events
        var captured: AsyncStream<AppleStoreTransaction>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func transaction(_ id: UInt64, productId: String = proId, verified: Bool = true) -> AppleStoreTransaction {
        let events = self.events
        return AppleStoreTransaction(id: id, productId: productId, signedTransactionInfo: "jws-\(id)",
                                     isVerified: verified, finish: { events.append("finish \(id)") })
    }

    func sendUpdate(_ transaction: AppleStoreTransaction) {
        continuation.yield(transaction)
    }

    func products(for ids: [String]) async throws -> [AppleStoreProduct] {
        productLoads += 1
        return catalog.filter { ids.contains($0.id) }
    }

    func purchase(productId: String, appAccountToken: UUID) async throws -> AppleStorePurchaseOutcome {
        purchases.append((productId, appAccountToken))
        events.append("purchase \(productId)")
        if let purchaseError { throw purchaseError }
        return purchaseOutcome
    }

    func updates() -> AsyncStream<AppleStoreTransaction> { stream }

    func unfinished() async -> [AppleStoreTransaction] {
        let transactions = unfinishedTransactions
        events.append("unfinished")
        return transactions
    }

    func currentEntitlements() async -> [AppleStoreTransaction] {
        events.append("entitlements")
        return entitlements
    }

    func sync() async throws {
        events.append("sync")
        if let syncError { throw syncError }
    }
}

@MainActor
private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
final class AppleSubscriptionsCoordinatorTests: XCTestCase {
    private let events = Events()
    private lazy var server = FakePlansServer(events: events)
    private lazy var store = FakeStore(events: events)

    private func readyCoordinator(file: StaticString = #filePath, line: UInt = #line) async -> AppleSubscriptionsCoordinator {
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        guard case .ready = coordinator.state else {
            XCTFail("expected the plans on screen, got \(coordinator.state)", file: file, line: line)
            return coordinator
        }
        return coordinator
    }

    private func currentTier(_ coordinator: AppleSubscriptionsCoordinator) -> String? {
        if case .ready(_, let tier, _) = coordinator.state { return tier }
        return nil
    }

    private func isActive(_ coordinator: AppleSubscriptionsCoordinator) -> Bool? {
        if case .ready(_, _, let active) = coordinator.state { return active }
        return nil
    }

    func test_the_plans_show_each_offer_at_the_app_store_price_cheapest_first() async {
        server.tier = "free"
        let coordinator = await readyCoordinator()
        guard case .ready(let offers, let tier, let active) = coordinator.state else {
            return XCTFail("\(coordinator.state)")
        }
        XCTAssertEqual(offers.map(\.tier), ["pro", "max"])
        XCTAssertEqual(offers.map(\.name), ["Pro", "Max"])
        XCTAssertEqual(offers.map(\.priceLine), ["$29.00 per month", "$99.00 per month"])
        XCTAssertFalse(offers[0].summary.isEmpty)
        XCTAssertEqual(tier, "free")
        XCTAssertFalse(active)
        XCTAssertTrue(coordinator.isOffered)
    }

    func test_the_period_text_comes_from_the_app_store_product() {
        let plan = AppleSubscriptionPlan(productId: proId, tier: "pro")
        func offer(_ unit: AppleStoreProduct.Period.Unit, _ value: Int, _ price: String) -> AppleSubscriptionOffer {
            AppleSubscriptionOffer(plan: plan, product: AppleStoreProduct(
                id: proId, displayName: "Pro", description: "", displayPrice: price, price: 1,
                period: .init(unit: unit, value: value)))
        }
        let monthly = offer(.month, 1, "$29.00")
        let yearly = offer(.year, 1, "$290.00")
        let quarterly = offer(.month, 3, "$79.00")
        XCTAssertEqual(yearly.priceLine, "$290.00 per year")
        XCTAssertEqual(quarterly.priceLine, "$79.00 every 3 months")
        XCTAssertEqual(AppleSubscriptionOffer.renewal(of: [monthly, monthly]), "every month")
        XCTAssertEqual(AppleSubscriptionOffer.renewal(of: [yearly]), "every year")
        XCTAssertEqual(AppleSubscriptionOffer.renewal(of: [monthly, yearly]), "at the end of each period")
        XCTAssertTrue(SubscriptionsView.renewalTerms(for: [yearly]).contains("Your plan renews every year at the price"))
        XCTAssertTrue(SubscriptionsView.renewalTerms(for: [monthly]).contains("renews every month"))
    }

    func test_a_purchase_is_posted_then_finished_and_the_plan_marked() async throws {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(1))
        server.submitAnswers = [.success("pro")]

        await coordinator.subscribe(to: proId)

        XCTAssertEqual(events.posted, ["jws-1"])
        XCTAssertEqual(events.finished, ["1"])
        let all = events.all
        XCTAssertLessThan(try XCTUnwrap(all.firstIndex(of: "post jws-1")), try XCTUnwrap(all.firstIndex(of: "finish 1")),
                          "finished only after the server took it")
        XCTAssertEqual(currentTier(coordinator), "pro")
        XCTAssertNil(coordinator.notice)
    }

    func test_a_purchase_the_server_refuses_is_not_finished() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(2))
        server.submitAnswers = [.failure(.refused)]

        await coordinator.subscribe(to: proId)

        XCTAssertEqual(events.posted, ["jws-2"])
        XCTAssertEqual(events.finished, [], "a refused transaction stays with the App Store")
        XCTAssertNotNil(coordinator.notice)
        XCTAssertNil(currentTier(coordinator))
        guard case .ready = coordinator.state else { return XCTFail("\(coordinator.state)") }
    }

    func test_a_purchase_the_server_never_got_is_not_finished_so_it_comes_back() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(3))
        server.submitAnswers = [.failure(.unavailable)]

        await coordinator.subscribe(to: proId)

        XCTAssertEqual(events.posted, ["jws-3"])
        XCTAssertEqual(events.finished, [])
        XCTAssertEqual(coordinator.notice?.contains("next time Pocket opens"), true)
    }

    func test_a_submit_that_needs_sign_in_again_never_finishes() async {
        var asked = 0
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store,
                                                        onReauthenticationRequired: { asked += 1 })
        server.submitAnswers = [.failure(.reauthenticationRequired)]

        let delivery = await coordinator.deliver(store.transaction(15))

        XCTAssertEqual(delivery, .signedOut)
        XCTAssertEqual(events.posted, ["jws-15"])
        XCTAssertEqual(events.finished, [], "a 401 is not the server taking it")
        XCTAssertEqual(asked, 1)
    }

    func test_an_answer_for_an_account_no_longer_signed_in_never_finishes() async {
        var asked = 0
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store,
                                                        onReauthenticationRequired: { asked += 1 })
        server.submitAnswers = [.failure(.accountChanged), .success("pro")]

        let first = await coordinator.deliver(store.transaction(16))
        XCTAssertEqual(first, .signedOut)
        XCTAssertEqual(events.finished, [], "an answer that belongs to another sign-in finishes nothing")
        XCTAssertEqual(asked, 0)

        let second = await coordinator.deliver(store.transaction(16))
        XCTAssertEqual(second, .accepted, "it is sent again, as the account now signed in")
        XCTAssertEqual(events.posted, ["jws-16", "jws-16"])
        XCTAssertEqual(events.finished, ["16"])
    }

    func test_an_unverified_transaction_is_never_posted_or_finished() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(4, verified: false))

        await coordinator.subscribe(to: proId)
        let delivery = await coordinator.deliver(store.transaction(5, verified: false))
        let again = await coordinator.deliver(store.transaction(5, verified: false))

        XCTAssertEqual(delivery, .unverified)
        XCTAssertEqual(again, .unverified)
        XCTAssertEqual(events.posted, [])
        XCTAssertEqual(events.finished, [])
        XCTAssertNotNil(coordinator.notice)
    }

    func test_a_refused_transaction_is_never_posted_again_this_session() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(40))
        server.submitAnswers = [.failure(.refused)]
        await coordinator.subscribe(to: proId)
        coordinator.dismissNotice()

        let fromUpdates = await coordinator.deliver(store.transaction(40))
        store.unfinishedTransactions = [store.transaction(40)]
        await coordinator.retryUnfinished()
        store.entitlements = [store.transaction(40)]
        await coordinator.restore()

        XCTAssertEqual(fromUpdates, .refused)
        XCTAssertEqual(events.posted, ["jws-40"], "posted once; refused for the rest of the session")
        XCTAssertEqual(events.finished, [])
    }

    func test_another_accounts_subscription_is_left_unfinished() async {
        let coordinator = await readyCoordinator()
        server.submitAnswers = [.failure(.linkedToAnotherAccount)]

        let delivery = await coordinator.deliver(store.transaction(60))

        XCTAssertEqual(delivery, .linkedToAnotherAccount)
        XCTAssertEqual(events.posted, ["jws-60"])
        XCTAssertEqual(events.finished, [], "another account's subscription stays with the App Store")
    }

    func test_another_accounts_subscription_is_not_sent_again_this_session() async {
        let coordinator = await readyCoordinator()
        server.submitAnswers = [.failure(.linkedToAnotherAccount)]
        _ = await coordinator.deliver(store.transaction(61))

        let again = await coordinator.deliver(store.transaction(61))
        store.unfinishedTransactions = [store.transaction(61)]
        await coordinator.retryUnfinished()
        store.entitlements = [store.transaction(61)]
        await coordinator.restore()

        XCTAssertEqual(again, .linkedToAnotherAccount)
        XCTAssertEqual(events.posted, ["jws-61"], "a refusal, not a passing failure: posted once")
        XCTAssertEqual(events.finished, [])
    }

    func test_another_accounts_subscription_is_said_in_one_line_on_the_plans_screen() async {
        let coordinator = await readyCoordinator()
        XCTAssertFalse(coordinator.isLinkedToAnotherAccount)
        store.entitlements = [store.transaction(62)]
        server.submitAnswers = [.failure(.linkedToAnotherAccount)]

        await coordinator.restore()

        XCTAssertTrue(coordinator.isLinkedToAnotherAccount)
        XCTAssertEqual(AppleSubscriptionsCoordinator.linkedToAnotherAccountLine,
                       "This Apple ID's subscription is linked to another Senti account. Contact help@plexaura.io.")
        XCTAssertNil(coordinator.notice, "said on the screen, not in an alert")
        guard case .ready = coordinator.state else { return XCTFail("\(coordinator.state)") }
    }

    func test_pending_and_cancelled_are_quiet_outcomes() async {
        let coordinator = await readyCoordinator()

        store.purchaseOutcome = .pending
        await coordinator.subscribe(to: maxId)
        guard case .ready = coordinator.state else { return XCTFail("pending is not an error: \(coordinator.state)") }
        XCTAssertEqual(coordinator.notice?.contains("Waiting for approval"), true)
        coordinator.dismissNotice()

        store.purchaseOutcome = .cancelled
        await coordinator.subscribe(to: maxId)
        guard case .ready = coordinator.state else { return XCTFail("cancelled is not an error: \(coordinator.state)") }
        XCTAssertNil(coordinator.notice)

        store.purchaseError = AppleStoreError.cancelled
        await coordinator.subscribe(to: maxId)
        guard case .ready = coordinator.state else { return XCTFail("\(coordinator.state)") }
        XCTAssertNil(coordinator.notice)

        XCTAssertEqual(events.posted, [])
        XCTAssertEqual(events.finished, [])
    }

    func test_no_purchase_while_a_subscription_is_active() async {
        server.isActive = true
        server.tier = "pro"
        let coordinator = await readyCoordinator()
        XCTAssertEqual(isActive(coordinator), true, "the screen offers nothing for sale")

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty, "no second purchase while one is running")
        XCTAssertEqual(coordinator.notice, AppleSubscriptionsCoordinator.alreadySubscribed)
        XCTAssertEqual(isActive(coordinator), true)
    }

    func test_a_subscription_started_since_the_plans_loaded_blocks_the_purchase() async {
        let coordinator = await readyCoordinator()
        XCTAssertEqual(isActive(coordinator), false)
        server.isActive = true

        await coordinator.subscribe(to: proId)

        XCTAssertTrue(store.purchases.isEmpty, "the status is read again before the App Store is asked")
        XCTAssertEqual(isActive(coordinator), true)
    }

    func test_a_plan_this_apple_id_holds_counts_as_active() async {
        store.entitlements = [store.transaction(30, productId: maxId, verified: false)]
        let unverified = await readyCoordinator()
        XCTAssertEqual(isActive(unverified), false, "an unverified entitlement proves nothing")

        store.entitlements = [store.transaction(31, productId: maxId)]
        let holder = await readyCoordinator()
        XCTAssertEqual(isActive(holder), true, "the server's status does not list subscriptions bought here")
        await holder.subscribe(to: proId)
        XCTAssertTrue(store.purchases.isEmpty)
    }

    func test_restore_syncs_then_posts_every_current_entitlement() async throws {
        let coordinator = await readyCoordinator()
        store.entitlements = [store.transaction(7), store.transaction(8, productId: maxId), store.transaction(9, verified: false)]
        server.submitAnswers = [.success("pro"), .success("max")]

        await coordinator.restore()

        XCTAssertEqual(events.posted, ["jws-7", "jws-8"], "every verified entitlement, and only those")
        XCTAssertEqual(events.finished, ["7", "8"])
        let all = events.all
        XCTAssertLessThan(try XCTUnwrap(all.firstIndex(of: "sync")), try XCTUnwrap(all.firstIndex(of: "post jws-7")))
        XCTAssertEqual(currentTier(coordinator), "max")
        XCTAssertEqual(isActive(coordinator), true, "a restored plan is a running one")
    }

    func test_restore_with_nothing_to_restore_says_so_and_a_cancelled_sync_is_quiet() async {
        let coordinator = await readyCoordinator()
        await coordinator.restore()
        XCTAssertEqual(coordinator.notice, "No subscription to restore for this Apple ID.")
        coordinator.dismissNotice()

        store.syncError = AppleStoreError.cancelled
        store.entitlements = [store.transaction(10)]
        await coordinator.restore()
        XCTAssertNil(coordinator.notice)
        XCTAssertEqual(events.posted, [], "nothing posted after a cancelled sync")
        guard case .ready = coordinator.state else { return XCTFail("\(coordinator.state)") }
    }

    func test_updates_and_unfinished_transactions_are_posted_from_sign_in() async {
        store.unfinishedTransactions = [store.transaction(11)]
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store,
                                                        notificationCenter: NotificationCenter())
        coordinator.start()
        defer { coordinator.stop() }

        let gotUnfinished = await eventually { self.events.finished.contains("11") }
        XCTAssertTrue(gotUnfinished, "an unfinished transaction is posted and finished at sign-in")

        store.sendUpdate(store.transaction(12, productId: maxId))
        store.sendUpdate(store.transaction(13, verified: false))
        let gotUpdate = await eventually { self.events.finished.contains("12") }
        XCTAssertTrue(gotUpdate, "an update is posted and finished")
        XCTAssertEqual(events.posted, ["jws-11", "jws-12"], "the unverified update is never posted")
        XCTAssertFalse(events.finished.contains("13"))
    }

    func test_unfinished_transactions_are_sent_again_when_the_app_comes_to_the_front() async {
        let center = NotificationCenter()
        let foreground = Notification.Name("test.plans.foreground")
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store, notificationCenter: center,
                                                        foregroundNotification: foreground)
        coordinator.start()
        defer { coordinator.stop() }
        let started = await eventually { self.events.all.filter { $0 == "unfinished" }.count == 1 }
        XCTAssertTrue(started, "the sign-in pass ran")
        XCTAssertEqual(events.posted, [])

        // A purchase the server could not be reached for is still unfinished when the app comes back.
        store.unfinishedTransactions = [store.transaction(21)]
        center.post(name: foreground, object: nil)

        let retried = await eventually { self.events.finished.contains("21") }
        XCTAssertTrue(retried, "coming to the front sends what is unfinished")
        XCTAssertEqual(events.posted, ["jws-21"])
    }

    func test_the_account_token_goes_into_the_purchase() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .cancelled

        await coordinator.subscribe(to: maxId)
        await coordinator.subscribe(to: proId)

        XCTAssertEqual(store.purchases.map { $0.productId }, [maxId, proId])
        XCTAssertEqual(store.purchases.map { $0.token }, [server.token, server.token])
        XCTAssertEqual(events.all.filter { $0 == "token" }.count, 1, "the token is asked for once per sign-in")
    }

    func test_no_purchase_without_the_account_token() async {
        let coordinator = AppleSubscriptionsCoordinator(server: FailingTokenServer(base: server), store: store)
        await coordinator.refresh()

        await coordinator.subscribe(to: proId)

        XCTAssertTrue(store.purchases.isEmpty, "the App Store is never asked without this account's token")
        XCTAssertNotNil(coordinator.notice)
    }

    func test_off_hides_everything_and_nothing_is_asked_of_the_app_store() async {
        server.plansAnswer = .failure(.off)
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden)
        XCTAssertFalse(coordinator.isOffered)
        XCTAssertEqual(store.productLoads, 0)

        server.plansAnswer = .success([])
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden, "an empty list sells nothing")
    }

    func test_turning_off_while_shown_hides_the_plans() async {
        let coordinator = await readyCoordinator()
        server.plansAnswer = .failure(.off)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden)

        server.plansAnswer = .success([AppleSubscriptionPlan(productId: proId, tier: "pro")])
        await coordinator.refresh()
        store.purchaseOutcome = .purchased(store.transaction(14))
        server.submitAnswers = [.failure(.off)]
        await coordinator.subscribe(to: proId)
        XCTAssertEqual(coordinator.state, .hidden, "a 404 on a transaction hides the plans too")
        XCTAssertEqual(events.finished, [])
    }

    func test_a_network_failure_before_the_server_answered_shows_nothing() async {
        server.plansAnswer = .failure(.unavailable)
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden, "only the server saying so shows the plans")
    }

    func test_a_refused_sign_in_hides_the_plans_and_asks_for_sign_in() async {
        server.plansAnswer = .failure(.reauthenticationRequired)
        var asked = 0
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store,
                                                        onReauthenticationRequired: { asked += 1 })
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden)
        XCTAssertEqual(asked, 1)
    }
}

/// The scripted server, except the account token cannot be read.
private struct FailingTokenServer: AppleSubscriptionsServing {
    let base: FakePlansServer
    func plans() async throws -> [AppleSubscriptionPlan] { try await base.plans() }
    func accountToken() async throws -> UUID { throw AppleSubscriptionsServerError.unavailable }
    func submit(signedTransactionInfo: String) async throws -> String {
        try await base.submit(signedTransactionInfo: signedTransactionInfo)
    }
    func accountStatus() async throws -> AppleSubscriptionsAccountStatus { try await base.accountStatus() }
}

// MARK: - The HTTP client

/// Answers by path; a nil answer is a transport failure. `onRequest` runs before the answer (to sign someone else in).
private final class PlansURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [String: (Int, String)] = [:]
    private static var captured: [(URLRequest, Data)] = []
    static var onRequest: (@Sendable () -> Void)?

    static func reset(_ answers: [String: (Int, String)]) {
        lock.lock()
        self.answers = answers
        captured = []
        onRequest = nil
        lock.unlock()
    }

    static func requests() -> [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append((request, body))
        let answer = Self.answers[request.url?.path ?? ""]
        let onRequest = Self.onRequest
        Self.lock.unlock()
        onRequest?()
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, text) = answer
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The bearer the client reads, changeable mid-request.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "test-bearer"
    var token: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
final class AppleSubscriptionsHTTPTests: XCTestCase {
    private static let products = "/api/v1/billing/apple/products"
    private static let accountToken = "/api/v1/billing/apple/account-token"
    private static let transactions = "/api/v1/billing/apple/transactions"
    private static let status = "/api/v1/billing/status"
    private static let plansBody = #"[{"productId":"com.plexaura.sentipocket.pro.monthly","tier":"pro"},"#
        + #"{"productId":"com.plexaura.sentipocket.max.monthly","tier":"MAX"},{"tier":"pro"}]"#
    /// The server's answer to a transaction: the account's entitlements (`EntitlementsResponse`).
    private static let entitlements = #"{"tier":"max","seats":1,"senti_rooms_concurrent":15,"agents_per_room":20,"#
        + #""retention_days":30,"support":"priority","unlimited_sentinel":-1}"#

    private let tokens = TokenBox()

    private func makeServer(_ answers: [String: (Int, String)]) -> HTTPAppleSubscriptionsServer {
        PlansURLProtocol.reset(answers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlansURLProtocol.self]
        let tokens = self.tokens
        return HTTPAppleSubscriptionsServer(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { tokens.token }
        )
    }

    private func error(_ work: () async throws -> Void) async -> AppleSubscriptionsServerError? {
        do {
            try await work()
            return nil
        } catch {
            return error as? AppleSubscriptionsServerError
        }
    }

    func test_plans_are_read_with_the_bearer_and_bad_rows_skipped() async throws {
        let server = makeServer([Self.products: (200, Self.plansBody)])
        let plans = try await server.plans()
        XCTAssertEqual(plans, [AppleSubscriptionPlan(productId: proId, tier: "pro"),
                               AppleSubscriptionPlan(productId: maxId, tier: "max")])
        let (request, _) = try XCTUnwrap(PlansURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/v1/billing/apple/products")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
    }

    func test_products_404_or_an_unreadable_answer_is_off() async {
        let missing = await error { _ = try await self.makeServer([Self.products: (404, #"{"detail":"Not found"}"#)]).plans() }
        XCTAssertEqual(missing, .off)
        let unreadable = await error { _ = try await self.makeServer([Self.products: (200, #"{"enabled":false}"#)]).plans() }
        XCTAssertEqual(unreadable, .off)
        let none = HTTPAppleSubscriptionsServer(apiBaseURL: nil, tokenProvider: { "test-bearer" })
        let unconfigured = await error { _ = try await none.plans() }
        XCTAssertEqual(unconfigured, .off)
    }

    func test_products_404_hides_the_plans_on_screen() async {
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (200, #"{"membership_tier":"free"}"#)])
        let store = FakeStore(events: Events())
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertTrue(coordinator.isOffered)

        PlansURLProtocol.reset([Self.products: (404, "")])
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .hidden)
        XCTAssertFalse(coordinator.isOffered)
    }

    func test_the_account_token_is_read_as_a_uuid() async throws {
        let token = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let server = makeServer([Self.accountToken: (200, #"{"appAccountToken":"\#(token)"}"#)])
        let read = try await server.accountToken()
        XCTAssertEqual(read, UUID(uuidString: token))
        let bad = await error { _ = try await self.makeServer([Self.accountToken: (200, #"{"appAccountToken":"nope"}"#)]).accountToken() }
        XCTAssertEqual(bad, .unavailable, "never a made-up token")
    }

    func test_a_transaction_is_posted_as_its_signed_form_only() async throws {
        let server = makeServer([Self.transactions: (200, Self.entitlements)])
        let tier = try await server.submit(signedTransactionInfo: "header.payload.signature")
        XCTAssertEqual(tier, "max")
        let (request, body) = try XCTUnwrap(PlansURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, Self.transactions)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["signedTransactionInfo": "header.payload.signature"])
    }

    func test_a_2xx_without_an_entitlement_is_not_acceptance() async {
        for body in ["{}", #"{"status":"ok"}"#, #"{"tier":""}"#, "not json"] {
            let result = await error {
                _ = try await self.makeServer([Self.transactions: (200, body)]).submit(signedTransactionInfo: "jws")
            }
            XCTAssertEqual(result, .unavailable, body)
        }
    }

    func test_a_transaction_is_finished_only_on_an_entitlements_answer_and_a_replay_is_one() async {
        let events = Events()
        let store = FakeStore(events: events)
        let server = makeServer([Self.transactions: (200, "{}"), Self.status: (200, #"{"membership_tier":"free"}"#)])
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)

        let bare = await coordinator.deliver(store.transaction(50))
        XCTAssertEqual(bare, .unavailable)
        XCTAssertEqual(events.finished, [], "a 2xx with no entitlement leaves it unfinished")

        // The server answers a transaction it already applied to this account with the same 200 and entitlements.
        PlansURLProtocol.reset([Self.transactions: (200, Self.entitlements), Self.status: (200, #"{"membership_tier":"max"}"#)])
        let applied = await coordinator.deliver(store.transaction(50))
        let replayed = await coordinator.deliver(store.transaction(50))
        XCTAssertEqual(applied, .accepted)
        XCTAssertEqual(replayed, .accepted)
        XCTAssertEqual(events.finished, ["50", "50"])
    }

    func test_the_status_gives_the_tier_and_whether_a_subscription_is_running() async throws {
        let running = #"{"membership_tier":"pro","active_subscription":{"status":"active","current_period_end":null,"#
            + #""cancel_at_period_end":false},"unlimited_runs":false}"#
        let active = try await makeServer([Self.status: (200, running)]).accountStatus()
        XCTAssertEqual(active, AppleSubscriptionsAccountStatus(tier: "pro", hasActiveSubscription: true))
        let none = try await makeServer([Self.status: (200, #"{"membership_tier":"free","active_subscription":null}"#)])
            .accountStatus()
        XCTAssertEqual(none, AppleSubscriptionsAccountStatus(tier: "free", hasActiveSubscription: false))
        XCTAssertEqual(PlansURLProtocol.requests().first?.0.url?.path, Self.status)
    }

    func test_the_servers_answers_map_to_what_the_coordinator_does() async {
        let cases: [(Int, AppleSubscriptionsServerError)] = [
            (401, .reauthenticationRequired),
            // 403: another account's token or subscription, or not a signed-in session; 409: bound to another account.
            (400, .refused), (403, .refused), (409, .refused), (422, .refused),
            (404, .off),
            (408, .unavailable), (429, .unavailable), (500, .unavailable), (503, .unavailable),
        ]
        for (status, expected) in cases {
            let result = await error {
                _ = try await self.makeServer([Self.transactions: (status, "{}")]).submit(signedTransactionInfo: "jws")
            }
            XCTAssertEqual(result, expected, "status \(status)")
        }
        let offline = await error { _ = try await self.makeServer([:]).submit(signedTransactionInfo: "jws") }
        XCTAssertEqual(offline, .unavailable)
    }

    func test_the_servers_account_mismatch_codes_read_as_another_account() async {
        func body(_ code: String) -> String { #"{"detail":{"error":{"code":"\#(code)","message":"m","request_id":"r"}}}"# }
        let cases: [(Int, String, AppleSubscriptionsServerError)] = [
            (403, body("APPLE_IAP_ACCOUNT_TOKEN_MISMATCH"), .linkedToAnotherAccount),
            (403, body("APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH"), .linkedToAnotherAccount),
            (409, body("APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH"), .linkedToAnotherAccount),
            (403, #"{"detail":"Apple purchases require a signed-in user session"}"#, .refused),
            (403, body("APPLE_IAP_PRODUCT_NOT_ALLOWED"), .refused),
            (400, body("APPLE_IAP_ACCOUNT_TOKEN_MISMATCH"), .refused),
        ]
        for (status, answer, expected) in cases {
            let result = await error {
                _ = try await self.makeServer([Self.transactions: (status, answer)]).submit(signedTransactionInfo: "jws")
            }
            XCTAssertEqual(result, expected, "\(status) \(answer)")
        }
    }

    func test_a_web_subscription_blocks_buying_another_plan_here() async {
        // A Pro subscription bought on the web: the server would apply an App Store Max as well, so the app must not
        // sell one.
        let web = #"{"membership_tier":"pro","unlimited_prompt_builder":false,"unlimited_runs":false,"#
            + #""donation_total_usd":0.0,"active_subscription":{"status":"active","#
            + #""current_period_end":"2026-12-03T00:00:00Z","cancel_at_period_end":false},"monthly_membership_usd":29}"#
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (200, web)])
        let store = FakeStore(events: Events())
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        guard case .ready(_, let tier, let active) = coordinator.state else { return XCTFail("\(coordinator.state)") }
        XCTAssertEqual(tier, "pro")
        XCTAssertTrue(active, "a web subscription is a running one")

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty, "no App Store Max on top of a web Pro")
        XCTAssertEqual(coordinator.notice, AppleSubscriptionsCoordinator.alreadySubscribed)
    }

    func test_an_answer_for_an_account_no_longer_signed_in_is_not_used() async {
        let server = makeServer([Self.transactions: (200, Self.entitlements)])
        let tokens = self.tokens
        PlansURLProtocol.onRequest = { tokens.token = "someone-else" }
        let result = await error { _ = try await server.submit(signedTransactionInfo: "jws") }
        XCTAssertEqual(result, .accountChanged)
    }

    func test_signed_out_never_calls_the_server() async {
        tokens.token = nil
        let result = await error { _ = try await self.makeServer([Self.products: (200, Self.plansBody)]).plans() }
        XCTAssertEqual(result, .reauthenticationRequired)
        XCTAssertTrue(PlansURLProtocol.requests().isEmpty)
    }
}
