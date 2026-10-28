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
/// the badge. Opening one marks it read (optimistically) and returns where to go.
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

    static let pollInterval: TimeInterval = 60

    init(
        transport: any NotificationsTransport,
        marker: (any NotificationReadMarking)?,
        roomTitle: @escaping @MainActor (String) -> String? = { _ in nil },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.transport = transport
        self.marker = marker
        self.roomTitle = roomTitle
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    var unreadCount: Int { state.unreadCount }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
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

    func refresh() async {
        guard failure != .reauthenticationRequired else { return }
        if notifications.isEmpty { isLoading = true; publish() }
        do {
            let page = try await transport.notifications()
            notifications = page.notifications
            // The server's read state wins once it agrees; keep local reads that it has not caught up with.
            locallyRead = locallyRead.filter { id in notifications.contains { $0.id == id && !$0.isRead } }
            failure = nil
        } catch SessionTransportError.reauthenticationRequired {
            failure = .reauthenticationRequired
            onReauthenticationRequired()
            stopPolling()
        } catch SessionTransportError.cancelled {
        } catch {
            if notifications.isEmpty { failure = .network }
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
        guard let marker else { return }
        Task { try? await marker.markRead(id: id) }
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
            failure: failure
        )
    }
}
