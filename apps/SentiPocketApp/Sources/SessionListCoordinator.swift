import Combine
import Foundation
import PocketSyncClient
import PocketUI

/// Main-actor adapter from the actor-owned repository to PocketUI's credential-free presentation state.
///
/// It never accepts a caller-supplied selected session unless that identity is present in the currently authorized
/// rows. A 401 clears the repository and visible selection before the app's sign-in gate is invalidated.
@MainActor
final class SessionListCoordinator: ObservableObject {
    @Published private(set) var state: SessionListPresentationState
    @Published private(set) var selectedSessionId: String?

    private let repository: SessionRepository
    private let onReauthenticationRequired: @MainActor () -> Void
    private let onSelectionChanged: @MainActor (String?) -> Void
    private var snapshot: SessionListSnapshot?
    private var provenance: SessionPresentationProvenance = .unavailable
    private var operation: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var hasStarted = false
    /// How far this phone has read each room since it was listed, as the server confirmed it (by session id): a count
    /// the server made before that read shows no badge (`SessionRowPresentation`).
    private var readThrough: [String: Int64] = [:]
    /// Rooms this phone caught up on (the server said nothing it counts was left, thread replies included), with the
    /// list's revision then: a count of replies alone, from a read of the list that started no later, was made before
    /// it and shows no badge. A read of the list started after counts again.
    private var caughtUpAt: [String: UInt64] = [:]
    /// The revision of the read of the whole list the rows were counted in (more rows loaded keep the rest as counted).
    private var snapshotRevision: UInt64 = 0

    init(
        repository: SessionRepository,
        onReauthenticationRequired: @escaping @MainActor () -> Void = {},
        onSelectionChanged: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.repository = repository
        self.onReauthenticationRequired = onReauthenticationRequired
        self.onSelectionChanged = onSelectionChanged
        self.state = SessionListPresentationState(
            sessions: [],
            includesArchived: false,
            hasMore: false,
            provenance: .unavailable
        )
    }

    deinit {
        operation?.cancel()
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !hasStarted else { return operation }
        hasStarted = true
        return refreshSessions()
    }

    func send(_ intent: PocketProductIntent) {
        switch intent {
        case .selectSession(let sessionId):
            selectSession(sessionId)
        case .refreshSessions:
            refreshSessions()
        case .loadMoreSessions:
            loadMoreSessions()
        default:
            break
        }
    }

    /// `quietly`: the open side panel's own re-read every few seconds. It never starts over a read still going (so a
    /// slow link still lands one), and a malformed answer keeps the room you are in and the rows you have.
    @discardableResult
    func refreshSessions(quietly: Bool = false) -> Task<Void, Never> {
        if quietly, let operation { return operation }
        return run(recounts: true, quietly: quietly) { repository in
            try await repository.refreshSessions()
        }
    }

    @discardableResult
    func loadMoreSessions() -> Task<Void, Never> {
        run { repository in
            try await repository.loadMoreSessions()
        }
    }

    private func selectSession(_ sessionId: String) {
        guard state.rows.contains(where: { UTF8ExactIdentity.matches($0.sessionId, sessionId) }) else { return }
        setSelectedSession(sessionId)
    }

    func clearSelection() {
        setSelectedSession(nil)
    }

    /// The server took your read of a room through `sequence`, and `caughtUp` when nothing it counts was left after
    /// it, thread replies included, so the badge follows your reading. The list draws again only when that clears a
    /// badge it shows, once a visit, never at every read.
    func noteRead(sessionId: String, through sequence: Int64, caughtUp: Bool = false) {
        let moved = sequence > (readThrough[sessionId] ?? 0)
        if moved { readThrough[sessionId] = sequence }
        if caughtUp { caughtUpAt[sessionId] = revision }
        guard moved || caughtUp,
              let row = state.rows.first(where: { UTF8ExactIdentity.matches($0.sessionId, sessionId) }),
              row.activity.unread > 0 else { return }
        // Unread messages clear once the read reaches the first of them; replies alone, once the read caught up.
        let clears = row.firstUnreadSequenceId.map { $0 <= sequence } ?? caughtUp
        guard clears else { return }
        state = render(snapshot: snapshot, provenance: provenance, isRefreshing: state.isRefreshing, failure: state.failure)
    }

    /// A protected sibling client (reasoning/write) observed an expired bearer. Clear rows and selection
    /// synchronously before the outer sign-in gate transitions, then fence/reset the actor-owned repository.
    @discardableResult
    func invalidateAuthentication() -> Task<Void, Never> {
        operation?.cancel()
        revision &+= 1
        snapshot = nil
        readThrough = [:]
        caughtUpAt = [:]
        provenance = .unavailable
        setSelectedSession(nil)
        state = render(
            snapshot: nil,
            provenance: .unavailable,
            isRefreshing: false,
            failure: .reauthenticationRequired
        )
        let repository = repository
        let task = Task { await repository.reset() }
        operation = task
        return task
    }

    private func run(
        recounts: Bool = false,
        quietly: Bool = false,
        _ request: @escaping @Sendable (SessionRepository) async throws -> SessionListSnapshot
    ) -> Task<Void, Never> {
        operation?.cancel()
        revision &+= 1
        let operationRevision = revision
        state = render(
            snapshot: snapshot,
            provenance: provenance,
            isRefreshing: true,
            failure: nil
        )

        let repository = repository
        let task = Task { @MainActor [weak self] in
            do {
                let next = try await request(repository)
                guard let self,
                      !Task.isCancelled,
                      self.revision == operationRevision else { return }
                self.snapshot = next
                if recounts { self.snapshotRevision = operationRevision }
                self.provenance = .network(lastUpdated: next.loadedAt)
                if let selectedSessionId = self.selectedSessionId,
                   !next.sessions.contains(where: {
                       UTF8ExactIdentity.matches($0.sessionId, selectedSessionId)
                   }) {
                    self.setSelectedSession(nil)
                }
                self.state = self.render(
                    snapshot: next,
                    provenance: self.provenance,
                    isRefreshing: false,
                    failure: nil
                )
                if self.revision == operationRevision {
                    self.operation = nil
                }
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.revision == operationRevision else { return }
                await self.apply(error, quietly: quietly)
                if self.revision == operationRevision {
                    self.operation = nil
                }
            }
        }
        operation = task
        return task
    }

    private func apply(_ error: Error, quietly: Bool = false) async {
        let transportError = error as? SessionTransportError

        switch transportError {
        case .notLoggedIn, .reauthenticationRequired:
            await clearProtectedState()
            state = render(
                snapshot: nil,
                provenance: .unavailable,
                isRefreshing: false,
                failure: .reauthenticationRequired
            )
            onReauthenticationRequired()

        case .accessDenied:
            await clearProtectedState()
            state = render(
                snapshot: nil,
                provenance: .unavailable,
                isRefreshing: false,
                failure: .accessDenied
            )

        case .network:
            let failure: SessionLoadFailure = snapshot == nil ? .offlineNoCache : .network
            if let snapshot {
                provenance = .cache(cachedAt: snapshot.loadedAt, authenticationExpired: false)
            } else {
                provenance = .unavailable
            }
            state = render(
                snapshot: snapshot,
                provenance: provenance,
                isRefreshing: false,
                failure: failure
            )

        case .invalidRequest, .invalidResponse, .invalidData:
            guard !quietly else {
                // The panel's own re-read: its malformed answer is never shown; the last good rows stay, as cached,
                // and so does the room you are in. A refresh you asked for still fails closed, below.
                if let snapshot { provenance = .cache(cachedAt: snapshot.loadedAt, authenticationExpired: false) }
                state = render(snapshot: snapshot, provenance: provenance, isRefreshing: false, failure: .service)
                return
            }
            setSelectedSession(nil)
            state = render(
                snapshot: snapshot,
                provenance: provenance,
                isRefreshing: false,
                failure: .invalidData
            )

        case .notConfigured, .rateLimited, .service, nil:
            if let snapshot {
                // Rows from the last successful response remain useful, but a failed refresh makes them a cached
                // snapshot. Never keep `.network` and advertise stale rows as "Live session data."
                provenance = .cache(cachedAt: snapshot.loadedAt, authenticationExpired: false)
            } else {
                provenance = .unavailable
            }
            state = render(
                snapshot: snapshot,
                provenance: provenance,
                isRefreshing: false,
                failure: .service
            )

        case .cancelled:
            state = render(
                snapshot: snapshot,
                provenance: provenance,
                isRefreshing: false,
                failure: nil
            )
        }
    }

    private func clearProtectedState() async {
        await repository.reset()
        snapshot = nil
        readThrough = [:]
        caughtUpAt = [:]
        provenance = .unavailable
        setSelectedSession(nil)
    }

    private func setSelectedSession(_ sessionId: String?) {
        guard !UTF8ExactIdentity.matches(selectedSessionId, sessionId) else { return }
        selectedSessionId = sessionId
        onSelectionChanged(sessionId)
    }

    private func render(
        snapshot: SessionListSnapshot?,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool,
        failure: SessionLoadFailure?
    ) -> SessionListPresentationState {
        SessionListPresentationState(
            sessions: snapshot?.sessions ?? [],
            resultCount: snapshot?.count ?? 0,
            includesArchived: snapshot?.includesArchived ?? false,
            hasMore: snapshot?.hasMore ?? false,
            provenance: provenance,
            isRefreshing: isRefreshing,
            failure: failure,
            readThrough: readThrough,
            caughtUp: Set(caughtUpAt.filter { $0.value >= snapshotRevision }.keys)
        )
    }
}
