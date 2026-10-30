import Foundation
import PocketSyncClient
import PocketUI

/// Marking a notification read: `PATCH /api/v1/sessions/notifications/{id}/read` with the user's bearer.
protocol NotificationReadMarking: Sendable {
    func markRead(id: String) async throws
}

final class HTTPNotificationReadMarker: NotificationReadMarking, @unchecked Sendable {
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

    func markRead(id: String) async throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              !id.isEmpty, id.utf8.count <= 128,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RoomSendError.rejected
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        components.percentEncodedPath = "/api/v1/sessions/notifications/\(encoded)/read"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        default: throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
    }
}

/// The bell: the newest notifications, refreshed every minute while the app is active, with the unread count for
/// the badge. Opening one marks it read (optimistically) and returns where to go; so does opening it from its push or
/// its banner (Carter, 10-30: "the notification marked as read as I click and open them"). Only the one opened:
/// a room being open reads nothing by itself (Carter, 10-30: "My notifications have been auto marked as read. Bad").
@MainActor
final class NotificationsCoordinator: ObservableObject {
    @Published private(set) var state = NotificationsPresentationState(rows: [], isLoading: true)

    private let transport: any NotificationsTransport
    private let marker: (any NotificationReadMarking)?
    private let roomTitle: @MainActor (String) -> String?
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    private var notifications: [SentiNotification] = []
    private var locallyRead: Set<String> = []
    private var isLoading = false
    private var failure: SessionLoadFailure?
    private var pollTask: Task<Void, Never>?
    private let now: @Sendable () -> Date
    private var updatedAt: Date?
    private var couldNotUpdate = false
    /// Opened from a push or a banner but not in the bell yet (it reads every 30 s, and a tapped push may be newer
    /// than the list); read when it arrives, if within ten minutes (warden, #275).
    private var pendingOpened: [(link: SentiLink, id: String?, at: Date)] = []
    /// Read marks the server refused; sent again on the next read of the bell (warden, #275).
    private var failedMarks: Set<String> = []
    /// Read marks waiting to go to the server, sent a few at a time.
    private var markQueue: [String] = []
    private var marking = 0
    static let concurrentMarks = 4

    /// The web polls the bell about this often.
    static let pollInterval: TimeInterval = 30

    init(
        transport: any NotificationsTransport,
        marker: (any NotificationReadMarking)?,
        roomTitle: @escaping @MainActor (String) -> String? = { _ in nil },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.transport = transport
        self.marker = marker
        self.roomTitle = roomTitle
        self.sleep = sleep
        self.now = now
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    var unreadCount: Int { state.unreadCount }

    func startPolling(readNow: Bool = true) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            if readNow { await self.refresh() }
            while !Task.isCancelled {
                await self.sleep(Self.pollInterval)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reads the bell. The poll skips it after an expired sign-in; opening the side panel or the bell (`force`) tries
    /// again, and a success brings the poll back. A failed read keeps the list and says it could not update.
    func refresh(force: Bool = false) async {
        guard force || failure != .reauthenticationRequired else { return }
        if notifications.isEmpty { isLoading = true; publish() }
        do {
            let page = try await transport.notifications()
            notifications = page.notifications
            // The server's read state wins once it agrees; keep local reads that it has not caught up with.
            locallyRead = locallyRead.filter { id in notifications.contains { $0.id == id && !$0.isRead } }
            let wasSignedOut = failure == .reauthenticationRequired
            failure = nil
            couldNotUpdate = false
            updatedAt = now()
            if wasSignedOut, pollTask == nil { startPolling(readNow: false) }
            let opened = pendingOpened.filter { now().timeIntervalSince($0.at) < Self.pendingFor }
            pendingOpened = []
            for open in opened { markOpened(open.link, notificationId: open.id, at: open.at) }
            let retry = failedMarks.filter { id in notifications.contains { $0.id == id && !$0.isRead } }
            failedMarks = []
            for id in retry { markRead(id) }
        } catch SessionTransportError.reauthenticationRequired {
            if failure != .reauthenticationRequired { onReauthenticationRequired() }
            failure = .reauthenticationRequired
            stopPolling()
        } catch SessionTransportError.cancelled {
        } catch {
            if notifications.isEmpty { failure = .network } else { couldNotUpdate = true }
        }
        isLoading = false
        publish()
    }

    /// Marks one read and returns its destination, if it points into a room.
    func open(_ id: String) -> SentiLink? {
        guard let notification = notifications.first(where: { $0.id == id }) else { return nil }
        markRead(id)
        return notification.link ?? (notification.sessionId.isEmpty ? nil : SentiLink(sessionId: notification.sessionId))
    }

    func markRead(_ id: String) {
        guard notifications.contains(where: { $0.id == id && !$0.isRead }), !locallyRead.contains(id) else { return }
        locallyRead.insert(id)
        publish()
        guard marker != nil else { return }
        markQueue.append(id)
        sendMarks()
    }

    /// A few marks at a time, never fifty at once (warden, #267). One that fails is unread again here and is sent again
    /// on the next read of the bell.
    private func sendMarks() {
        guard let marker else { return }
        while marking < Self.concurrentMarks, !markQueue.isEmpty {
            let id = markQueue.removeFirst()
            marking += 1
            Task { [weak self] in
                let sent: Bool
                do {
                    try await marker.markRead(id: id)
                    sent = true
                } catch {
                    sent = false
                }
                guard let self else { return }
                self.marking -= 1
                if !sent {
                    self.locallyRead.remove(id)
                    self.failedMarks.insert(id)
                    self.publish()
                }
                self.sendMarks()
            }
        }
    }

    static let pendingFor: TimeInterval = 600

    /// The notification a tapped push or banner was: by its id when the push carries one, else the one its link
    /// names (a message, a reply, a ticket or an agent request), else the room's newest notice. One notification,
    /// never the room's others. Not in the bell yet, it is read when it arrives.
    func markOpened(_ link: SentiLink, notificationId: String? = nil, at: Date? = nil) {
        let target: SentiNotification?
        if let notificationId {
            target = notifications.first { $0.id.lowercased() == notificationId }
        } else {
            target = notifications.first { !$0.isRead && !locallyRead.contains($0.id) && Self.opens($0, link) }
        }
        guard let target else {
            pendingOpened = Array((pendingOpened + [(link, notificationId, at ?? now())]).suffix(10))
            return
        }
        markRead(target.id)
    }

    static func opens(_ notification: SentiNotification, _ link: SentiLink) -> Bool {
        let target = notification.link ?? SentiLink(sessionId: notification.sessionId)
        guard target.sessionId == link.sessionId else { return false }
        if let reply = link.replyId { return target.replyId == reply }
        if let message = link.messageSequence { return target.messageSequence == message }
        if let ticket = link.ticketId { return target.ticketId == ticket }
        if let admission = link.admissionId { return target.admissionId == admission }
        return target.messageSequence == nil && target.replyId == nil && target.ticketId == nil
            && target.admissionId == nil
    }

    /// There is no bulk endpoint, so each unread notification is marked on its own.
    func markAllRead() {
        for notification in notifications where !notification.isRead { markRead(notification.id) }
    }

    private func publish() {
        state = NotificationsPresentationState(
            rows: notifications.map { notification in
                let link = notification.link ?? (notification.sessionId.isEmpty ? nil : SentiLink(sessionId: notification.sessionId))
                return NotificationRow(
                    id: notification.id,
                    kind: notification.kind,
                    title: notification.title,
                    body: notification.body,
                    roomTitle: roomTitle(notification.sessionId),
                    createdAt: notification.createdAt,
                    isRead: notification.isRead || locallyRead.contains(notification.id),
                    canOpen: link != nil
                )
            },
            isLoading: isLoading,
            failure: failure,
            updatedAt: updatedAt,
            couldNotUpdate: couldNotUpdate
        )
    }
}
