import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle
import PocketUI
import PocketReasoning
import PocketSyncClient

/// App shell (Atlas). The end-to-end state machine + lane feature views plug in here as they land.
/// For Sunday watchability, every screen ships a #Preview wired to the canonical fixture so the Xcode
/// canvas renders live on `git pull` + open — no simulator run required to see progress.
@main
struct SentiPocketApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Device-local model ownership is app-lifetime and deliberately independent of authentication.
    @StateObject private var whisperModel = WhisperModelProvisioningCoordinator()
    /// Room links iOS hands the app (universal links), held until a signed-in root opens them.
    @StateObject private var incomingLinks = IncomingLinkInbox()
    #if DEBUG
    @StateObject private var model = PocketAppModel()
    #endif
    #if canImport(CallKit) && canImport(PushKit)
    /// App-lifetime DIALS wiring (onAnswered hookup part-b): owns the SentiCallManager (its PKPushRegistry delegate
    /// must live the whole app) + the DialCoordinator, and installs the push-receive/answer adapters + the governed
    /// DI seams (hydrate via the authed DialHydrationClient / runDial via LiveDialVoice+PhoneWriteAdapter+orchestrator).
    @StateObject private var dialHost = DialHost()
    #endif
    #if !DEBUG
    /// The login GATE (Atlas, 322268 — closes the gate≠live gap): makes SentiNativeAuth LIVE. Signed-out →
    /// PocketSignInView; signed-in → the authenticated three-tab app. Every authed client (sync/hydrate/reason/write) is
    /// unreachable until a REAL token is stored (warden gate #1). DEBUG stays on the fixture flow (no real auth).
    @StateObject private var signIn = SignInCoordinator(login: SentiPocketApp.makeLogin())
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
                .onAppear { whisperModel.start() }
                .onOpenURL { url in _ = incomingLinks.receive(url) }
            #if canImport(CallKit) && canImport(PushKit)
                // The host is app-lifetime, but it constructs PushKit/CallKit only with a valid trusted gateway config.
                .environmentObject(dialHost)
                .onAppear { wireRegistrarToLogin() }
                .onChange(of: releaseAuthenticationIsActive) { isActive in
                    if !isActive && shouldImmediatelyInvalidateDialHost {
                        dialHost.onAuthenticationInvalidated()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        dialHost.applicationBecameActive()
                    }
                }
            #endif
        }
    }

    #if canImport(CallKit) && canImport(PushKit)
    private var releaseAuthenticationIsActive: Bool {
        #if DEBUG
        false
        #else
        signIn.isAuthenticated
        #endif
    }

    private var shouldImmediatelyInvalidateDialHost: Bool {
        #if DEBUG
        true
        #else
        // User sign-out owns a durable old-bearer revoke. Its pending bit survives marker, DELETE, and Keychain
        // failures, so the generic false transition must not disarm that explicit retry path.
        !signIn.isSignOutPending
        #endif
    }

    /// Wire login → the device VoIP-register: on a fresh login (SignInCoordinator.onAuthenticated) register the cached
    /// token so a ring can be ADDRESSED to this device. With DialHost's onVoipToken adapter this covers both orderings
    /// (token-before-login and token-after-login). Release only — DEBUG runs the fixture flow with no real auth/register.
    @MainActor
    private func wireRegistrarToLogin() {
        #if !DEBUG
        let host = dialHost
        signIn.onAuthenticated = { host.onLoginCompleted() }
        signIn.onAuthenticationRevoked = { host.onAuthenticationInvalidated() }
        signIn.onSignOutStarted = {
            try host.beginSignOut()
        }
        signIn.onWillSignOut = {
            try await host.prepareForSignOut()
        }
        host.installAuthenticationExpiryHandler { [weak signIn] in
            signIn?.invalidateAuthentication()
        }
        if signIn.isAuthenticated {
            host.onLoginCompleted()
        }
        #endif
    }
    #endif

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if RoomPreview.isRequested {
            RoomPreview.rootView
        } else {
            RootAppView(model: model, whisperModelCoordinator: whisperModel)
        }
        #else
        // WARDEN gate #1 (322268): the authed surfaces are unreachable until a REAL token is stored.
        if signIn.isAuthenticated {
            #if canImport(CallKit) && canImport(PushKit)
            AuthenticatedRootView(
                authenticationEpoch: signIn.authenticationEpoch,
                whisperModelCoordinator: whisperModel,
                incomingLinks: incomingLinks,
                onSignOut: { signIn.send(.signOut) },
                onReauthenticationRequired: { expectedEpoch in
                    guard signIn.isCurrentAuthentication(expectedEpoch) else { return }
                    signIn.invalidateAuthentication(expectedEpoch: expectedEpoch)
                },
                onSessionSelectionChanged: { expectedEpoch, sessionId in
                    guard signIn.isCurrentAuthentication(expectedEpoch) else { return }
                    dialHost.selectSession(sessionId)
                }
            )
            .id(signIn.authenticationEpoch)
            #else
            AuthenticatedRootView(
                authenticationEpoch: signIn.authenticationEpoch,
                whisperModelCoordinator: whisperModel,
                incomingLinks: incomingLinks,
                onSignOut: { signIn.send(.signOut) },
                onReauthenticationRequired: { expectedEpoch in
                    signIn.invalidateAuthentication(expectedEpoch: expectedEpoch)
                }
            )
            .id(signIn.authenticationEpoch)
            #endif
        } else {
            PocketSignInView(phase: signIn.phase, send: signIn.send)
        }
        #endif
    }

    #if !DEBUG
    /// Build the REAL device-flow login closure (gate #2: never fake a token). SENTI_API_URL may explicitly override
    /// the gateway, but there is no baked public-tunnel fallback: missing/invalid configuration fails before auth.
    private static func makeLogin() -> () async throws -> Void {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
        return {
            guard let base = GatewayEndpoint.resolve(
                infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            ) else {
                throw GatewayEndpointError.notConfigured
            }
            try await SentiNativeAuth(apiBaseURL: base, appVersion: version).login()
        }
    }
    #endif
}

/// Release composition of the authenticated repository-backed Sessions surface and the selected-session Pocket flow.
private struct AuthenticatedRootView: View {
    @StateObject private var sessions: SessionListCoordinator
    @StateObject private var details: SelectedSessionDetailCoordinator
    @StateObject private var checkpointPocket: CheckpointPocketCoordinator
    @StateObject private var checkpointNarrationRevocation: VerifiedCheckpointNarrationRevocationRelay
    @StateObject private var revocationRelay: AuthenticatedSessionRevocationRelay
    @StateObject private var notifications: NotificationsCoordinator
    @State private var presentsNotifications = false
    @Environment(\.scenePhase) private var rootScenePhase
    @ObservedObject private var whisperModelCoordinator: WhisperModelProvisioningCoordinator
    @ObservedObject private var incomingLinks: IncomingLinkInbox
    @State private var selectedTab: PocketTab = .sessions
    @State private var presentsSettings = false
    @State private var roomPath: [RoomRoute] = []
    private let roomTransport: any RoomTransport
    private let ticketsTransport: any RoomTicketsTransport
    private let admissionsTransport: any RoomAdmissionsTransport
    private let admissionDecider: any AdmissionDeciding
    private let roomSender: any RoomMessageSending
    private let roomActionSender: any RoomActionSending
    private let accountIdentity: any AccountIdentityProviding
    private let roomReceipts: any RoomReceiptsClient
    private let roomSearch: any RoomSearching
    private let authenticationRevision: UInt64
    private let onSignOut: @MainActor () -> Void

    init(
        authenticationEpoch: UInt64,
        whisperModelCoordinator: WhisperModelProvisioningCoordinator,
        incomingLinks: IncomingLinkInbox,
        onSignOut: @escaping @MainActor () -> Void,
        onReauthenticationRequired: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSessionSelectionChanged: @escaping @MainActor (UInt64, String?) -> Void = { _, _ in }
    ) {
        let guardedReauthentication: @MainActor @Sendable () -> Void = {
            onReauthenticationRequired(authenticationEpoch)
        }
        let apiURL = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"])
        let transport = HTTPSessionTransport(
            apiBaseURL: apiURL,
            urlSession: SentiHTTPTransportPolicy.protectedReadSession,
            streamingSession: SentiHTTPTransportPolicy.roomStreamSession,
            tokenProvider: { SessionTokenStore.load() }
        )
        let checkpointTransport = HTTPCheckpointTransport(
            gatewayBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"]),
            urlSession: SentiHTTPTransportPolicy.checkpointSession,
            tokenProvider: { SessionTokenStore.load() }
        )
        let revocationRelay = AuthenticatedSessionRevocationRelay(
            onReauthenticationRequired: guardedReauthentication
        )
        let checkpointNarrationRevocation = VerifiedCheckpointNarrationRevocationRelay()
        let checkpointPocket = CheckpointPocketCoordinator(
            transport: checkpointTransport,
            onReauthenticationRequired: {
                revocationRelay.invalidateAuthentication()
            },
            onSelectionRevoked: { sessionId in
                revocationRelay.revokeSelection(expectedSessionId: sessionId)
            },
            onProtectedContentRevoked: { [weak checkpointNarrationRevocation] in
                _ = checkpointNarrationRevocation?.revoke()
            }
        )
        let details = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: {
                revocationRelay.invalidateAuthentication()
            },
            onSelectionRevoked: { sessionId in
                revocationRelay.revokeSelection(expectedSessionId: sessionId)
            },
            onOpenCheckpoint: { target in
                checkpointPocket.open(target)
            }
        )
        let sessions = SessionListCoordinator(
            repository: SessionRepository(transport: transport),
            onReauthenticationRequired: {
                revocationRelay.invalidateAuthentication()
            },
            onSelectionChanged: { sessionId in
                checkpointPocket.setSelectedSession(
                    sessionId,
                    authenticationRevision: authenticationEpoch
                )
                details.setSelectedSession(
                    sessionId,
                    authenticationRevision: authenticationEpoch
                )
                onSessionSelectionChanged(authenticationEpoch, sessionId)
            }
        )
        revocationRelay.sessions = sessions
        revocationRelay.details = details
        revocationRelay.checkpointPocket = checkpointPocket

        _sessions = StateObject(wrappedValue: sessions)
        _details = StateObject(wrappedValue: details)
        _checkpointPocket = StateObject(wrappedValue: checkpointPocket)
        _checkpointNarrationRevocation = StateObject(wrappedValue: checkpointNarrationRevocation)
        _revocationRelay = StateObject(wrappedValue: revocationRelay)
        _notifications = StateObject(wrappedValue: NotificationsCoordinator(
            transport: transport,
            marker: HTTPNotificationReadMarker(apiBaseURL: apiURL),
            roomTitle: { sessionId in
                sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, sessionId) }?.title
            },
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        _whisperModelCoordinator = ObservedObject(wrappedValue: whisperModelCoordinator)
        _incomingLinks = ObservedObject(wrappedValue: incomingLinks)
        self.roomTransport = transport
        self.ticketsTransport = transport
        self.admissionsTransport = transport
        self.admissionDecider = HTTPAdmissionDecider(apiBaseURL: apiURL)
        // Typed room messages go straight to the Senti API as you, like the web; the gateway's confirm-and-receipt
        // flow stays for AI-drafted writes (the Pocket tab and voice replies).
        self.roomSender = HTTPRoomMessageSender(apiBaseURL: apiURL)
        self.roomActionSender = HTTPRoomActionSender(apiBaseURL: apiURL)
        self.accountIdentity = HTTPAccountIdentity(apiBaseURL: apiURL)
        // Read receipts and presence, as yourself, like the web.
        self.roomReceipts = HTTPRoomReceipts(apiBaseURL: apiURL)
        self.roomSearch = transport
        self.authenticationRevision = authenticationEpoch
        self.onSignOut = onSignOut
    }

    var body: some View {
        AppShell(
            selection: $selectedTab,
            sessions: {
                NavigationStack(path: $roomPath) {
                    SessionListView(state: sessions.state) { intent in
                        sessions.send(intent)
                        if case .selectSession(let sessionId) = intent,
                           UTF8ExactIdentity.matches(sessions.selectedSessionId, sessionId) {
                            // Tapping a room opens its live chat; the Pocket and Activity tabs follow the selection.
                            let row = sessions.state.rows.first {
                                UTF8ExactIdentity.matches($0.sessionId, sessionId)
                            }
                            roomPath = [RoomRoute(
                                sessionId: sessionId,
                                title: row?.title ?? "Room",
                                membershipRole: row?.membershipRole ?? ""
                            )]
                        }
                    }
                    .navigationDestination(for: RoomRoute.self) { route in
                        RoomChatScreen(
                            route: route,
                            transport: roomTransport,
                            sender: roomSender,
                            actionSender: roomActionSender,
                            identity: accountIdentity,
                            ticketsTransport: ticketsTransport,
                            admissionsTransport: admissionsTransport,
                            admissionDecider: admissionDecider,
                            openRoom: { link in open(link) },
                            openChildRoom: { child in roomPath.append(child) },
                            receipts: roomReceipts,
                            search: roomSearch,
                            onReauthenticationRequired: invalidateProtectedAuthentication
                        )
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                presentsNotifications = true
                                Task { await notifications.refresh() }
                            } label: {
                                Image(systemName: notifications.unreadCount > 0 ? "bell.badge" : "bell")
                                    .overlay(alignment: .topTrailing) {
                                        if notifications.unreadCount > 0 {
                                            Text(notifications.unreadCount > 99 ? "99+" : "\(notifications.unreadCount)")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .background(Capsule().fill(Color.red))
                                                .offset(x: 10, y: -8)
                                        }
                                    }
                            }
                            .accessibilityLabel(notifications.unreadCount > 0
                                ? "Notifications, \(notifications.unreadCount) unread"
                                : "Notifications")
                            .accessibilityIdentifier("sessions.notifications")
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                presentsSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                                    .labelStyle(.iconOnly)
                            }
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("sessions.settings")
                        }
                    }
                }
            },
            pocket: {
                SelectedSessionPocketView(
                    sessions: sessions,
                    checkpointPocket: checkpointPocket,
                    checkpointNarrationRevocation: checkpointNarrationRevocation,
                    onCheckpointDone: {
                        checkpointPocket.clear()
                        selectedTab = .activity
                    },
                    onReauthenticationRequired: invalidateProtectedAuthentication
                )
            },
            activity: {
                SelectedSessionActivityBoundary(
                    sessions: sessions,
                    details: details
                )
            }
        )
        .onChange(of: checkpointPocket.isActive) { isActive in
            if isActive {
                selectedTab = .pocket
            }
        }
        .sheet(isPresented: $presentsNotifications) {
            NotificationsView(state: notifications.state) { intent in
                switch intent {
                case .open(let id):
                    guard let link = notifications.open(id) else { return }
                    presentsNotifications = false
                    open(link)
                case .markRead(let id):
                    notifications.markRead(id)
                case .markAllRead:
                    notifications.markAllRead()
                case .refresh:
                    Task { await notifications.refresh() }
                case .close:
                    presentsNotifications = false
                }
            }
        }
        .onChange(of: rootScenePhase) { phase in
            if phase == .active { notifications.startPolling() } else { notifications.stopPolling() }
        }
        .onChange(of: incomingLinks.revision) { _ in openPendingLinkIfReady() }
        .onChange(of: roomListSettled) { _ in openPendingLinkIfReady() }
        .sheet(isPresented: $presentsSettings) {
            WhisperModelSettingsView(
                coordinator: whisperModelCoordinator,
                onSignOut: {
                    presentsSettings = false
                    onSignOut()
                }
            )
        }
        .onAppear {
            checkpointPocket.setSelectedSession(
                sessions.selectedSessionId,
                authenticationRevision: authenticationRevision
            )
            details.setSelectedSession(
                sessions.selectedSessionId,
                authenticationRevision: authenticationRevision
            )
            sessions.start()
            notifications.startPolling()
            openPendingLinkIfReady()
        }
        .onDisappear {
            notifications.stopPolling()
            sessions.clearSelection()
            details.clearSelection()
            checkpointPocket.clearSelection()
        }
    }

    @MainActor
    private func invalidateProtectedAuthentication() {
        revocationRelay.invalidateAuthentication()
    }

    /// Opens a Senti link in the app: the room, at the message it names, with its ticket or agent requests on top.
    @MainActor
    private func open(_ link: SentiLink) {
        let row = sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, link.sessionId) }
        presentsNotifications = false
        presentsSettings = false
        selectedTab = .sessions
        roomPath = [RoomRoute(
            sessionId: link.sessionId,
            title: row?.title ?? "Room",
            membershipRole: row?.membershipRole ?? "",
            focusSequenceId: link.messageSequence,
            focusTicketId: link.ticketId,
            opensAdmissions: link.admissionId != nil
        )]
    }

    /// The room list has loaded or failed, so a room opened from a link knows its title and your role in it.
    private var roomListSettled: Bool {
        sessions.state.provenance != .unavailable || sessions.state.failure != nil
    }

    /// Opens the link iOS handed the app (a universal link) once the room list has settled. Each link opens once.
    @MainActor
    private func openPendingLinkIfReady() {
        guard roomListSettled, let link = incomingLinks.take() else { return }
        open(link)
    }
}

/// Breaks the construction cycle between the session allowlist and its selected-session detail coordinator while
/// keeping revocation synchronous on the main actor. References are weak; the authenticated root owns both objects.
@MainActor
private final class AuthenticatedSessionRevocationRelay: ObservableObject {
    weak var sessions: SessionListCoordinator?
    weak var details: SelectedSessionDetailCoordinator?
    weak var checkpointPocket: CheckpointPocketCoordinator?

    private let onReauthenticationRequired: @MainActor @Sendable () -> Void

    init(onReauthenticationRequired: @escaping @MainActor @Sendable () -> Void) {
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func invalidateAuthentication() {
        checkpointPocket?.invalidateAuthentication()
        sessions?.invalidateAuthentication()
        details?.invalidateAuthentication()
        // Session-list invalidation emits its selection callback with the old root epoch. Clear again so that
        // callback cannot leave even an identity-only authorization epoch behind after protected content closes.
        checkpointPocket?.invalidateAuthentication()
        onReauthenticationRequired()
    }

    func revokeSelection(expectedSessionId: String) {
        guard let selectedSessionId = sessions?.selectedSessionId,
              selectedSessionId.utf8.elementsEqual(expectedSessionId.utf8) else { return }
        sessions?.clearSelection()
    }
}

private struct SelectedSessionPocketView: View {
    @ObservedObject var sessions: SessionListCoordinator
    @ObservedObject var checkpointPocket: CheckpointPocketCoordinator
    @ObservedObject var checkpointNarrationRevocation: VerifiedCheckpointNarrationRevocationRelay
    let onCheckpointDone: @MainActor () -> Void
    let onReauthenticationRequired: @MainActor @Sendable () -> Void

    @ViewBuilder var body: some View {
        switch checkpointPocket.phase {
        case .loading:
            checkpointStatus(
                title: "Verifying checkpoint",
                systemImage: "checkmark.shield",
                message: "Fetching the exact selected checkpoint and verifying its signature before showing any content.",
                actionTitle: nil,
                action: nil
            )

        case .failed(_, let failure):
            checkpointStatus(
                title: failure.title,
                systemImage: "exclamationmark.shield.fill",
                message: failure.detail,
                actionTitle: failure.allowsRetry ? "Try again" : nil,
                action: failure.allowsRetry ? {
                    _ = checkpointPocket.retry()
                } : nil
            )

        case .ready(_, let verifiedBundle):
            NavigationStack {
                VerifiedCheckpointNarrationView(
                    verifiedBundle: verifiedBundle,
                    revocationRelay: checkpointNarrationRevocation,
                    onDone: onCheckpointDone
                )
                .id(VerifiedCheckpointNarrationIdentity(verifiedBundle: verifiedBundle))
            }

        case .idle:
            idlePocket
        }
    }

    @ViewBuilder
    private var idlePocket: some View {
        if let sessionId = sessions.selectedSessionId {
            PhoneRootView(
                sessionId: sessionId,
                onReauthenticationRequired: onReauthenticationRequired,
                isWriteAuthorized: {
                    UTF8ExactIdentity.matches(sessions.selectedSessionId, sessionId)
                }
            )
                .id(UTF8ExactIdentity(sessionId))
        } else {
            NavigationStack {
                StatusView(
                    title: "Choose a session",
                    systemImage: "rectangle.stack",
                    message: "Select an authorized session before asking Senti or posting as yourself."
                )
                .navigationTitle("Pocket")
            }
        }
    }

    private func checkpointStatus(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        NavigationStack {
            StatusView(
                title: title,
                systemImage: systemImage,
                message: message,
                actionTitle: actionTitle,
                action: action
            )
            .navigationTitle("Verified checkpoint")
            .toolbar { checkpointDoneToolbar }
        }
    }

    @ToolbarContentBuilder
    private var checkpointDoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done", action: onCheckpointDone)
                .accessibilityIdentifier("pocket.verified-checkpoint.done")
        }
    }
}

private struct SelectedSessionActivityBoundary: View {
    @ObservedObject var sessions: SessionListCoordinator
    @ObservedObject var details: SelectedSessionDetailCoordinator

    @ViewBuilder
    var body: some View {
        NavigationStack {
            Group {
                if sessions.selectedSessionId == nil {
                    StatusView(
                        title: "Choose a session",
                        systemImage: "waveform.path.ecg",
                        message: "Select an authorized session before loading its activity or room checkpoints."
                    )
                    .navigationTitle("Activity")
                } else {
                    activityContent
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                NavigationLink {
                                    checkpointContent
                                } label: {
                                    Label("Room checkpoints", systemImage: "tray.full")
                                        .labelStyle(.iconOnly)
                                }
                                .accessibilityLabel("Room checkpoints")
                            }
                        }
                }
            }
            .navigationDestination(isPresented: destinationIsPresented) {
                if let destination = details.destination {
                    destinationView(destination)
                }
            }
        }
        .id(sessions.selectedSessionId.map(UTF8ExactIdentity.init))
    }

    /// Item-based navigation destinations require iOS 17; Pocket's floor remains iOS 16.
    private var destinationIsPresented: Binding<Bool> {
        Binding(
            get: { details.destination != nil },
            set: { isPresented in
                if !isPresented {
                    details.clearDestination()
                }
            }
        )
    }

    @ViewBuilder
    private func destinationView(_ destination: SessionDetailDestination) -> some View {
        switch destination {
        case .event(let sequenceId, let eventId):
            if let event = details.event(sequenceId: sequenceId, eventId: eventId) {
                SessionEventDetailView(
                    event: event,
                    provenance: details.activityState?.provenance ?? .unavailable
                )
            }
        case .action(let actionId):
            if let action = details.action(actionId: actionId) {
                SessionActionDetailView(
                    action: action,
                    provenance: details.activityState?.provenance ?? .unavailable
                )
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if let state = details.activityState {
            SessionActivityView(state: state) { intent in
                details.send(intent)
            }
        } else {
            loadStatus(
                details.activityLoadState,
                emptyTitle: "No activity loaded",
                systemImage: "waveform.path.ecg",
                retry: { details.refreshActivity() }
            )
            .navigationTitle("Activity")
        }
    }

    @ViewBuilder
    private var checkpointContent: some View {
        if let state = details.checkpointState {
            SessionCheckpointListView(state: state) { intent in
                details.send(intent)
            }
        } else {
            loadStatus(
                details.checkpointLoadState,
                emptyTitle: "No room checkpoints loaded",
                systemImage: "tray.full",
                retry: { details.refreshCheckpoints() }
            )
            .navigationTitle("Room checkpoints")
        }
    }

    private func loadStatus(
        _ loadState: SelectedSessionDetailLoadState,
        emptyTitle: String,
        systemImage: String,
        retry: @escaping () -> Void
    ) -> some View {
        let title: String
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        switch loadState {
        case .loading:
            title = "Loading"
            message = "Fetching the selected session through your current Senti authorization."
            actionTitle = nil
            action = nil
        case .failed(let failure):
            title = failure.title
            message = failure.detail
            actionTitle = "Try again"
            action = retry
        case .idle, .loaded:
            title = emptyTitle
            message = "Refresh to load the currently selected authorized session."
            actionTitle = "Refresh"
            action = retry
        }

        return StatusView(
            title: title,
            systemImage: loadState.isLoading ? "arrow.triangle.2.circlepath" : systemImage,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }
}

/// B2 selected-session composition: the real reasoning coordinator + phone-write flow. No Release fixture identity or
/// cached sample is used; the only session id comes from SessionListCoordinator's currently authorized row allowlist.
struct PhoneRootView: View {
    @StateObject private var reasoning: RealReasoningCoordinator
    @StateObject private var write: PhoneWriteViewModel

    init(
        sessionId: String,
        onReauthenticationRequired: @escaping @MainActor @Sendable () -> Void = {},
        isWriteAuthorized: @escaping @MainActor () -> Bool = { true }
    ) {
        let unavailable = UnavailableSessionReasoningProvider()
        let gatewayURL = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"])
        let authenticationExpiry = AuthenticationExpiryRelay()
        authenticationExpiry.install(onReauthenticationRequired)
        // ONLINE → gateway reasoning admitted against an independently fetched, signature-verified exact checkpoint.
        // The actor keeps auth/session/checkpoint context and refuses foreign citations before the UI can label output
        // live/grounded. Until the backend + signing key/Gemma are live, failures surface honestly. A build with no
        // trusted gateway has no selected-session cache and never borrows DEBUG fixture content.
        let tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }
        let online = gatewayURL.map { gatewayURL in
            VerifiedGatewayReasoningProvider(
                expectedSessionId: sessionId,
                gateway: UnboundGatewayReasoningProvider(client: GatewayReasoningHTTPClient(
                    apiBaseURL: gatewayURL,
                    tokenProvider: tokenProvider,
                    onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
                )),
                checkpointTransport: HTTPCheckpointTransport(
                    gatewayBaseURL: gatewayURL,
                    urlSession: SentiHTTPTransportPolicy.checkpointSession,
                    tokenProvider: tokenProvider
                ),
                tokenProvider: tokenProvider,
                onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
            )
        }
        _reasoning = StateObject(wrappedValue: RealReasoningCoordinator(
            sessionId: sessionId, checkpointId: nil,
            selectProvider: { isOnline in
                if isOnline, let online { return online as ReasoningProvider }
                return unavailable as ReasoningProvider
            }))
        _write = StateObject(wrappedValue: PhoneWriteViewModel(
            sessionId: sessionId,
            client: PocketWriteClient(apiBaseURL: gatewayURL),
            onReauthenticationRequired: { expectedToken in
                if expectedToken == nil || SessionTokenStore.load() == expectedToken {
                    onReauthenticationRequired()
                }
            },
            isWriteAuthorized: isWriteAuthorized))
    }

    var body: some View { PocketPhoneView(reasoning: reasoning, write: write) }
}

private struct UnavailableSessionReasoningProvider: ReasoningProvider {
    let provenance: ReasoningProvenance = .cachedSample

    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        throw UnavailableSessionReasoningError.noVerifiedCache
    }

    func answer(
        _ question: String,
        sessionId: String,
        checkpointId: String?
    ) async throws -> ReasonedAnswer {
        throw UnavailableSessionReasoningError.noVerifiedCache
    }
}

private enum UnavailableSessionReasoningError: LocalizedError {
    case noVerifiedCache

    var errorDescription: String? {
        "No verified briefing is cached for this session. Connect to Senti to reason over its latest checkpoint."
    }
}

#if DEBUG
/// DEBUG uses the canonical verified fixture and the in-module demo seam. Release never names that seam.
private struct RootAppView: View {
    @ObservedObject var model: PocketAppModel
    @ObservedObject var whisperModelCoordinator: WhisperModelProvisioningCoordinator
    @State private var presentsSettings = false

    var body: some View {
        Group {
            if model.verifiedBundle != nil {
                PocketRootView(state: model.state, send: model.send)
            } else {
                RootView()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                presentsSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("debug.settings")
        }
        .sheet(isPresented: $presentsSettings) {
            WhisperModelSettingsView(coordinator: whisperModelCoordinator)
        }
    }
}
#endif

#if DEBUG
/// Placeholder root until Pulse's PocketUI lands. FAIL-CLOSED: it decodes the cached checkpoint and then
/// requires `VerifiedBundle.verify` (trusted signingKeyId + semantic validity + ed25519 under the pinned key)
/// BEFORE showing anything. An unsigned or untrusted-key bundle renders the refusal state — Senti Pocket never
/// displays, narrates, or answers from an unverified bundle. (On forge-day, once the fixture is signed under a
/// trusted key, this same screen renders the briefing.)
struct RootView: View {
    private let decoded: PocketBundle? = FixtureLoader.canonicalBundle()
    private let verified: VerifiedBundle?

    init() { verified = FixtureLoader.canonicalBundle().flatMap { VerifiedBundle.verify($0) } }

    var body: some View {
        NavigationStack {
            if let vb = verified {
                briefing(vb.bundle)
            } else if decoded == nil {
                StatusView(title: "No bundle", systemImage: "bolt.slash",
                    message: "canonical_checkpoint.json failed to load — check Resources bundling.")
            } else {
                StatusView(title: "Bundle not verified", systemImage: "lock.trianglebadge.exclamationmark",
                    message: "The cached checkpoint is unsigned or signed by an untrusted key. Senti Pocket refuses to display, narrate, or answer from an unverified bundle — fail-closed. Sign the fixture under a trusted key (pocket-demo-app-fixture) to enable the demo.")
                    .navigationTitle("Fail-closed")
            }
        }
    }

    @ViewBuilder private func briefing(_ b: PocketBundle) -> some View {
        List {
            Section("Senti is calling") {
                Text(b.summary.headline).font(.headline)
                Text("checkpoint \(b.checkpointId) · seq \(b.sequenceStart)–\(b.sequenceEnd)")
                    .font(.caption).foregroundStyle(.secondary)
                Label("verified · \(b.signingKeyId)", systemImage: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
            }
            ForEach(b.summary.perAgent, id: \.sentiOpaqueIdentity) { agent in
                Section(agent.agentId) {
                    ForEach(agent.claims, id: \.sentiOpaqueIdentity) { claim in
                        HStack(alignment: .top) {
                            Text(badge(claim.kind)).font(.caption2)
                            Text(claim.text).font(.subheadline)
                        }
                    }
                }
            }
            Section("Contracts") {
                Text("PocketContracts v\(PocketContracts.version) · \(b.evidence.count) evidence refs")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Senti Pocket")
    }

    private func badge(_ kind: ClaimKind) -> String {
        switch kind {
        case .fact: return "[FACT]"
        case .inference: return "[INFER]"
        case .recommendation: return "[REC]"
        }
    }
}
#endif

private extension AgentSummary {
    var sentiOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(agentId) }
}

private extension Claim {
    var sentiOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(id) }
}

/// iOS 16-compatible empty/error state (ContentUnavailableView is iOS 17+, but the app target is pinned to iOS 16
/// per the baseline — forge #238084 caught the mismatch on the real Mac). Pure VStack/Image/Text = iOS 16-safe.
private struct StatusView: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Root — verify-gated canonical fixture") {
    RootView()
}
#endif
