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

/// The server, scripted: what it sells, the account's token, and its answer to each transaction in turn.
private final class FakePlansServer: AppleSubscriptionsServing, @unchecked Sendable {
    let events: Events
    let token = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    var plansAnswer: Result<[AppleSubscriptionPlan], AppleSubscriptionsServerError> = .success([
        AppleSubscriptionPlan(productId: proId, tier: "pro"),
        AppleSubscriptionPlan(productId: maxId, tier: "max"),
    ])
    /// Answers to the transactions posted, first to last; past the end the server accepts and names no tier.
    var submitAnswers: [Result<String?, AppleSubscriptionsServerError>] = []
    var tier: String?
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

    func submit(signedTransactionInfo: String) async throws -> String? {
        events.append("post \(signedTransactionInfo)")
        lock.lock()
        let answer = submitAnswers.isEmpty ? .success(nil) : submitAnswers.removeFirst()
        lock.unlock()
        return try answer.get()
    }

    func currentTier() async throws -> String? { tier }
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

    func unfinished() async -> [AppleStoreTransaction] { unfinishedTransactions }

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
        if case .ready(_, let tier) = coordinator.state { return tier }
        return nil
    }

    func test_the_plans_show_each_offer_at_the_app_store_price_cheapest_first() async {
        server.tier = "free"
        let coordinator = await readyCoordinator()
        guard case .ready(let offers, let tier) = coordinator.state else { return XCTFail("\(coordinator.state)") }
        XCTAssertEqual(offers.map(\.tier), ["pro", "max"])
        XCTAssertEqual(offers.map(\.name), ["Pro", "Max"])
        XCTAssertEqual(offers.map(\.priceLine), ["$29.00 per month", "$99.00 per month"])
        XCTAssertFalse(offers[0].summary.isEmpty)
        XCTAssertEqual(tier, "free")
        XCTAssertTrue(coordinator.isOffered)
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

    func test_an_unverified_transaction_is_never_posted_or_finished() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(4, verified: false))

        await coordinator.subscribe(to: proId)
        let delivery = await coordinator.deliver(store.transaction(5, verified: false))

        XCTAssertEqual(delivery, .unverified)
        XCTAssertEqual(events.posted, [])
        XCTAssertEqual(events.finished, [])
        XCTAssertNotNil(coordinator.notice)
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
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
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
    func submit(signedTransactionInfo: String) async throws -> String? { try await base.submit(signedTransactionInfo: signedTransactionInfo) }
    func currentTier() async throws -> String? { nil }
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
        let missing = await error { _ = try await self.makeServer([Self.products: (404, #"{"detail":"Not Found"}"#)]).plans() }
        XCTAssertEqual(missing, .off)
        let unreadable = await error { _ = try await self.makeServer([Self.products: (200, #"{"enabled":false}"#)]).plans() }
        XCTAssertEqual(unreadable, .off)
        let none = HTTPAppleSubscriptionsServer(apiBaseURL: nil, tokenProvider: { "test-bearer" })
        let unconfigured = await error { _ = try await none.plans() }
        XCTAssertEqual(unconfigured, .off)
    }

    func test_products_404_hides_the_plans_on_screen() async {
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (200, #"{"membership_tier":"free"}"#)])
        let events = Events()
        let store = FakeStore(events: events)
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
        let server = makeServer([Self.transactions: (200, #"{"tier":"max","productId":"x"}"#)])
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

    func test_the_tier_is_read_where_the_answer_names_it() {
        XCTAssertEqual(HTTPAppleSubscriptionsServer.tier(in: Data(#"{"membership_tier":"Pro"}"#.utf8)), "pro")
        XCTAssertEqual(HTTPAppleSubscriptionsServer.tier(in: Data(#"{"entitlement":{"tier":"max"}}"#.utf8)), "max")
        XCTAssertNil(HTTPAppleSubscriptionsServer.tier(in: Data(#"{"ok":true}"#.utf8)))
    }

    func test_the_current_tier_comes_from_billing_status() async throws {
        let server = makeServer([Self.status: (200, #"{"membership_tier":"max","unlimited_runs":true}"#)])
        let tier = try await server.currentTier()
        XCTAssertEqual(tier, "max")
    }

    func test_answers_map_to_what_the_coordinator_does() async {
        let cases: [(Int, AppleSubscriptionsServerError)] = [
            (401, .reauthenticationRequired), (403, .refused), (409, .refused), (422, .refused), (404, .off),
            (429, .unavailable), (503, .unavailable),
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

    func test_an_answer_for_an_account_no_longer_signed_in_is_not_used() async {
        let server = makeServer([Self.transactions: (200, #"{"tier":"max"}"#)])
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
