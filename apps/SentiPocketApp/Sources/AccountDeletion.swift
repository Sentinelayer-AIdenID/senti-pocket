import Foundation
import PocketContracts

/// Where the account's deletion stands, as the server says.
struct AccountDeletionStatus: Equatable, Sendable {
    /// True from the request until it is cancelled.
    let isPending: Bool
    let requestedAt: Date?
    /// When the account goes: Keep my account works until then, and the server refuses it from then on (409).
    let deleteAfter: Date?
    /// The server's wait between a request and the deletion, in days, when its answer says so (`grace_days`). Until
    /// the status route sends it, nothing tells the phone the wait before a request, so no number of days is shown.
    let graceDays: Int?

    init(isPending: Bool, requestedAt: Date?, deleteAfter: Date?, graceDays: Int? = nil) {
        self.isPending = isPending
        self.requestedAt = requestedAt
        self.deleteAfter = deleteAfter
        self.graceDays = graceDays
    }
}

extension AccountDeletionStatus {
    /// `{"status": "none"|"pending", "requested_at": iso|null, "delete_after": iso|null}`, the dates as the server
    /// writes them (`2026-11-13T06:12:34.567890+00:00`), and `grace_days` when it is there; nil for any other shape.
    init?(body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let status = object["status"] as? String,
              status == "none" || status == "pending" else { return nil }
        self.init(
            isPending: status == "pending",
            requestedAt: (object["requested_at"] as? String).flatMap { ParsedSessionTimestamp($0).date },
            deleteAfter: (object["delete_after"] as? String).flatMap { ParsedSessionTimestamp($0).date },
            graceDays: Self.parseGraceDays(object["grace_days"])
        )
    }

    /// A whole number of days within the server's own bounds (1 to 365). Anything else (a fraction, a string, true)
    /// is not a number of days, and the screens say none.
    static func parseGraceDays(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let days = number.doubleValue
        guard days.rounded() == days, days >= 1, days <= 365 else { return nil }
        return Int(days)
    }
}

/// Why an account-deletion call did not go through. Response bodies are never shown.
enum AccountDeletionError: Error, Equatable {
    /// 404: the server does not offer account deletion (or no longer has the account).
    case notOffered
    /// No token, or the server refused it (401).
    case signedOut
    /// 409 on cancel: the date to keep the account has passed.
    case deadlinePassed
    /// 429: more than the server takes in a minute (10 for the three routes together).
    case rateLimited
    /// No answer came back.
    case unreachable
    /// Any other answer, or one this app cannot read.
    case failed
}

/// The account-deletion routes, as yourself. A protocol so the coordinator is testable without a network.
protocol AccountDeleting: Sendable {
    func status() async throws -> AccountDeletionStatus
    func requestDeletion() async throws -> AccountDeletionStatus
    func cancelDeletion() async throws
}

/// `GET`/`POST /api/v1/me/account/deletion` and `POST /api/v1/me/account/deletion/cancel`, with the app's own
/// sign-in token. Every route answers 404 while the server has deletion turned off. Yours alone: no cache, no cookies,
/// the bearer per request.
final class HTTPAccountDeletionClient: AccountDeleting, @unchecked Sendable {
    private let apiBaseURL: URL?
    /// The no-cache, no-cookie session by default (read by a test).
    let urlSession: URLSession
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

    func status() async throws -> AccountDeletionStatus {
        let (status, body) = try await send("GET", path: "/api/v1/me/account/deletion")
        guard status == 200 else { throw Self.failure(for: status) }
        guard let decoded = AccountDeletionStatus(body: body) else { throw AccountDeletionError.failed }
        return decoded
    }

    func requestDeletion() async throws -> AccountDeletionStatus {
        let (status, body) = try await send("POST", path: "/api/v1/me/account/deletion")
        guard status == 202 else { throw Self.failure(for: status) }
        // Accepted means scheduled, and every sign-in has already ended, even if the body cannot be read.
        let decoded = AccountDeletionStatus(body: body)
        return AccountDeletionStatus(isPending: true, requestedAt: decoded?.requestedAt,
                                     deleteAfter: decoded?.deleteAfter, graceDays: decoded?.graceDays)
    }

    func cancelDeletion() async throws {
        let (status, _) = try await send("POST", path: "/api/v1/me/account/deletion/cancel")
        switch status {
        case 200..<300: return
        case 409: throw AccountDeletionError.deadlinePassed
        default: throw Self.failure(for: status)
        }
    }

    private func send(_ method: String, path: String) async throws -> (Int, Data) {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw AccountDeletionError.failed
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw AccountDeletionError.signedOut }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw AccountDeletionError.failed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AccountDeletionError.unreachable
        }
        // An answer for a token that has since been replaced is not this account's.
        guard tokenProvider() == token else { throw AccountDeletionError.failed }
        guard let http = response as? HTTPURLResponse else { throw AccountDeletionError.unreachable }
        return (http.statusCode, data)
    }

    private static func failure(for status: Int) -> AccountDeletionError {
        switch status {
        case 401: return .signedOut
        case 404: return .notOffered
        case 429: return .rateLimited
        default: return .failed
        }
    }
}

/// The deletion screen's request: idle, waiting for the second yes, on its way, or why it did not go through.
enum AccountDeletionRequestState: Equatable {
    case idle
    /// "Delete my account" was tapped and the confirmation is up. Only the confirmation's own button sends.
    case confirming
    case sending
    case failed(String)
}

/// The full-screen notice shown while the account is scheduled for deletion.
struct AccountDeletionPendingNotice: Equatable {
    enum Phase: Equatable {
        case waiting
        case keeping
        case failed(String)
        case deadlinePassed
    }

    let deleteAfter: Date?
    var phase: Phase

    /// Keep my account is offered until the date to keep it has passed; Sign out is always offered.
    var offersKeepAccount: Bool { phase != .deadlinePassed }
}

/// The date shown over the sign-in screen once a deletion request went through.
struct AccountDeletionScheduled: Equatable {
    let deleteAfter: Date?
}

/// Account deletion for the signed-in person: the Settings row, the request, and the pending notice.
///
/// Nothing on this phone is removed before the server's 202: the sign-out that follows it clears the token and what
/// the person left here. The one step taken before the request is stopping this phone's call ring, because the 202
/// ends the token that removal needs; if the request does not go through, calls ring again.
@MainActor
final class AccountDeletionCoordinator: ObservableObject {
    /// False only once the server answers 404 (it does not offer deletion). Any other failure keeps the row, so the
    /// way to delete the account stays where App Review looks for it, and a request that fails says why.
    @Published private(set) var isOffered = true
    /// The server's wait in days, when its status says (`grace_days`); nil shows no number.
    @Published private(set) var graceDays: Int?
    @Published private(set) var request: AccountDeletionRequestState = .idle
    /// Set while the server says deletion is scheduled; the app shows only the notice.
    @Published private(set) var pending: AccountDeletionPendingNotice?
    @Published private(set) var scheduled: AccountDeletionScheduled?

    /// Stops this phone's call ringing and marks its registration for removal, as sign-out starts.
    var beginCallRingRevoke: (() throws -> Void)?
    /// Removes the call-ring registration while the token still works, as sign-out does.
    var finishCallRingRevoke: (() async throws -> Void)?
    /// Turns call ringing back on when the deletion was not requested.
    var rearmCallRing: (() -> Void)?
    /// After Keep my account: the request removed this account's notification registrations on the server, and
    /// keeping the account brings none back, so the phone registers again.
    var registerAgain: (() -> Void)?

    private let client: any AccountDeleting
    /// Moves on each sign-in, so an answer for the last account changes nothing.
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    init(client: any AccountDeleting) {
        self.client = client
    }

    /// A new sign-in: the last account's answers are forgotten until the server answers for this one.
    @discardableResult
    func start() -> Task<Void, Never> {
        generation &+= 1
        refreshTask = nil
        isOffered = true
        graceDays = nil
        request = .idle
        pending = nil
        scheduled = nil
        return refresh()
    }

    /// Asks the server where deletion stands; one question at a time.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let generation = self.generation
        let client = self.client
        let task = Task { [weak self] in
            let answer: Result<AccountDeletionStatus, AccountDeletionError>
            do {
                answer = .success(try await client.status())
            } catch {
                answer = .failure(error as? AccountDeletionError ?? .failed)
            }
            guard let self, self.generation == generation else { return }
            self.refreshTask = nil
            self.apply(answer)
        }
        refreshTask = task
        return task
    }

    /// Only what changed is set, so the views that watch this are not drawn again for the same answer.
    private func apply(_ answer: Result<AccountDeletionStatus, AccountDeletionError>) {
        switch answer {
        case .success(let status):
            if !isOffered { isOffered = true }
            if graceDays != status.graceDays { graceDays = status.graceDays }
            if status.isPending {
                if pending == nil {
                    pending = AccountDeletionPendingNotice(deleteAfter: status.deleteAfter, phase: .waiting)
                }
            } else if pending != nil {
                pending = nil
            }
        case .failure(.notOffered):
            if isOffered { isOffered = false }
        case .failure:
            break
        }
    }

    /// A protected read was refused because deletion is pending: the status route gives the date for the notice.
    func pendingReported() {
        guard pending == nil else { return }
        refresh()
    }

    /// The first yes ("Delete my account"): the confirmation comes up, and nothing is sent.
    func askToDelete() {
        switch request {
        case .idle, .failed: request = .confirming
        case .confirming, .sending: break
        }
    }

    /// The confirmation was turned down: nothing was sent.
    func dismissConfirmation() {
        if request == .confirming { request = .idle }
    }

    /// The second yes, from the confirmation's own button: only now is the request sent, once. Calls stop ringing
    /// first, while the token still works (the 202 ends it); only that 202 signs this phone out, once the date is set
    /// to show. Otherwise calls ring again and the screen says why.
    @discardableResult
    func confirmDeletion(signOut: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard request == .confirming else { return nil }
        request = .sending
        let generation = self.generation
        return Task { [weak self] in
            await self?.send(generation: generation, signOut: signOut)
        }
    }

    private func send(generation: UInt64, signOut: @escaping @MainActor () -> Void) async {
        do {
            try beginCallRingRevoke?()
            try await finishCallRingRevoke?()
        } catch {
            guard self.generation == generation else { return }
            rearmCallRing?()
            request = .failed(AccountDeletionCopy.requestFailure(.unreachable))
            return
        }
        // Another sign-in since: its token must never carry this request.
        guard self.generation == generation else { return }
        do {
            let status = try await client.requestDeletion()
            guard self.generation == generation else { return }
            request = .idle
            scheduled = AccountDeletionScheduled(deleteAfter: status.deleteAfter)
            signOut()
        } catch {
            guard self.generation == generation else { return }
            rearmCallRing?()
            request = .failed(AccountDeletionCopy.requestFailure(error as? AccountDeletionError ?? .failed))
        }
    }

    /// Cancels the scheduled deletion; on the server's yes this phone registers for notifications again and the app
    /// carries on.
    func keepAccount(onContinue: @escaping @MainActor () -> Void) async {
        guard var notice = pending, notice.offersKeepAccount, notice.phase != .keeping else { return }
        notice.phase = .keeping
        pending = notice
        let generation = self.generation
        do {
            try await client.cancelDeletion()
            guard self.generation == generation else { return }
            pending = nil
            registerAgain?()
            onContinue()
        } catch {
            guard self.generation == generation else { return }
            let failure = error as? AccountDeletionError ?? .failed
            notice.phase = failure == .deadlinePassed
                ? .deadlinePassed
                : .failed(AccountDeletionCopy.keepFailure(failure))
            pending = notice
        }
    }

    /// The deletion screen opens again: a failed request's words and a confirmation left open go.
    func resetRequest() {
        if request != .sending { request = .idle }
    }

    func dismissScheduled() {
        scheduled = nil
    }
}

/// The words the deletion screens use. They say what the server does: the request signs the account out everywhere at
/// once, the deletion comes after the server's wait, and only Keep my account (not signing in) stops it. The number of
/// days comes from the server, and only when it says.
enum AccountDeletionCopy {
    static let sheetTitle = "Deleting your account"

    static let rightAwayTitle = "Right away"
    static let rightAway = "You're signed out on every device, notifications stop, and apps and agents you connected "
        + "lose access."

    static let laterTitle = "Later"
    static func later(graceDays: Int?) -> String {
        let what = "your profile and sign-in details, your settings and the files you uploaded are deleted."
        guard let graceDays else {
            return "After a waiting period, \(what) You'll see the date as soon as you confirm."
        }
        return "After \(days(graceDays)), \(what)"
    }

    static let staysTitle = "What stays"
    static let stays = "Messages you sent in shared rooms stay there for the people in them. Payment records are kept."

    static let keepTitle = "If you change your mind"
    static let keep = "Sign in before the date and tap Keep my account. Signing in alone doesn't stop it, and keeping "
        + "your account doesn't sign your other devices or agents back in."

    static let deleteButton = "Delete my account"
    /// VoiceOver reads it after the button: what the button does, and that it asks once more.
    static let deleteHint = "Deletes your account after the waiting period. You'll be asked once more first."

    static let confirmTitle = "Delete your account?"
    static func confirmMessage(graceDays: Int?) -> String {
        guard let graceDays else {
            return "You'll be signed out on every device now. Your account is deleted after the waiting period."
        }
        return "You'll be signed out on every device now. Your account is deleted after \(days(graceDays))."
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// When the account goes, in the phone's time zone: the weekday, the date and the time (the deadline is a moment,
    /// and Keep my account is refused from that minute), with the year only when it is not this year's.
    static func when(_ date: Date, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current,
                     timeZone: TimeZone = .current) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .weekday(.wide).month(.wide).day().hour().minute()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }

    static func scheduledTitle(deleteAfter: Date?) -> String {
        deleteAfter.map { "Your account will be deleted on \(when($0))." } ?? "Your account will be deleted."
    }

    static func scheduledDetail(deleteAfter: Date?) -> String {
        deleteAfter == nil
            ? "You're signed out on every device. Sign in to see the date, or to keep your account."
            : "You're signed out on every device. To keep your account, sign in before then and tap Keep my account."
    }

    static func pendingTitle(deleteAfter: Date?) -> String {
        deleteAfter.map { "Your account will be deleted on \(when($0))." } ?? "Your account is going to be deleted."
    }

    static let pendingDetail = "Tap Keep my account to stop it. Keeping it doesn't sign your other devices or agents "
        + "back in."
    static let deadlinePassedTitle = "Your account is being deleted."
    static let deadlinePassedDetail = "The date to keep it has passed, so it can't be stopped now."

    /// Why a request did not go through. "Nothing was deleted" only where the server's answer says so; a lost
    /// connection may have carried the request, so it claims nothing.
    static func requestFailure(_ error: AccountDeletionError) -> String {
        switch error {
        case .unreachable: return "Couldn't reach Senti. Check your connection and try again."
        case .notOffered: return "Deleting your account isn't available right now. Nothing was deleted."
        case .rateLimited: return "Too many tries. Wait a minute, then try again. Nothing was deleted."
        case .signedOut: return "Your sign-in has ended. Sign in again to see where your account stands."
        case .deadlinePassed, .failed: return "Senti couldn't finish that just now. Try again in a minute."
        }
    }

    static func keepFailure(_ error: AccountDeletionError) -> String {
        switch error {
        case .unreachable: return "Couldn't reach Senti. Check your connection and try again."
        case .rateLimited: return "Too many tries. Wait a minute, then try again."
        case .signedOut: return "Your sign-in has ended. Sign out, then sign in again to keep your account."
        case .notOffered, .deadlinePassed, .failed: return "Senti couldn't keep your account just now. Try again in a minute."
        }
    }
}
