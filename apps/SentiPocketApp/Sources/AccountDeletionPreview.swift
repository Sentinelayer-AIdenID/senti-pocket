#if DEBUG
import Foundation
import SwiftUI
import PocketUI

/// DEBUG-only: `-PocketAccountDeletionPreview` hosts the signed-in root of the root preview (made-up rooms, no
/// network) behind a sign-in that needs no account, with account deletion answered by a made-up server through the
/// app's own HTTP client (`AccountDeletionPreviewServer`). A UI test walks Settings, Delete account, the confirmation,
/// the sign-out and Keep my account on it, and takes the pictures. Made-up data only; never compiled into Release.
///
/// Options:
/// - `-PocketAccountDeletionStage <stage>`, what the server says (default `none`):
///   - `none`: no deletion yet; a request is accepted, for a date seven days on;
///   - `days`: as `none`, and the status says how many days the server waits (`grace_days`: 7);
///   - `pending`: deletion scheduled five days on; Keep my account is accepted;
///   - `deadline`: deletion scheduled, but Keep my account is refused (409: the date has passed);
///   - `limited`: a request is refused (429: too many tries);
///   - `offline`: a request gets no answer;
///   - `slow`: a request and Keep my account are answered after three seconds.
/// - `-PocketAccountDeletionLog`: a strip at the bottom says how many times each route was asked.
enum AccountDeletionPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-PocketAccountDeletionPreview") }

    @MainActor
    static func rootView(whisperModel: WhisperModelProvisioningCoordinator, incomingLinks: IncomingLinkInbox) -> some View {
        // The room list at launch, not a room another preview left open.
        UserDefaults.standard.set("", forKey: "pocket.lastRoomId")
        return AccountDeletionPreviewRoot(whisperModel: whisperModel, incomingLinks: incomingLinks)
    }
}

/// The preview's sign-in, as the app's: the signed-in root while a made-up token is held, the sign-in screen (with
/// the date a deletion was scheduled for over it) once it is not.
private struct AccountDeletionPreviewRoot: View {
    @ObservedObject var whisperModel: WhisperModelProvisioningCoordinator
    @ObservedObject var incomingLinks: IncomingLinkInbox
    @StateObject private var signIn = SignInCoordinator(
        login: { AccountDeletionPreviewSession.shared.token = "preview-session" },
        isLoggedIn: { AccountDeletionPreviewSession.shared.token != nil },
        signOut: { AccountDeletionPreviewSession.shared.token = nil },
        clearProtectedLocalState: {}
    )
    @State private var deletion = AccountDeletionCoordinator(client: HTTPAccountDeletionClient(
        apiBaseURL: URL(string: "https://preview.invalid"),
        urlSession: AccountDeletionPreviewServer.session,
        tokenProvider: { AccountDeletionPreviewSession.shared.token }
    ))

    var body: some View {
        Group {
            if signIn.isAuthenticated {
                AuthenticatedRootView(
                    authenticationEpoch: signIn.authenticationEpoch,
                    whisperModelCoordinator: whisperModel,
                    incomingLinks: incomingLinks,
                    services: RootPreview.api.services,
                    accountDeletion: deletion,
                    onSignOut: { signIn.send(.signOut) },
                    onReauthenticationRequired: { _ in }
                )
                .id(signIn.authenticationEpoch)
            } else {
                PocketSignInView(phase: signIn.phase, offersApple: signIn.offersApple, send: signIn.send)
                    .overlay { AccountDeletionScheduledOverlay(coordinator: deletion) }
            }
        }
        .overlay(alignment: .bottom) {
            if AccountDeletionPreviewServer.showsLog {
                AccountDeletionPreviewLog(counts: AccountDeletionPreviewCounts.shared)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The preview's made-up token, kept in memory; signed in at launch.
private final class AccountDeletionPreviewSession: @unchecked Sendable {
    static let shared = AccountDeletionPreviewSession()
    private let lock = NSLock()
    private var value: String? = "preview-session"

    var token: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The made-up deletion routes behind the preview: the status codes and bodies the Senti API sends (its error
/// envelope, and dates as the server writes them, included), from a state that a request and Keep my account change
/// as the server's do.
final class AccountDeletionPreviewServer: URLProtocol {
    enum Stage: String {
        case unrequested = "none", days, pending, deadline, limited, offline, slow
    }

    static let stage: Stage = Stage(rawValue: RootPreview.argument("-PocketAccountDeletionStage") ?? "") ?? .unrequested
    static let showsLog = ProcessInfo.processInfo.arguments.contains("-PocketAccountDeletionLog")

    /// A session whose every request this server answers.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountDeletionPreviewServer.self]
        return URLSession(configuration: configuration)
    }()

    private struct Deletion {
        var requestedAt: Date?
        var deleteAfter: Date?
    }

    private static let lock = NSLock()
    private static var deletion: Deletion = {
        let now = Date()
        switch AccountDeletionPreviewServer.stage {
        case .pending, .deadline:
            return Deletion(requestedAt: now.addingTimeInterval(-2 * 86_400), deleteAfter: now.addingTimeInterval(5 * 86_400))
        case .unrequested, .days, .limited, .offline, .slow:
            return Deletion(requestedAt: nil, deleteAfter: nil)
        }
    }()

    /// Dates as the server writes them: `2026-11-13T06:12:34.567000+00:00`.
    private static let serverDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        if Self.stage == .slow, method == "POST" { Thread.sleep(forTimeInterval: 3) }
        guard let url = request.url, let answer = Self.answer(method: method, path: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headers = answer.headers
        headers["Content-Type"] = "application/json"
        headers["Cache-Control"] = "no-store"
        guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// What the server answers; nil is no answer at all.
    private static func answer(method: String, path: String) -> (status: Int, body: String, headers: [String: String])? {
        lock.lock()
        defer { lock.unlock() }
        switch (method, path) {
        case ("GET", "/api/v1/me/account/deletion"):
            note("status")
            return (200, statusBody(), [:])
        case ("POST", "/api/v1/me/account/deletion"):
            note("request")
            switch stage {
            case .limited:
                return (429, #"{"error":{"code":"RATE_LIMITED","message":"Too many account deletion requests","request_id":"preview"}}"#,
                        ["Retry-After": "60"])
            case .offline:
                return nil
            case .unrequested, .days, .pending, .deadline, .slow:
                // A repeated request keeps the first date, as the server's does.
                if deletion.deleteAfter == nil {
                    let now = Date()
                    deletion = Deletion(requestedAt: now, deleteAfter: now.addingTimeInterval(7 * 86_400))
                }
                return (202, statusBody(), [:])
            }
        case ("POST", "/api/v1/me/account/deletion/cancel"):
            note("cancel")
            if stage == .deadline {
                return (409, #"{"error":{"code":"HTTP_ERROR","message":"Deletion grace period has ended","details":null,"request_id":"preview"}}"#,
                        [:])
            }
            deletion = Deletion(requestedAt: nil, deleteAfter: nil)
            return (200, statusBody(), [:])
        default:
            return (404, #"{"error":{"code":"HTTP_ERROR","message":"Not found","details":null,"request_id":"preview"}}"#, [:])
        }
    }

    private static func statusBody() -> String {
        var fields: [String]
        if let requestedAt = deletion.requestedAt, let deleteAfter = deletion.deleteAfter {
            fields = [#""status":"pending""#,
                      #""requested_at":"\#(serverDate.string(from: requestedAt))""#,
                      #""delete_after":"\#(serverDate.string(from: deleteAfter))""#]
        } else {
            fields = [#""status":"none""#, #""requested_at":null"#, #""delete_after":null"#]
        }
        if stage == .days { fields.append(#""grace_days":7"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func note(_ route: String) {
        Task { @MainActor in AccountDeletionPreviewCounts.shared.note(route) }
    }
}

/// How many times the made-up server was asked each route, for the UI test.
@MainActor
final class AccountDeletionPreviewCounts: ObservableObject {
    static let shared = AccountDeletionPreviewCounts()
    @Published private(set) var status = 0
    @Published private(set) var request = 0
    @Published private(set) var cancel = 0

    func note(_ route: String) {
        switch route {
        case "status": status += 1
        case "request": request += 1
        case "cancel": cancel += 1
        default: break
        }
    }
}

/// The strip the UI test reads: "server: status 2, request 1, cancel 0".
private struct AccountDeletionPreviewLog: View {
    @ObservedObject var counts: AccountDeletionPreviewCounts

    var body: some View {
        Text("server: status \(counts.status), request \(counts.request), cancel \(counts.cancel)")
            .font(.caption2.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.yellow.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
            .accessibilityIdentifier("preview.deletion.log")
    }
}
#endif
