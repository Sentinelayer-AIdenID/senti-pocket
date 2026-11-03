import Foundation
import PocketContracts

/// Where the account's deletion stands, as the server says.
struct AccountDeletionStatus: Equatable, Sendable {
    /// True from the request until it is cancelled.
    let isPending: Bool
    let requestedAt: Date?
    /// When the account and its data go; signing in before then can keep it.
    let deleteAfter: Date?
}

extension AccountDeletionStatus {
    /// `{"status": "none"|"pending", "requested_at"?, "delete_after"?}`; nil for any other shape.
    init?(body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let status = object["status"] as? String,
              status == "none" || status == "pending" else { return nil }
        isPending = status == "pending"
        requestedAt = (object["requested_at"] as? String).flatMap { ParsedSessionTimestamp($0).date }
        deleteAfter = (object["delete_after"] as? String).flatMap { ParsedSessionTimestamp($0).date }
    }
}

/// Why an account-deletion call did not go through. Response bodies are never shown.
enum AccountDeletionError: Error, Equatable {
    /// 404: the server does not offer account deletion.
    case notOffered
    /// No token, or the server refused it (401).
    case signedOut
    /// 409 on cancel: the date to keep the account has passed.
    case deadlinePassed
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
/// sign-in token. Every route answers 404 while the server has deletion turned off.
final class HTTPAccountDeletionClient: AccountDeleting, @unchecked Sendable {
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
        return AccountDeletionStatus(isPending: true, requestedAt: decoded?.requestedAt, deleteAfter: decoded?.deleteAfter)
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
        default: return .failed
        }
    }
}

/// The confirmation sheet's request: idle, on its way, or why it did not go through.
enum AccountDeletionRequestState: Equatable {
    case idle
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
@MainActor
final class AccountDeletionCoordinator: ObservableObject {
    /// Only a 200 from the status route shows the Settings row; a 404 or a failure hides it.
    @Published private(set) var isOffered = false
    @Published private(set) var request: AccountDeletionRequestState = .idle
    /// Set while the server says deletion is scheduled; the app shows only the notice.
    @Published private(set) var pending: AccountDeletionPendingNotice?
    @Published private(set) var scheduled: AccountDeletionScheduled?

    private let client: any AccountDeleting
    /// Moves on each sign-in, so an answer for the last account changes nothing.
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    init(client: any AccountDeleting) {
        self.client = client
    }

    /// A new sign-in: nothing is shown until the server answers for this account.
    @discardableResult
    func start() -> Task<Void, Never> {
        generation &+= 1
        refreshTask = nil
        isOffered = false
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
            let answer: AccountDeletionStatus?
            do { answer = try await client.status() } catch { answer = nil }
            guard let self, self.generation == generation else { return }
            self.refreshTask = nil
            guard let answer else {
                self.isOffered = false
                return
            }
            self.isOffered = true
            self.pending = answer.isPending
                ? (self.pending ?? AccountDeletionPendingNotice(deleteAfter: answer.deleteAfter, phase: .waiting))
                : nil
        }
        refreshTask = task
        return task
    }

    /// A protected read was refused because deletion is pending: the status route gives the date for the notice.
    func pendingReported() {
        guard pending == nil else { return }
        refresh()
    }

    /// Asks the server to delete the account. Only its 202 signs this phone out, once the date is set to show.
    func requestDeletion(signOut: @escaping @MainActor () -> Void) async {
        guard request != .sending else { return }
        request = .sending
        let generation = self.generation
        do {
            let status = try await client.requestDeletion()
            guard self.generation == generation else { return }
            request = .idle
            scheduled = AccountDeletionScheduled(deleteAfter: status.deleteAfter)
            signOut()
        } catch {
            guard self.generation == generation else { return }
            request = .failed(AccountDeletionCopy.requestFailure(error as? AccountDeletionError ?? .failed))
        }
    }

    /// Cancels the scheduled deletion; on the server's yes the app carries on.
    func keepAccount(onContinue: @escaping @MainActor () -> Void) async {
        guard var notice = pending, notice.offersKeepAccount, notice.phase != .keeping else { return }
        notice.phase = .keeping
        pending = notice
        let generation = self.generation
        do {
            try await client.cancelDeletion()
            guard self.generation == generation else { return }
            pending = nil
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

    /// Clears a failed request's message when the sheet opens again.
    func clearRequestFailure() {
        if case .failed = request { request = .idle }
    }

    func dismissScheduled() {
        scheduled = nil
    }
}

/// The words the deletion screens use.
enum AccountDeletionCopy {
    /// The server's usual wait before deleting; its status route gives no date before a request.
    static let graceDays = 7

    static func date(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    /// What deleting does, for the confirmation sheet.
    static let consequences = [
        "Your account and your data will be deleted after \(graceDays) days.",
        "You'll be signed out on every device now.",
        "Signing in again before then lets you keep your account.",
        "Messages you posted in shared rooms stay with the room."
    ]

    static func scheduled(deleteAfter: Date?) -> String {
        let when = deleteAfter.map { "on \(date($0))" } ?? "after \(graceDays) days"
        return "Your account and your data will be deleted \(when). You've been signed out on every device. "
            + "Sign in again before then to keep your account."
    }

    static func pendingTitle(deleteAfter: Date?) -> String {
        deleteAfter.map { "Your account is scheduled for deletion on \(date($0))." }
            ?? "Your account is scheduled for deletion."
    }

    static let pendingDetail = "Keep your account to cancel the deletion and carry on, or sign out."
    static let deadlinePassedTitle = "Your account is being deleted."
    static let deadlinePassedDetail = "The date to keep it has passed, so it can no longer be cancelled."

    static func requestFailure(_ error: AccountDeletionError) -> String {
        switch error {
        case .unreachable: return "Couldn't reach Senti. You're still signed in; try again when you're connected."
        case .notOffered: return "Deleting your account isn't available right now. You're still signed in."
        case .signedOut: return "Your sign-in has expired. Sign in again, then try again."
        case .deadlinePassed, .failed: return "Senti didn't delete your account. You're still signed in; try again later."
        }
    }

    static func keepFailure(_ error: AccountDeletionError) -> String {
        switch error {
        case .unreachable: return "Couldn't reach Senti. Try again when you're connected."
        case .signedOut: return "Your sign-in has expired. Sign out, then sign in again."
        case .notOffered, .deadlinePassed, .failed: return "Senti couldn't keep your account just now. Try again."
        }
    }
}
