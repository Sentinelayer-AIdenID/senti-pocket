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
    /// `GET /billing/status`: the account's tier, its web and App Store subscriptions, or a failure to read it.
    var tier: String?
    var hasWeb = false
    var hasApple = false
    var statusFails = false
    /// Holds every post until released, so a delivery can be caught in flight.
    var holdSubmits = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(events: Events) {
        self.events = events
    }

    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    func releaseHeld() {
        lock.lock()
        let waiting = held
        held = []
        lock.unlock()
        waiting.forEach { $0.resume() }
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
        if holdSubmits {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                held.append(continuation)
                lock.unlock()
            }
        }
        lock.lock()
        let answer = submitAnswers.isEmpty ? .success("pro") : submitAnswers.removeFirst()
        lock.unlock()
        return try answer.get()
    }

    func accountStatus() async throws -> AppleSubscriptionsAccountStatus {
        if statusFails { throw AppleSubscriptionsServerError.unavailable }
        return AppleSubscriptionsAccountStatus(tier: tier, hasWebSubscription: hasWeb, hasAppleSubscription: hasApple)
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
private func plans(_ coordinator: AppleSubscriptionsCoordinator) -> AppleSubscriptionsPlans? {
    switch coordinator.state {
    case .ready(let plans), .purchasing(let plans): return plans
    case .hidden, .loading, .failed: return nil
    }
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

    private func buyable(_ coordinator: AppleSubscriptionsCoordinator) -> [String] {
        guard let shown = plans(coordinator) else { return [] }
        return shown.offers.filter(shown.canBuy).map(\.productId)
    }

    func test_the_plans_show_each_offer_at_the_app_store_price_cheapest_first() async {
        server.tier = "free"
        let coordinator = await readyCoordinator()
        guard let shown = plans(coordinator) else { return XCTFail("\(coordinator.state)") }
        XCTAssertEqual(shown.offers.map(\.tier), ["pro", "max"])
        XCTAssertEqual(shown.offers.map(\.name), ["Pro", "Max"])
        XCTAssertEqual(shown.offers.map(\.priceLine), ["$29.00 per month", "$99.00 per month"])
        XCTAssertFalse(shown.offers[0].summary.isEmpty)
        XCTAssertEqual(shown.currentTier, "free")
        XCTAssertEqual(shown.standing, .open)
        XCTAssertEqual(buyable(coordinator), [proId, maxId])
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

    func test_each_subscribe_button_names_its_plan_and_price() async {
        server.tier = "max"
        let atMax = await readyCoordinator()
        guard let maxPlans = plans(atMax) else { return XCTFail("\(atMax.state)") }
        XCTAssertEqual(SubscriptionsView.buttonLabel(for: maxPlans.offers[0], in: maxPlans), "Pro, included in your plan")
        XCTAssertEqual(SubscriptionsView.buttonLabel(for: maxPlans.offers[1], in: maxPlans), "Max, your plan, $99.00 per month")

        server.tier = "free"
        let free = await readyCoordinator()
        guard let freePlans = plans(free) else { return XCTFail("\(free.state)") }
        XCTAssertEqual(freePlans.offers.map { SubscriptionsView.buttonLabel(for: $0, in: freePlans) },
                       ["Subscribe to Pro, $29.00 per month", "Subscribe to Max, $99.00 per month"])
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
        XCTAssertEqual(plans(coordinator)?.currentTier, "pro")
        XCTAssertNil(coordinator.notice)
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

    func test_a_404_after_a_charge_says_so_and_keeps_the_plans() async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(71))
        server.submitAnswers = [.failure(.off)]

        await coordinator.subscribe(to: proId)

        guard case .ready = coordinator.state else { return XCTFail("the plans stay: \(coordinator.state)") }
        XCTAssertEqual(coordinator.notice?.hasPrefix("Your purchase went through, but Senti can't apply it right now."), true)
        XCTAssertEqual(events.finished, [], "kept with the App Store")
    }

    func test_a_submit_that_needs_sign_in_again_never_finishes() async {
        var asked = 0
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store,
                                                        onReauthenticationRequired: { asked += 1 })
        server.submitAnswers = [.failure(.reauthenticationRequired)]

        let delivery = await coordinator.deliver(store.transaction(15))

        XCTAssertEqual(delivery, .signedOut)
        XCTAssertEqual(events.posted, ["jws-15"])
        XCTAssertEqual(events.finished, [], "a 401, or a session the server will not take, is not the server taking it")
        XCTAssertEqual(asked, 1)
        XCTAssertNil(coordinator.line)
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

    // MARK: The server's refusals, code by code

    private func refuse(_ error: AppleSubscriptionsServerError, finishes: Bool,
                        shows expected: AppleSubscriptionsCoordinator.Line,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let coordinator = await readyCoordinator()
        store.purchaseOutcome = .purchased(store.transaction(80))
        server.submitAnswers = [.failure(error)]

        await coordinator.subscribe(to: proId)

        XCTAssertEqual(events.posted, ["jws-80"], file: file, line: line)
        XCTAssertEqual(events.finished, finishes ? ["80"] : [], "finished: \(finishes)", file: file, line: line)
        XCTAssertEqual(coordinator.line, expected, file: file, line: line)
        XCTAssertNil(coordinator.notice, "said in a line on the screen, not an alert", file: file, line: line)
        guard case .ready = coordinator.state else {
            return XCTFail("the plans stay: \(coordinator.state)", file: file, line: line)
        }
    }

    func test_account_not_found_is_left_unfinished_with_its_line() async {
        await refuse(.accountNotFound, finishes: false, shows: .accountNotFound)
    }

    func test_another_accounts_subscription_is_left_unfinished_with_its_line() async {
        await refuse(.linkedToAnotherAccount, finishes: false, shows: .linkedToAnotherAccount)
        XCTAssertEqual(AppleSubscriptionsCoordinator.Line.linkedToAnotherAccount.text,
                       "This Apple ID's subscription is linked to another Senti account. Contact help@plexaura.io.")
    }

    func test_an_ownership_conflict_is_left_unfinished_for_support() async {
        await refuse(.ownershipConflict, finishes: false, shows: .ownershipConflict)
        XCTAssertTrue(AppleSubscriptionsCoordinator.Line.ownershipConflict.text.contains("Contact help@plexaura.io."))
    }

    func test_a_test_purchase_from_an_account_not_allowed_is_left_unfinished() async {
        await refuse(.sandboxNotAllowed, finishes: false, shows: .sandboxNotAllowed)
        XCTAssertEqual(AppleSubscriptionsCoordinator.Line.sandboxNotAllowed.text,
                       "Test purchases aren't enabled for this account.")
    }

    func test_family_sharing_is_finished_and_says_it_is_not_supported() async {
        await refuse(.familySharingNotSupported, finishes: true, shows: .familySharingNotSupported)
        XCTAssertTrue(AppleSubscriptionsCoordinator.Line.familySharingNotSupported.text.contains("Family Sharing isn't supported"))
    }

    func test_a_product_the_server_does_not_sell_is_finished() async {
        await refuse(.productNotAllowed, finishes: true, shows: .notApplied)
    }

    func test_an_invalid_transaction_is_finished() async {
        await refuse(.invalidTransaction, finishes: true, shows: .notApplied)
    }

    func test_any_other_refusal_is_left_unfinished_without_naming_an_account() async {
        await refuse(.refused, finishes: false, shows: .notApplied)
        XCTAssertFalse(AppleSubscriptionsCoordinator.Line.notApplied.text.contains("signed in"))
    }

    func test_a_refusal_is_never_posted_again_this_session() async {
        for (index, error) in [AppleSubscriptionsServerError.refused, .linkedToAnotherAccount, .sandboxNotAllowed,
                               .ownershipConflict, .accountNotFound].enumerated() {
            let id = UInt64(40 + index)
            let coordinator = await readyCoordinator()
            server.submitAnswers = [.failure(error)]
            _ = await coordinator.deliver(store.transaction(id))

            let again = await coordinator.deliver(store.transaction(id))
            store.unfinishedTransactions = [store.transaction(id)]
            await coordinator.retryUnfinished()
            store.entitlements = [store.transaction(id)]
            await coordinator.restore()
            store.unfinishedTransactions = []
            store.entitlements = []

            XCTAssertEqual(again, .refused(error))
            XCTAssertEqual(events.posted.filter { $0 == "jws-\(id)" }.count, 1, "\(error): posted once this session")
        }
        XCTAssertEqual(events.finished, [])
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

    // MARK: Nothing sold twice

    func test_an_unread_plan_sells_nothing_until_it_is_read() async {
        server.statusFails = true
        let coordinator = await readyCoordinator()
        XCTAssertEqual(plans(coordinator)?.standing, .unknown)
        XCTAssertEqual(buyable(coordinator), [], "an unknown plan is no sale")
        XCTAssertEqual(SubscriptionsView.standingText(.unknown), "Couldn't check your plan. Try again.")

        await coordinator.subscribe(to: maxId)
        XCTAssertTrue(store.purchases.isEmpty, "a web subscriber whose status did not load is never sold Max")

        server.statusFails = false
        await coordinator.refresh()
        XCTAssertEqual(plans(coordinator)?.standing, .open, "trying again reads it")
        await coordinator.subscribe(to: maxId)
        XCTAssertEqual(store.purchases.map { $0.productId }, [maxId])
    }

    func test_a_status_that_fails_right_before_the_purchase_stops_it() async {
        let coordinator = await readyCoordinator()
        XCTAssertEqual(plans(coordinator)?.standing, .open)
        server.statusFails = true

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty)
        XCTAssertEqual(plans(coordinator)?.standing, .unknown)
    }

    func test_every_plan_at_or_below_the_accounts_tier_is_closed() async {
        let cases: [(String?, [String])] = [
            ("team", []), ("enterprise", []), ("business", []), ("max", []), ("pro", [maxId]), ("free", [proId, maxId]),
            (nil, [proId, maxId]),
        ]
        for (tier, expected) in cases {
            server.tier = tier
            let coordinator = await readyCoordinator()
            XCTAssertEqual(buyable(coordinator), expected, "tier \(tier ?? "none")")
        }
    }

    func test_a_team_seat_or_an_admin_set_max_buys_nothing() async {
        server.tier = "team"
        let seat = await readyCoordinator()
        await seat.subscribe(to: proId)
        await seat.subscribe(to: maxId)
        server.tier = "max"
        let floor = await readyCoordinator()
        await floor.subscribe(to: proId)
        XCTAssertTrue(store.purchases.isEmpty, "never charged for a plan the account already has or exceeds")
    }

    func test_an_admin_set_pro_can_still_buy_max() async {
        server.tier = "pro"
        let coordinator = await readyCoordinator()
        await coordinator.subscribe(to: maxId)
        XCTAssertEqual(store.purchases.map { $0.productId }, [maxId])
    }

    func test_a_web_subscription_sells_nothing_and_points_to_the_website() async {
        server.hasWeb = true
        server.tier = "pro"
        let coordinator = await readyCoordinator()
        XCTAssertEqual(plans(coordinator)?.standing, .webSubscription)

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty, "no App Store Max on top of a web Pro")
        let text = SubscriptionsView.standingText(.webSubscription) ?? ""
        XCTAssertTrue(text.contains("website"))
        XCTAssertFalse(text.contains("Settings"), "a web plan is not managed in the iPhone's Settings")
    }

    func test_a_subscription_started_since_the_plans_loaded_blocks_the_purchase() async {
        let coordinator = await readyCoordinator()
        XCTAssertEqual(plans(coordinator)?.standing, .open)
        server.hasWeb = true

        await coordinator.subscribe(to: proId)

        XCTAssertTrue(store.purchases.isEmpty, "the status is read again before the App Store is asked")
        XCTAssertEqual(plans(coordinator)?.standing, .webSubscription)
    }

    func test_this_accounts_app_store_subscription_on_another_apple_id_blocks_the_sale() async {
        server.hasApple = true
        server.tier = "pro"
        let coordinator = await readyCoordinator()
        XCTAssertEqual(plans(coordinator)?.standing, .appleSubscription, "the server's word, whatever this Apple ID holds")
        await coordinator.subscribe(to: maxId)
        XCTAssertTrue(store.purchases.isEmpty)
        XCTAssertEqual(SubscriptionsView.standingText(.appleSubscription)?.hasPrefix("Your plan is active."), true)
    }

    func test_an_apple_id_subscription_that_is_not_this_accounts_is_not_called_yours() async {
        store.entitlements = [store.transaction(30, productId: maxId, verified: false)]
        let unverified = await readyCoordinator()
        XCTAssertEqual(plans(unverified)?.standing, .open, "an unverified entitlement proves nothing")

        store.entitlements = [store.transaction(31, productId: maxId)]
        let holder = await readyCoordinator()
        XCTAssertEqual(plans(holder)?.standing, .appleIDHoldsAnother)
        XCTAssertEqual(SubscriptionsView.standingText(.appleIDHoldsAnother)?.contains("Your plan is active"), false)
        await holder.subscribe(to: proId)
        XCTAssertTrue(store.purchases.isEmpty, "not a second subscription on this Apple ID")
    }

    // MARK: Restore, updates, unfinished

    func test_restore_syncs_then_posts_every_current_entitlement() async throws {
        let coordinator = await readyCoordinator()
        store.entitlements = [store.transaction(7), store.transaction(8, productId: maxId), store.transaction(9, verified: false)]
        server.submitAnswers = [.success("pro"), .success("max")]

        await coordinator.restore()

        XCTAssertEqual(events.posted, ["jws-7", "jws-8"], "every verified entitlement, and only those")
        XCTAssertEqual(events.finished, ["7", "8"])
        let all = events.all
        XCTAssertLessThan(try XCTUnwrap(all.firstIndex(of: "sync")), try XCTUnwrap(all.firstIndex(of: "post jws-7")))
        XCTAssertEqual(plans(coordinator)?.currentTier, "max")
        XCTAssertNotEqual(plans(coordinator)?.standing, .open, "nothing more is sold once a plan is restored")
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

    func test_restore_while_that_purchase_is_still_being_applied_does_not_say_restored() async {
        let coordinator = await readyCoordinator()
        server.holdSubmits = true
        let inFlight = Task { await coordinator.deliver(self.store.transaction(70)) }
        let held = await eventually { self.server.heldCount == 1 }
        XCTAssertTrue(held)

        store.entitlements = [store.transaction(70)]
        await coordinator.restore()

        XCTAssertEqual(coordinator.notice, "A purchase is still being applied. Check again in a moment.")
        server.holdSubmits = false
        server.releaseHeld()
        _ = await inFlight.value
        XCTAssertEqual(events.posted, ["jws-70"], "posted once")
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

    // MARK: Off

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
        server.submitAnswers = [.failure(.off)]
        _ = await coordinator.deliver(store.transaction(14))
        XCTAssertEqual(coordinator.state, .hidden, "a 404 on a transaction outside a purchase hides the plans too")
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

    /// An error answer as the API sends it: its own envelope, `error` at the top.
    private static func errorBody(_ code: String) -> String {
        #"{"error":{"code":"\#(code)","message":"m","request_id":"r"}}"#
    }

    /// The same answer in the framework's own shape, under `detail` (what a bare app would send).
    private static func nestedErrorBody(_ code: String) -> String {
        #"{"detail":{"error":{"code":"\#(code)","message":"m","request_id":"r"}}}"#
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

    func test_the_status_gives_the_tier_and_which_subscriptions_are_running() async throws {
        let web = #"{"membership_tier":"pro","active_subscription":{"status":"active","current_period_end":null,"#
            + #""cancel_at_period_end":false},"apple_subscription":null,"unlimited_runs":false}"#
        let apple = #"{"membership_tier":"max","active_subscription":null,"apple_subscription":{"tier":"max","#
            + #""status":"grace_period","active_until":"2026-12-04T12:00:00Z","environment":"Production"}}"#
        let none = #"{"membership_tier":"free","active_subscription":null,"apple_subscription":null}"#
        let readWeb = try await makeServer([Self.status: (200, web)]).accountStatus()
        XCTAssertEqual(readWeb, AppleSubscriptionsAccountStatus(tier: "pro", hasWebSubscription: true, hasAppleSubscription: false))
        let readApple = try await makeServer([Self.status: (200, apple)]).accountStatus()
        XCTAssertEqual(readApple, AppleSubscriptionsAccountStatus(tier: "max", hasWebSubscription: false, hasAppleSubscription: true))
        let readNone = try await makeServer([Self.status: (200, none)]).accountStatus()
        XCTAssertEqual(readNone, AppleSubscriptionsAccountStatus(tier: "free", hasWebSubscription: false, hasAppleSubscription: false))
        XCTAssertEqual(PlansURLProtocol.requests().first?.0.url?.path, Self.status)
        let broken = await error { _ = try await self.makeServer([Self.status: (500, "{}")]).accountStatus() }
        XCTAssertEqual(broken, .unavailable)
    }

    func test_the_servers_codes_map_to_what_the_app_does() async {
        // The API's own envelope (production) and the framework's nested one: the code is read from either.
        for body in [Self.errorBody, Self.nestedErrorBody] {
            await codesMap(body)
        }
    }

    func test_the_code_is_read_from_the_apis_own_envelope_first() {
        XCTAssertEqual(HTTPAppleSubscriptionsServer.errorCode(in: Data(Self.errorBody("APPLE_IAP_SANDBOX_NOT_ALLOWED").utf8)),
                       "APPLE_IAP_SANDBOX_NOT_ALLOWED")
        XCTAssertEqual(HTTPAppleSubscriptionsServer.errorCode(in: Data(Self.nestedErrorBody("APPLE_IAP_OWNERSHIP_CONFLICT").utf8)),
                       "APPLE_IAP_OWNERSHIP_CONFLICT")
        // An OAuth-style answer carries `error` as a string: no code, so a plain refusal.
        XCTAssertNil(HTTPAppleSubscriptionsServer.errorCode(in: Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertNil(HTTPAppleSubscriptionsServer.errorCode(in: Data("not json".utf8)))
    }

    private func codesMap(_ errorBody: (String) -> String) async {
        let cases: [(Int, String, AppleSubscriptionsServerError)] = [
            (403, errorBody("APPLE_IAP_SIGNED_IN_SESSION_REQUIRED"), .reauthenticationRequired),
            (409, errorBody("APPLE_IAP_ACCOUNT_NOT_FOUND"), .accountNotFound),
            (403, errorBody("APPLE_IAP_ACCOUNT_TOKEN_MISMATCH"), .linkedToAnotherAccount),
            (403, errorBody("APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH"), .linkedToAnotherAccount),
            (409, errorBody("APPLE_IAP_TRANSACTION_ACCOUNT_MISMATCH"), .linkedToAnotherAccount),
            (409, errorBody("APPLE_IAP_OWNERSHIP_CONFLICT"), .ownershipConflict),
            (403, errorBody("APPLE_IAP_SANDBOX_NOT_ALLOWED"), .sandboxNotAllowed),
            (403, errorBody("APPLE_IAP_FAMILY_SHARING_NOT_SUPPORTED"), .familySharingNotSupported),
            (400, errorBody("APPLE_IAP_PRODUCT_NOT_ALLOWED"), .productNotAllowed),
            (400, errorBody("APPLE_IAP_INVALID_TRANSACTION"), .invalidTransaction),
            // A finishing code with any other status is a plain refusal: it never finishes a transaction.
            (409, errorBody("APPLE_IAP_FAMILY_SHARING_NOT_SUPPORTED"), .refused),
            (403, errorBody("APPLE_IAP_PRODUCT_NOT_ALLOWED"), .refused),
            (422, errorBody("APPLE_IAP_INVALID_TRANSACTION"), .refused),
            (400, errorBody("APPLE_IAP_PRODUCT_TYPE_NOT_ALLOWED"), .refused),
            (400, errorBody("APPLE_IAP_INVALID_SIGNED_DATA"), .refused),
            (403, #"{"detail":"Forbidden"}"#, .refused),
            (401, "{}", .reauthenticationRequired),
            (404, #"{"detail":"Not Found"}"#, .off),
            (408, "{}", .unavailable), (429, "{}", .unavailable), (500, "{}", .unavailable), (503, "{}", .unavailable),
        ]
        for (status, body, expected) in cases {
            let result = await error {
                _ = try await self.makeServer([Self.transactions: (status, body)]).submit(signedTransactionInfo: "jws")
            }
            XCTAssertEqual(result, expected, "\(status) \(body)")
        }
        let offline = await error { _ = try await self.makeServer([:]).submit(signedTransactionInfo: "jws") }
        XCTAssertEqual(offline, .unavailable)
    }

    func test_only_three_codes_finish_a_transaction() {
        let finishing: [AppleSubscriptionsServerError] = [.familySharingNotSupported, .productNotAllowed, .invalidTransaction]
        let kept: [AppleSubscriptionsServerError] = [.sandboxNotAllowed, .ownershipConflict, .accountNotFound,
                                                     .linkedToAnotherAccount, .refused, .off, .reauthenticationRequired,
                                                     .accountChanged, .unavailable]
        XCTAssertTrue(finishing.allSatisfy(\.finishesTransaction))
        XCTAssertFalse(kept.contains(where: \.finishesTransaction))
    }

    func test_a_web_subscription_blocks_buying_another_plan_here() async {
        // A Pro subscription bought on the web: the server would apply an App Store Max as well, so the app must not
        // sell one.
        let web = #"{"membership_tier":"pro","unlimited_prompt_builder":false,"unlimited_runs":false,"#
            + #""donation_total_usd":0.0,"active_subscription":{"status":"active","#
            + #""current_period_end":"2026-12-03T00:00:00Z","cancel_at_period_end":false},"apple_subscription":null,"#
            + #""monthly_membership_usd":29}"#
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (200, web)])
        let store = FakeStore(events: Events())
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertEqual(plans(coordinator)?.standing, .webSubscription, "a web subscription is a running one")

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty, "no App Store Max on top of a web Pro")
    }

    func test_an_app_store_subscription_on_another_apple_id_blocks_buying_here() async {
        let apple = #"{"membership_tier":"pro","active_subscription":null,"apple_subscription":{"tier":"pro","#
            + #""status":"active","active_until":"2026-12-04T12:00:00Z","environment":"Production"}}"#
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (200, apple)])
        let store = FakeStore(events: Events())
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertEqual(plans(coordinator)?.standing, .appleSubscription)

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty, "not a second App Store subscription on another Apple ID")
    }

    func test_a_status_the_server_cannot_give_sells_nothing() async {
        let server = makeServer([Self.products: (200, Self.plansBody), Self.status: (500, Self.errorBody("BILLING_STATUS_ERROR"))])
        let store = FakeStore(events: Events())
        let coordinator = AppleSubscriptionsCoordinator(server: server, store: store)
        await coordinator.refresh()
        XCTAssertEqual(plans(coordinator)?.standing, .unknown)

        await coordinator.subscribe(to: maxId)

        XCTAssertTrue(store.purchases.isEmpty)
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
