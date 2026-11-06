import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle
import PocketUI
import PocketReasoning
import PocketSyncClient
import PocketVoice

/// App shell (Atlas). The end-to-end state machine + lane feature views plug in here as they land.
/// For Sunday watchability, every screen ships a #Preview wired to the canonical fixture so the Xcode
/// canvas renders live on `git pull` + open — no simulator run required to see progress.
@main
struct SentiPocketApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Apple push: the device token and the notification center's delegate (`PushRegistrar`).
    @UIApplicationDelegateAdaptor(PocketAppDelegate.self) private var appDelegate
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
    @StateObject private var signIn = SignInCoordinator(login: SentiPocketApp.makeLogin(),
                                                        appleLogin: SentiPocketApp.makeAppleLogin())
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
                .onAppear { whisperModel.start() }
                .onOpenURL { url in
                    LaunchUrgency.shared.raise()
                    _ = incomingLinks.receive(url)
                }
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
        Self.wire(signIn, to: dialHost, endPushes: { PushRegistrar.shared.signOut() })
        #endif
    }

    /// The release wiring above, separate so a test runs it with a test host.
    @MainActor
    static func wire(_ signIn: SignInCoordinator, to host: DialHost, endPushes: @escaping @MainActor () -> Void) {
        signIn.onAuthenticated = { host.onLoginCompleted() }
        signIn.onAuthenticationRevoked = {
            host.onAuthenticationInvalidated()
            // A refused credential ends this account's notifications on this phone too, as signing out does: someone
            // else may sign in next (warden, #298 review). So does the recent-emoji row.
            endPushes()
            RoomEmojiPicker.forgetRecent()
        }
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
    }
    #endif

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if RoomCalendarPreview.isRequested {
            RoomCalendarPreview.rootView
        } else if RootPreview.isRequested {
            RootPreview.rootView(whisperModel: whisperModel, incomingLinks: incomingLinks)
        } else if AgentChatPreview.isRequested {
            AgentChatPreview.rootView
        } else if RoomPreview.isRequested {
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
                onSignOut: {
                    // This phone stops getting the person's notifications before the sign-in goes.
                    PushRegistrar.shared.signOut()
                    // And nobody else signing in here sees what they were writing, sending or shown.
                    RoomComposerDraft.forgetAllSaved()
                    RoomMediaUploadCoordinator.forgetAll()
                    RoomEmojiPicker.forgetRecent()
                    signIn.send(.signOut)
                },
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
                onSignOut: {
                    // This phone stops getting the person's notifications before the sign-in goes.
                    PushRegistrar.shared.signOut()
                    // And nobody else signing in here sees what they were writing, sending or shown.
                    RoomComposerDraft.forgetAllSaved()
                    RoomMediaUploadCoordinator.forgetAll()
                    RoomEmojiPicker.forgetRecent()
                    signIn.send(.signOut)
                },
                onReauthenticationRequired: { expectedEpoch in
                    signIn.invalidateAuthentication(expectedEpoch: expectedEpoch)
                }
            )
            .id(signIn.authenticationEpoch)
            #endif
        } else {
            PocketSignInView(phase: signIn.phase, offersApple: signIn.offersApple, send: signIn.send)
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

    /// Sign in with Apple through the same API origin, or nil (not offered) unless the build turns it on.
    private static func makeAppleLogin() -> (() async throws -> Void)? {
        guard AppleSignInSetting.isEnabled(in: Bundle.main.infoDictionary) else { return nil }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
        return {
            guard let base = GatewayEndpoint.resolve(
                infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            ) else {
                throw GatewayEndpointError.notConfigured
            }
            try await SentiNativeAuth(apiBaseURL: base, appVersion: version).loginWithApple()
        }
    }
    #endif
}

/// What the signed-in app reads and writes through: the Senti API as you in the app; scripted rooms and people in the
/// DEBUG root preview (`RootPreview`), which hosts this same root, its side panel and its rooms.
struct RootServices {
    var sessions: any SessionTransport
    var room: any RoomTransport
    var tickets: any RoomTicketsTransport
    var admissions: any RoomAdmissionsTransport
    var search: any RoomSearching
    var notifications: any NotificationsTransport
    var notificationMarker: (any NotificationReadMarking)?
    var callLog: any CallLogTransport
    var waiting: any WaitingTransport
    var checkpoints: any CheckpointTransport
    var directMessages: any DirectMessaging
    var roomFolders: any RoomFoldersServing
    var admissionDecider: any AdmissionDeciding
    var sender: any RoomMessageSending
    var actionSender: any RoomActionSending
    var ticketWriter: any RoomTicketWriting
    var ticketLeases: any TicketLeaseStoring
    var ticketExtras: any RoomTicketExtrasReading
    var identity: any AccountIdentityProviding
    var receipts: any RoomReceiptsClient
    var readMarker: any RoomReadMarking
    /// Apple push for this phone: the app registers it; a preview never does.
    var registersPush = true
    /// The calendar and its Apple Calendar link, shown once the server answers their routes; nil (a preview) hides it.
    var calendar: (any RoomCalendarServing & CalendarFeedServing)?

    /// The Senti API as you.
    static func live() -> RootServices {
        let apiURL = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"])
        let transport = HTTPSessionTransport(
            apiBaseURL: apiURL,
            urlSession: SentiHTTPTransportPolicy.protectedReadSession,
            streamingSession: SentiHTTPTransportPolicy.roomStreamSession,
            tokenProvider: { SessionTokenStore.load() }
        )
        // Typed room messages go straight to the Senti API as you, like the web; the gateway's confirm-and-receipt
        // flow stays for AI-drafted writes (the Pocket tab and voice replies).
        let sender = HTTPRoomMessageSender(apiBaseURL: apiURL)
        return RootServices(
            sessions: transport,
            room: transport,
            tickets: transport,
            admissions: transport,
            search: transport,
            notifications: transport,
            notificationMarker: HTTPNotificationReadMarker(apiBaseURL: apiURL),
            callLog: transport,
            waiting: transport,
            checkpoints: HTTPCheckpointTransport(
                gatewayBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"]),
                urlSession: SentiHTTPTransportPolicy.checkpointSession,
                tokenProvider: { SessionTokenStore.load() }
            ),
            // Yours alone, as you: no cache, no cookies, the bearer per request.
            directMessages: HTTPDirectMessagesClient(apiBaseURL: apiURL,
                                                     urlSession: SentiHTTPTransportPolicy.protectedReadSession,
                                                     tokenProvider: { SessionTokenStore.load() }),
            roomFolders: HTTPRoomFoldersClient(apiBaseURL: apiURL, urlSession: SentiHTTPTransportPolicy.protectedReadSession,
                                               tokenProvider: { SessionTokenStore.load() }),
            admissionDecider: HTTPAdmissionDecider(apiBaseURL: apiURL),
            sender: sender,
            actionSender: HTTPRoomActionSender(apiBaseURL: apiURL),
            // Ticket writes as you, like the web; the lease a claim returns is kept in the Keychain to release it.
            ticketWriter: HTTPRoomTicketWriter(apiBaseURL: apiURL),
            ticketLeases: KeychainTicketLeaseStore(),
            ticketExtras: HTTPRoomTicketExtras(apiBaseURL: apiURL),
            identity: HTTPAccountIdentity(apiBaseURL: apiURL),
            // Read receipts and presence, as yourself, like the web.
            receipts: HTTPRoomReceipts(apiBaseURL: apiURL),
            readMarker: HTTPRoomReadMarker(apiBaseURL: apiURL),
            calendar: HTTPRoomCalendarClient(apiBaseURL: apiURL, urlSession: CalendarHTTP.session,
                                             tokenProvider: { SessionTokenStore.load() })
        )
    }
}

/// A room screen on screen, made once for what it is opened with: the room, its saved summary and whether direct messages
/// are on. The root draws again for every change of the room list, the bell, Waiting on you, folders and its sheets;
/// each of those made a new room screen (with a Keychain read) and drew the room's whole list again (the freezes of
/// build 2026110308).
///
/// A slot is held by reference and keeps the screen it made. A draw of the root puts the same view there (the slot and
/// its revision, nothing that needs an `==`), and a draw of that view gives the same screen, until what the room is
/// opened with changes. A host compared by its `==` (#332) was made again at draws of the root without SwiftUI asking
/// its `==`: on the build Mac (iOS 26.5) at a draw just after a root opened, and at every draw of the root in some CI
/// runs (iOS 26.4), the side panel's open and close included. Carter's phone froze twice on 11-06 right after the side
/// panel opened or a room was picked from it, its main thread inside SwiftUI with no frame of the app above `main`.
@MainActor
final class RoomScreenSlot {
    private struct Opening: Equatable {
        let route: RoomRoute
        let savedSummary: String?
        let directMessagesOn: Bool
    }

    private var opening: Opening?
    private var made: RoomChatScreen?
    private var make: (@MainActor (RoomRoute, String?) -> RoomChatScreen)?
    /// Moves only when what the room is opened with changes.
    private(set) var revision = 0

    /// What the room is opened with at this draw of the root, and how to make its screen: a new revision, and a new
    /// screen when it is next asked for, only when the opening changed.
    func open(_ route: RoomRoute, savedSummary: String?, directMessagesOn: Bool,
              make: @escaping @MainActor (RoomRoute, String?) -> RoomChatScreen) -> Int {
        self.make = make
        let opening = Opening(route: route, savedSummary: savedSummary, directMessagesOn: directMessagesOn)
        guard opening != self.opening else { return revision }
        self.opening = opening
        made = nil
        revision &+= 1
        return revision
    }

    /// The room screen for the current revision: made the first time it is asked for, the same screen after.
    var screen: RoomChatScreen? {
        if made == nil, let opening, let make {
            made = make(opening.route, opening.savedSummary)
        }
        return made
    }
}

/// The root's room screen slots: one for each room shown (the room on screen, and rooms opened over it), let go when
/// the room is no longer shown.
@MainActor
final class RoomScreenSlots {
    private var slots: [RoomRoute: RoomScreenSlot] = [:]

    func slot(for route: RoomRoute) -> RoomScreenSlot {
        if let slot = slots[route] { return slot }
        let slot = RoomScreenSlot()
        slots[route] = slot
        return slot
    }

    /// Lets go of the slots of rooms no longer shown.
    func keep(_ shown: [RoomRoute]) {
        guard slots.keys.contains(where: { !shown.contains($0) }) else { return }
        slots = slots.filter { shown.contains($0.key) }
    }
}

/// A slot's room screen. It holds the slot and its revision only, so it is the same view at every draw of the root until
/// what the room is opened with changes, and a draw of it gives the slot's screen, made once.
struct RoomScreenSlotView: View {
    let slot: RoomScreenSlot
    let revision: Int

    var body: some View {
        if let screen = slot.screen {
            screen
        }
    }
}

/// Ends editing anywhere in the app, so the keyboard starts going down now: before the side panel's spring, or before a
/// room is put in place of the one on screen (which takes away the composer the keyboard was for). Carter's freezes of
/// 11-06 each came after a send or a reply, with the keyboard still up as the panel opened or a room was picked from it;
/// one hung with the keyboard's input system on the main thread.
@MainActor
func endAllEditing() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Whether the side panel is open. The root keeps it without watching it (`SidePanelFrame` watches it), so the panel
/// opening and closing draws the frame and never the root, whose draws put the room screen in place.
@MainActor
final class SidePanelState: ObservableObject {
    @Published var isOpen = false
    /// A drag from the left edge that is opening the panel: the room's rows read it, and leave the drag to the edge
    /// (`RoomEdgeClaim`).
    let edgeClaim = RoomEdgeClaim()

    /// What ends editing before the panel opens or another room is put in place: `endAllEditing` in the app; a test
    /// gives its own, to see it run first.
    private let endEditing: @MainActor () -> Void

    init(endEditing: @escaping @MainActor () -> Void = endAllEditing) {
        self.endEditing = endEditing
    }

    /// Opens the panel, editing ended first, so the keyboard starts going down before the panel's spring.
    func open() {
        endEditing()
        isOpen = true
    }

    func close() {
        if isOpen { isOpen = false }
    }

    /// Puts another room, or your rooms, in place of the one on screen: editing ended first (the room's composer goes
    /// with it, so the keyboard starts going down before), then `change`, then the panel closed.
    func switchRoom(_ change: () -> Void) {
        endEditing()
        change()
        close()
    }

    /// A drag on the room, at its first move. One from the left edge (`SidePanelEdgeDrag.claims`), with the panel
    /// closed and nothing over the room, is the edge's: editing ends then, before the room starts following the finger,
    /// and the room's rows leave the drag alone. Returns whether it is the edge's.
    func beginEdgeDrag(start: CGPoint, translation: CGSize, allowed: Bool) -> Bool {
        guard !isOpen, SidePanelEdgeDrag.claims(start: start, translation: translation, allowed: allowed) else {
            return false
        }
        endEditing()
        edgeClaim.isClaimed = true
        return true
    }

    /// The edge's drag let go: far enough along, or flung, and the panel opens as its button opens it (`open`);
    /// otherwise it stays closed. Either way the rows have their swipe back.
    func endEdgeDrag(translation: CGFloat, predicted: CGFloat, width: CGFloat) {
        guard edgeClaim.isClaimed else { return }
        edgeClaim.isClaimed = false
        if SidePanelEdgeDrag.opens(translation: translation, predicted: predicted, width: width) { open() }
    }

    /// A drag that stopped without being let go (the system took the touch): the rows have their swipe back.
    func dropEdgeDrag() {
        edgeClaim.isClaimed = false
    }
}

/// The drag from the left edge that opens the side panel (Carter, 11-06): one that starts within `zone` of the screen's
/// left edge and goes right, more sideways than up or down. Anywhere else a drag is the room's, as before: its scroll,
/// and a row's swipe to reply.
enum SidePanelEdgeDrag {
    /// How near the screen's left edge a drag must start.
    static let zone: CGFloat = 20

    /// Whether a drag from the edge may open the panel at all: not while it is open, not under a sheet (a full-screen
    /// photo and the call's screen are over the room too: they take the touch first), not with a room pushed on the
    /// one on screen (the system's own drag from the edge goes back), and not with VoiceOver on (its users have the
    /// button).
    static func allowed(open: Bool, covered: Bool, roomPushed: Bool, voiceOver: Bool) -> Bool {
        !open && !covered && !roomPushed && !voiceOver
    }

    /// Whether a drag, at its first move, is the edge's.
    static func claims(start: CGPoint, translation: CGSize, allowed: Bool) -> Bool {
        allowed && start.x <= zone && translation.width > 0 && translation.width > abs(translation.height)
    }

    /// How far the room has followed the finger: from resting (0) to open (`width`).
    static func offset(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        min(max(translation, 0), width)
    }

    /// Letting go opens the panel past a third of the way, or flung past half of it.
    static func opens(translation: CGFloat, predicted: CGFloat, width: CGFloat) -> Bool {
        translation > width / 3 || predicted > width / 2
    }
}

/// The side panel underneath, and the room on top as a card pushed aside while the panel is open (Carter #55006). It
/// watches the panel's state, so the panel opening and closing draws this and not the root: the panel and the room it
/// is given are the views the root made last. It also asks for the reads the panel's open needs, and keeps the open
/// panel's rooms read while the app is in front.
struct SidePanelFrame<Panel: View, Room: View>: View {
    @ObservedObject private var state: SidePanelState
    /// How far the room moves right when the panel opens; the panel fits in that space.
    private let width: CGFloat
    /// A sheet over the room: with the open panel, what tells the room it is covered.
    private let coveredOtherwise: Bool
    /// A room pushed on the one on screen: the system's drag from the left edge goes back, so the panel's does not open.
    private let roomPushed: Bool
    /// The open panel's read of its rooms: at once, then every `refresh` nanoseconds, with the app in front.
    private let refresh: UInt64
    /// The reads the panel's open asks for (what it shows that was not read lately).
    private let onOpen: @MainActor () -> Void
    private let poll: @MainActor () -> Void
    private let panel: Panel
    private let room: Room
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// A drag on the room, from its first move: whether it is the edge's, and how far the room follows it. Back to
    /// nothing when the drag ends, however it ends.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.35, dampingFraction: 0.8)))
    private var edge = EdgeFollow()

    private struct EdgeFollow: Equatable {
        var decided = false
        var offset: CGFloat?
    }

    init(state: SidePanelState, width: CGFloat, coveredOtherwise: Bool, roomPushed: Bool, refresh: UInt64,
         onOpen: @escaping @MainActor () -> Void, poll: @escaping @MainActor () -> Void, panel: Panel, room: Room) {
        _state = ObservedObject(wrappedValue: state)
        self.width = width
        self.coveredOtherwise = coveredOtherwise
        self.roomPushed = roomPushed
        self.refresh = refresh
        self.onOpen = onOpen
        self.poll = poll
        self.panel = panel
        self.room = room
    }

    var body: some View {
        // How far open the panel shows, 0 to 1: open, or as far as a drag from the left edge has brought the room.
        let shown = state.isOpen ? 1 : (edge.offset ?? 0) / width
        let edgeAllowed = SidePanelEdgeDrag.allowed(open: state.isOpen, covered: coveredOtherwise,
                                                    roomPushed: roomPushed, voiceOver: voiceOver)
        ZStack(alignment: .leading) {
            // The panel ends before the room card begins, so its right edge (unread counts, See all) is never under it.
            panel
                .frame(width: width - 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(Double(shown))
                .allowsHitTesting(state.isOpen)
                .accessibilityHidden(!state.isOpen)
            room
                // A sheet or the side panel over the room: its moving parts rest (warden, #269).
                .environment(\.roomIsCovered, state.isOpen || coveredOtherwise)
                // A drag the left edge has taken is never a row's swipe to reply.
                .environment(\.roomEdgeClaim, state.edgeClaim)
                // The room moves right, a little smaller, its corners rounded into a card; a tap or a swipe on it
                // closes.
                .overlay {
                    if state.isOpen {
                        Color.black.opacity(0.22)
                            .onTapGesture { state.close() }
                            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                                if value.translation.width < -40 { state.close() }
                            })
                            .accessibilityLabel("Close the side panel")
                            .accessibilityAddTraits(.isButton)
                            .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28 * shown, style: .continuous))
                .shadow(color: .black.opacity(Double(0.28 * shown)), radius: 20, x: -6)
                // Only drawn differently, never laid out again: toggling the safe area here changed the room's height
                // on every frame of the spring, and a room with a long history loaded re-measured all of its rows each
                // time (Carter, 10-30 14:22: frozen after tapping the menu with 238 rows loaded). Following a drag from
                // the edge is the same: drawn, never laid out.
                .scaleEffect(1 - 0.1 * shown, anchor: .leading)
                .offset(x: width * shown)
                // Simultaneous, so a drag anywhere else stays the room's: its scroll, and its rows' swipe to reply.
                .simultaneousGesture(edgeDrag(allowed: edgeAllowed), including: edgeAllowed ? .all : .subviews)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.isOpen)
        .onChange(of: state.isOpen) { open in
            if open { onOpen() }
        }
        // A drag that ended without being let go (the system took the touch) gives the rows their swipe back.
        .onChange(of: edge.decided) { decided in
            if !decided { state.dropEdgeDrag() }
        }
        // While the side panel stays open its rooms keep up: a message that arrives in another room shows its unread
        // badge without closing and opening the panel again (Carter, #61188). Only with the app in front, as the bell's
        // and Waiting on you's polling, and never over a read still going.
        .task(id: DrawerPoll(open: state.isOpen, active: scenePhase == .active)) {
            guard DrawerPoll(open: state.isOpen, active: scenePhase == .active).runs else { return }
            // Back in front with the panel open: read at once, not 15 s later (opening it reads too, and a quiet read
            // never starts over that one).
            poll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refresh)
                guard !Task.isCancelled, state.isOpen, scenePhase == .active else { return }
                poll()
            }
        }
    }

    /// A drag from the left edge opens the panel, the room following the finger (Carter, 11-06). At its first move the
    /// panel's state decides whether the drag is the edge's, and ends editing if it is; let go, the state opens the
    /// panel as its button does, or the room springs back. In the screen's space, as the room moves under the finger.
    private func edgeDrag(allowed: Bool) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($edge) { value, edge, _ in
                if !edge.decided {
                    edge.decided = true
                    if state.beginEdgeDrag(start: value.startLocation, translation: value.translation, allowed: allowed) {
                        edge.offset = 0
                    }
                }
                if edge.offset != nil { edge.offset = SidePanelEdgeDrag.offset(value.translation.width, width: width) }
            }
            .onEnded { value in
                state.endEdgeDrag(translation: value.translation.width, predicted: value.predictedEndTranslation.width,
                                  width: width)
            }
    }
}

/// Release composition of the authenticated repository-backed Sessions surface and the selected-session Pocket flow.
/// When the open side panel reads its rooms again: open, with the app in front.
struct DrawerPoll: Equatable {
    let open: Bool
    let active: Bool
    var runs: Bool { open && active }
}

struct AuthenticatedRootView: View {
    @StateObject private var sessions: SessionListCoordinator
    @StateObject private var details: SelectedSessionDetailCoordinator
    @StateObject private var checkpointPocket: CheckpointPocketCoordinator
    @StateObject private var checkpointNarrationRevocation: VerifiedCheckpointNarrationRevocationRelay
    @StateObject private var revocationRelay: AuthenticatedSessionRevocationRelay
    @StateObject private var notifications: NotificationsCoordinator
    @State private var presentsNotifications = false
    /// Your calls across your rooms: "Calls & briefings".
    @StateObject private var callLog: CallLogCoordinator
    @State private var presentsCallLog = false
    /// What waits on your decision across your rooms (ticket 931e1d2e).
    @StateObject private var waiting: WaitingOnYouCoordinator
    @State private var presentsWaiting = false
    /// Direct messages: on when the server answers their settings (DIRECT_MESSAGES_ENABLED), else nothing shows.
    @StateObject private var directMessages: DirectMessagesCenter
    /// Your room folders: on when the server lists them (ROOM_FOLDERS_ENABLED), else nothing shows.
    @StateObject private var roomFolders: RoomFoldersCenter
    /// The calendar: on when the server answers its routes (CALENDAR_DRAFTS_ENABLED, CALENDAR_FEED_ENABLED). Kept, not
    /// watched, as the side panel's placement is: the room's calendar entry and Settings watch it, so its answers draw
    /// them and never the root (each draw of the root can make the room screen under it again).
    @State private var calendar: CalendarCenter
    /// The side panel's rooms in your folders, placed off the main thread when the rooms or the folders change. Kept,
    /// not watched: the panel watches it, so a new placing draws the panel and not the root (and the room under it).
    @State private var sidePanelPlacement = SidePanelPlacement()
    @Environment(\.scenePhase) private var rootScenePhase
    @ObservedObject private var whisperModelCoordinator: WhisperModelProvisioningCoordinator
    @ObservedObject private var incomingLinks: IncomingLinkInbox
    @State private var presentsNewRoom = false
    @State private var presentsSettings = false
    /// The room on screen, the root of the stack; nil shows your rooms. Breakouts push onto `roomPath`.
    @State private var currentRoom: RoomRoute?
    @State private var roomPath: [RoomRoute] = []
    /// Whether the side panel is open: kept, not watched (`SidePanelFrame` watches it), so its open and close never draw
    /// the root. It also ends editing before the panel opens and before another room is put in place.
    @State private var panelState: SidePanelState
    /// The room screens on screen (`RoomScreenSlot`); the same store for the root's life.
    @State private var roomScreens = RoomScreenSlots()
    /// How often the open side panel reads the rooms again, in nanoseconds.
    static let openDrawerRefresh: UInt64 = 15_000_000_000
    /// What the side panel's open reads again: anything not read for this many seconds (the panel's own poll period;
    /// the bell and Waiting on you poll on their own while the app is in front).
    static let panelFreshness: TimeInterval = 15
    /// How far the room card moves right when the side panel opens; the panel fits in that space.
    private static let drawerWidth: CGFloat = 300
    @State private var presentsPocket = false
    @State private var presentsActivity = false
    @State private var accountName: String?
    /// A room being opened from its id while the server says what it is; any other open replaces it.
    @State private var pendingOpen: UUID?
    /// The room opened last, reopened when the app starts (as the big assistant apps reopen your last chat).
    @AppStorage("pocket.lastRoomId") private var lastRoomId = ""
    @State private var restoredLastRoom = false
    @AppStorage("pocket.theme") private var themeRaw = PocketThemePreference.system.rawValue
    @StateObject private var messageReader = MessageReader()
    @ObservedObject private var readingSource = ReadAloudSource.shared
    private let roomTransport: any RoomTransport
    private let ticketsTransport: any RoomTicketsTransport
    private let admissionsTransport: any RoomAdmissionsTransport
    private let admissionDecider: any AdmissionDeciding
    private let roomSender: any RoomMessageSending
    private let roomActionSender: any RoomActionSending
    private let ticketWriter: any RoomTicketWriting
    private let ticketLeases: any TicketLeaseStoring
    private let ticketExtras: any RoomTicketExtrasReading
    private let accountIdentity: any AccountIdentityProviding
    private let roomReceipts: any RoomReceiptsClient
    private let roomSearch: any RoomSearching
    /// How far you have read each room, told to the server as you read, for the unread badges.
    private let roomReadMarker: any RoomReadMarking
    private let authenticationRevision: UInt64
    private let onSignOut: @MainActor () -> Void

    /// Apple push for this phone is registered by the app's root, and never by a preview of it.
    private let registersPush: Bool

    init(
        authenticationEpoch: UInt64,
        whisperModelCoordinator: WhisperModelProvisioningCoordinator,
        incomingLinks: IncomingLinkInbox,
        services: RootServices = .live(),
        onSignOut: @escaping @MainActor () -> Void,
        onReauthenticationRequired: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSessionSelectionChanged: @escaping @MainActor (UInt64, String?) -> Void = { _, _ in },
        endEditing: @escaping @MainActor () -> Void = endAllEditing
    ) {
        _panelState = State(initialValue: SidePanelState(endEditing: endEditing))
        let guardedReauthentication: @MainActor @Sendable () -> Void = {
            onReauthenticationRequired(authenticationEpoch)
        }
        let checkpointTransport = services.checkpoints
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
            transport: services.sessions,
            // The signing gateway is not deployed and Release pins no signing key yet: checkpoints
            // open as the server holds them until it is.
            opensVerifiedCheckpoints: PocketGatewayTrust.verifiesBundles,
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
            repository: SessionRepository(transport: services.sessions),
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
        let notifications = NotificationsCoordinator(
            transport: services.notifications,
            marker: services.notificationMarker,
            roomTitle: { sessionId in
                sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, sessionId) }?.title
            },
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        )
        _notifications = StateObject(wrappedValue: notifications)
        _callLog = StateObject(wrappedValue: CallLogCoordinator(
            transport: services.callLog,
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        _waiting = StateObject(wrappedValue: WaitingOnYouCoordinator(
            transport: services.waiting,
            sender: services.sender,
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        _directMessages = StateObject(wrappedValue: DirectMessagesCenter(
            client: services.directMessages,
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        _roomFolders = StateObject(wrappedValue: RoomFoldersCenter(
            client: services.roomFolders,
            // Where each room is filed is the room list's: it is read again after every change.
            onRoomsChanged: { sessions.send(.refreshSessions) },
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        let calendarClient = services.calendar ?? CalendarOff()
        let identity = services.identity
        _calendar = State(initialValue: CalendarCenter(
            client: calendarClient,
            feed: calendarClient,
            // The link is kept for the signed-in person in this phone's Keychain only (gone with the sign-in).
            vault: CalendarLinkVault.live,
            person: { await identity.currentAccount().map { $0.accountId ?? $0.authorId } },
            // The webcal link goes to the system (Apple Calendar's subscribe sheet), which says whether it opened.
            openURL: { await UIApplication.shared.open($0) },
            onReauthenticationRequired: { revocationRelay.invalidateAuthentication() }
        ))
        _whisperModelCoordinator = ObservedObject(wrappedValue: whisperModelCoordinator)
        _incomingLinks = ObservedObject(wrappedValue: incomingLinks)
        self.roomTransport = services.room
        self.ticketsTransport = services.tickets
        self.admissionsTransport = services.admissions
        self.admissionDecider = services.admissionDecider
        self.roomSender = services.sender
        self.roomActionSender = services.actionSender
        self.ticketWriter = services.ticketWriter
        self.ticketLeases = services.ticketLeases
        self.ticketExtras = services.ticketExtras
        self.accountIdentity = services.identity
        self.roomReceipts = services.receipts
        self.roomSearch = services.search
        self.roomReadMarker = services.readMarker
        self.registersPush = services.registersPush
        self.authenticationRevision = authenticationEpoch
        self.onSignOut = onSignOut
    }

    private var theme: Binding<PocketThemePreference> {
        Binding(
            get: { PocketThemePreference(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    var body: some View {
        #if DEBUG
        let _ = RootPreview.meter.rootBodyRan()
        #endif
        let _ = roomScreens.keep([currentRoom].compactMap { $0 } + roomPath)
        // The side panel sits underneath; opening it pushes the room aside as a card (Carter #55006). The frame watches
        // whether it is open, so its open and close draw the frame, not this root.
        SidePanelFrame(
            state: panelState,
            width: Self.drawerWidth,
            coveredOtherwise: coveredBySheet,
            roomPushed: !roomPath.isEmpty,
            refresh: Self.openDrawerRefresh,
            // Opening the side panel reads what it shows that was not read lately: the bell, Waiting on you, whether
            // folders and direct messages are on, and your folders, so no count is older than `panelFreshness`. The
            // rooms are read once, at once, by the panel's own poll (a second read here was the same request again).
            onOpen: {
                Task { await notifications.refresh(force: true, ifOlderThan: Self.panelFreshness) }
                Task { await waiting.refresh(ifOlderThan: Self.panelFreshness) }
                Task { await roomFolders.refresh(ifOlderThan: Self.panelFreshness) }
                Task { await directMessages.refresh(ifOlderThan: Self.panelFreshness) }
            },
            poll: { _ = sessions.refreshSessions(quietly: true) },
            panel: sidePanel,
            room: roomStack
        )
        .pocketCanvas()
        // The logo at launch, while your rooms load underneath (Carter, #55287).
        .overlay { LaunchSplash(isReady: roomListSettled) }
        .preferredColorScheme(theme.wrappedValue.colorScheme)
        #if DEBUG
        // The root preview's side panel opens and closes on a signal, so a profile of it has no accessibility client
        // tapping (each tap of a UI test reads the screen's whole accessibility tree first).
        .onReceive(RootPreview.drawerRequests) { open in
            if open { panelState.open() } else { panelState.close() }
        }
        // A room picked as the side panel picks one, and its All rooms, for a hosted test.
        .onReceive(RootPreview.roomRequests) { sessionId in show(roomRoute(for: sessionId)) }
        .onReceive(RootPreview.allRoomsRequests) { _ in showAllRooms() }
        .onAppear {
            guard RootPreview.isRequested else { return }
            let meter = RootPreview.meter
            meter.watch("sessions", sessions)
            meter.watch("notifications", notifications)
            meter.watch("waiting", waiting)
            meter.watch("directMessages", directMessages)
            meter.watch("roomFolders", roomFolders)
            meter.watch("details", details)
            meter.watch("messageReader", messageReader)
        }
        #endif
        .sheet(isPresented: $presentsPocket) {
            SelectedSessionPocketView(
                sessions: sessions,
                checkpointPocket: checkpointPocket,
                checkpointNarrationRevocation: checkpointNarrationRevocation,
                onCheckpointDone: {
                    checkpointPocket.clear()
                    presentsPocket = false
                    presentsActivity = true
                },
                onReauthenticationRequired: invalidateProtectedAuthentication
            )
        }
        .sheet(isPresented: $presentsActivity) {
            SelectedSessionActivityBoundary(
                sessions: sessions,
                details: details,
                reader: messageReader
            )
        }
        .onChange(of: checkpointPocket.isActive) { isActive in
            if isActive {
                presentsPocket = true
            }
        }
        .task {
            accountName = await accountIdentity.currentAccount()?.login
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
                    Task { await notifications.refresh(force: true) }
                case .close:
                    presentsNotifications = false
                }
            }
            .onAppear { notifications.listShown(true) }
            .onDisappear { notifications.listShown(false) }
        }
        .sheet(isPresented: $presentsCallLog) {
            CallLogView(state: callLog.state, readingId: readingCallId) { intent in
                switch intent {
                case .refresh:
                    Task { await callLog.refresh() }
                case .loadMore:
                    Task { await callLog.loadMore() }
                case .open(let id):
                    guard let link = callLog.link(for: id) else { return }
                    presentsCallLog = false
                    open(link)
                case .listen(let id):
                    if readingCallId == id {
                        messageReader.stop()
                    } else if let readable = callLog.readable(id) {
                        ReadAloudSource.shared.reading(in: readable.sessionId)
                        if messageReader.read(id: "call:" + id, markdown: readable.markdown, title: readable.title)
                            == .unavailable {
                            callLog.show(notice: "Listening isn't available while a call or a briefing holds the audio.")
                        }
                    }
                case .openBriefing:
                    presentsCallLog = false
                    // One sheet goes before the next comes: iOS 16 drops a sheet asked for while another is leaving.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { presentsPocket = true }
                case .close:
                    presentsCallLog = false
                }
            }
        }
        .sheet(isPresented: $presentsWaiting) {
            WaitingOnYouView(state: waiting.state, send: { intent in
                guard let link = waiting.send(intent) else { return }
                presentsWaiting = false
                open(link)
            }, onDone: { presentsWaiting = false })
        }
        .onChange(of: rootScenePhase) { phase in
            if phase == .active { notifications.startPolling() } else { notifications.stopPolling() }
            if phase == .active { waiting.startPolling() } else { waiting.stopPolling() }
        }
        .onChange(of: incomingLinks.revision) { _ in openPendingLinkIfReady() }
        .onChange(of: roomListSettled) { _ in openPendingLinkIfReady() }
        // The app icon shows the bell's unread count.
        .onChange(of: notifications.unreadCount) { count in PushRegistrar.shared.setBadge(count) }
        .sheet(isPresented: $presentsSettings) {
            WhisperModelSettingsView(
                coordinator: whisperModelCoordinator,
                directMessages: directMessages,
                calendar: CalendarSettingsContext(center: calendar, rooms: calendarRooms,
                                                  onReauthenticationRequired: invalidateProtectedAuthentication),
                onSignOut: {
                    presentsSettings = false
                    onSignOut()
                }
            )
        }
        .modifier(RoomFolderSheets(center: roomFolders))
        .sheet(isPresented: $presentsNewRoom) {
            if let creator = roomSender as? any RoomCreating {
                NewRoomSheet(
                    creator: creator,
                    onCreated: { sessionId, title in
                        presentsNewRoom = false
                        sessions.send(.refreshSessions)
                        // You made it, so you own it: the owner's tools (rename, invite) are there at once.
                        show(RoomRoute(sessionId: sessionId, title: title, membershipRole: "owner"))
                    },
                    onClose: { presentsNewRoom = false }
                )
            }
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
            Task { await directMessages.refresh() }
            Task { await roomFolders.refresh() }
            notifications.startPolling()
            // Waiting on you is read from sign-in on, not only once the app comes back to the front (warden, #270).
            waiting.startPolling()
            // Apple push: a tap opens its room at the message; the room on screen gets no banner.
            PushRegistrar.shared.inbox = incomingLinks
            PushRegistrar.shared.currentRoomId = { (roomPath.last ?? currentRoom)?.sessionId }
            // A notification while Pocket is open slides in over it, and a tap opens it here (Carter, #55508).
            InAppBanner.shared.onOpen = { link in open(link) }
            // Only a tapped push or banner reads its notification; going into a room any other way reads nothing
            // (warden, #275). The bell reads by id itself.
            InAppBanner.shared.onOpenedNotification = { link, id in
                notifications.markOpened(link, notificationId: id)
                Task { await notifications.refresh(force: true) }
            }
            PushRegistrar.shared.onOpened = { link, id in
                notifications.markOpened(link, notificationId: id)
                Task { await notifications.refresh(force: true) }
            }
            InAppBanner.shared.isHosted = true
            // An answered agent's call opens its room, where its voice room starts.
            RoomCallDesk.shared.openRoom = { [weak incomingLinks] sessionId in
                incomingLinks?.receive(SentiLink(sessionId: sessionId))
            }
            if registersPush { Task { await PushRegistrar.shared.start() } }
            openPendingLinkIfReady()
        }
        .onDisappear {
            InAppBanner.shared.isHosted = false
            InAppBanner.shared.onOpen = nil
            InAppBanner.shared.dismiss()
            notifications.stopPolling()
            waiting.stopPolling()
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
        // Whatever was open on top goes, so the room opened is the one you see (warden, #272).
        presentsCallLog = false
        presentsWaiting = false
        let row = sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, link.sessionId) }
        presentsNotifications = false
        presentsSettings = false
        presentsPocket = false
        presentsActivity = false
        func route(direct: DirectRoomInfo?) -> RoomRoute {
            RoomRoute(
                sessionId: link.sessionId,
                title: row?.title ?? direct?.counterpart.displayName ?? "Room",
                membershipRole: row?.membershipRole ?? "",
                focusSequenceId: link.messageSequence,
                // A reply notification opens the thread at the reply.
                focusReplyId: link.messageSequence == nil ? nil : link.replyId,
                focusTicketId: link.ticketId,
                opensAdmissions: link.admissionId != nil,
                readMark: row.map(RoomReadMark.init(row:)),
                // A direct message (from its push, too) opens as one: whom it is with, and its room.
                direct: direct
            )
        }
        guard row == nil else {
            show(route(direct: DirectRoomInfo(row: row, rows: sessions.state.rows)))
            return
        }
        // Not in the room list yet (the push of a direct message that just started): ask the server what it is first,
        // so it opens with its header. A room the list reads meanwhile, or another open, wins.
        sessions.send(.refreshSessions)
        let token = UUID()
        pendingOpen = token
        Task { @MainActor in
            let direct = await directMessages.directInfo(for: link.sessionId, row: nil, rows: sessions.state.rows)
            guard pendingOpen == token else { return }
            show(route(direct: direct))
        }
    }

    /// A direct message the server opened from a profile card: the room on screen, and the room list reads it.
    @MainActor
    private func openDirect(_ dm: DirectMessage) {
        let row = sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, dm.sessionId) }
        show(RoomRoute(
            sessionId: dm.sessionId,
            title: dm.counterpart.displayName,
            membershipRole: row?.membershipRole ?? "",
            readMark: row.map(RoomReadMark.init(row:)),
            direct: DirectRoomInfo(dm)
        ))
        sessions.send(.refreshSessions)
    }

    /// What a room screen needs for direct messages, where they are on.
    private var directContext: RoomDirectContext? {
        RoomDirectContext.ifAvailable(
            directMessages,
            existing: { senderId in
                sessions.state.rows.first { $0.counterpart?.senderId.lowercased() == senderId.lowercased() }?.sessionId
            },
            open: { dm in openDirect(dm) }
        )
    }

    /// Puts a room on screen as the root (no back button: the side panel is the way between rooms), keeps the
    /// selection Pocket and Activity follow in step, and remembers it for the next launch.
    @MainActor
    private func show(_ route: RoomRoute) {
        // Editing ends first, through the side panel's own step: the room's composer goes with the room.
        panelState.switchRoom {
            pendingOpen = nil
            if !UTF8ExactIdentity.matches(sessions.selectedSessionId, route.sessionId) {
                sessions.send(.selectSession(sessionId: route.sessionId))
            }
            roomPath = []
            currentRoom = RoomRoute.keepingOpenRoom(currentRoom, for: route)
            lastRoomId = route.sessionId
            #if DEBUG
            RootPreview.meter.roomPutInPlace(route.sessionId)
            #endif
        }
    }

    /// Your rooms in place of the room on screen (the side panel's All rooms), editing ended first in the same way.
    @MainActor
    private func showAllRooms() {
        panelState.switchRoom {
            roomPath = []
            currentRoom = nil
            #if DEBUG
            RootPreview.meter.roomPutInPlace(nil)
            #endif
        }
    }

    private func roomRoute(for sessionId: String) -> RoomRoute {
        let row = sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, sessionId) }
        return RoomRoute(
            sessionId: sessionId,
            title: row?.title ?? "Room",
            membershipRole: row?.membershipRole ?? "",
            readMark: row.map(RoomReadMark.init(row:)),
            direct: DirectRoomInfo(row: row, rows: sessions.state.rows)
        )
    }

    /// Reopens the last room once the room list has settled and still lists it. A link that arrived first wins.
    @MainActor
    private func restoreLastRoomIfReady() {
        guard !restoredLastRoom, roomListSettled else { return }
        restoredLastRoom = true
        guard currentRoom == nil, !lastRoomId.isEmpty,
              sessions.state.rows.contains(where: { UTF8ExactIdentity.matches($0.sessionId, lastRoomId) }) else { return }
        show(roomRoute(for: lastRoomId))
    }

    @MainActor
    private func closeDrawer() {
        panelState.close()
    }

    private var drawerButton: some View {
        Button {
            CrashReporter.shared.note("drawerOpened")
            panelState.open()
        } label: {
            Image(systemName: "line.3.horizontal")
                .overlay(alignment: .topTrailing) {
                    if notifications.unreadCount > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 9, height: 9)
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .accessibilityLabel(notifications.unreadCount > 0
            ? "Rooms and settings, \(notifications.unreadCount) unread notifications"
            : "Rooms and settings")
        .accessibilityIdentifier("pocket.drawer.open")
    }

    /// The side panel. Its rooms and folders are placed off the main thread, and only when the room list or your
    /// folders change: opening it, and a read that finds nothing new, place nothing.
    private var sidePanel: some View {
        PocketSidePanel(
            placement: sidePanelPlacement,
            currentRoomId: currentRoom?.sessionId,
            unreadNotifications: notifications.unreadCount,
            waitingOnYou: waiting.state.isAvailable ? waiting.state.total : nil,
            accountName: accountName,
            theme: theme,
            onSelectRoom: { sessionId in show(roomRoute(for: sessionId)) },
            onAllRooms: { showAllRooms() },
            onNotifications: {
                closeDrawer()
                presentsNotifications = true
                Task { await notifications.refresh(force: true) }
            },
            onWaitingOnYou: {
                closeDrawer()
                presentsWaiting = true
                Task { await waiting.refresh() }
            },
            onCalls: {
                closeDrawer()
                presentsCallLog = true
                Task { await callLog.refresh() }
            },
            onActivity: {
                closeDrawer()
                presentsActivity = true
            },
            onSettings: {
                closeDrawer()
                presentsSettings = true
                Task { await directMessages.refresh() }
                Task { await calendar.refresh(probeRoom: calendarProbeRoom) }
            },
            onNewRoom: roomSender is any RoomCreating ? {
                closeDrawer()
                presentsNewRoom = true
            } : nil,
            folderNotice: roomFolders.notice,
            // Folders show only where they are on.
            onFolder: roomFolders.items == nil ? nil : { roomFolders.send($0) }
        )
        .onAppear(perform: placeSidePanelRooms)
        .onChange(of: sessions.state.rows) { _ in placeSidePanelRooms() }
        .onChange(of: roomFolders.folders) { _ in placeSidePanelRooms() }
    }

    private func placeSidePanelRooms() {
        sidePanelPlacement.update(rows: sessions.state.rows, folders: roomFolders.items)
    }

    /// The rooms: the room on screen as the root of the stack (your rooms when there is none), rooms opened over it, and
    /// the player of a message read aloud in another room.
    private var roomStack: some View {
        NavigationStack(path: $roomPath) {
            Group {
                if let currentRoom {
                    roomScreen(currentRoom)
                        .id(currentRoom)
                } else {
                    SessionListView(state: sessions.state, folders: roomFolders.items,
                                    onFolder: { roomFolders.send($0) }) { intent in
                        sessions.send(intent)
                        if case .selectSession(let sessionId) = intent,
                           UTF8ExactIdentity.matches(sessions.selectedSessionId, sessionId) {
                            show(roomRoute(for: sessionId))
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { drawerButton }
            }
            .modifier(calendarEntry)
            .navigationDestination(for: RoomRoute.self) { route in
                roomScreen(route)
            }
        }
        // Listening goes on when you leave its room (Carter, 10-30): outside that room the app keeps the player, and
        // its title takes you back to the message.
        .overlay(alignment: .bottom) {
            if let playback = messageReader.playback, let source = readingSource.sessionId,
               source != (roomPath.last ?? currentRoom)?.sessionId {
                ReadAloudPlayer(reader: messageReader, playback: playback) {
                    if let id = messageReader.readingId {
                        open(ReadAloudSource.link(readingId: id, sessionId: source))
                    }
                }
                .padding(.bottom, currentRoom == nil ? 16 : 72)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: messageReader.playback == nil)
    }

    /// The room on screen, made again only when what it is opened with changes (`RoomScreenSlot`).
    private func roomScreen(_ route: RoomRoute) -> some View {
        let savedSummary = sessions.state.rows.first { UTF8ExactIdentity.matches($0.sessionId, route.sessionId) }?.summary
        let slot = roomScreens.slot(for: route)
        let revision = slot.open(route, savedSummary: savedSummary, directMessagesOn: directContext != nil) {
            route, savedSummary in
            roomChatScreen(route, savedSummary: savedSummary, direct: directContext)
        }
        return RoomScreenSlotView(slot: slot, revision: revision)
    }

    /// The calendar's ⋯ entry for the room on screen (a room, not a direct message). It sits on the navigation root
    /// beside the side panel's button, outside the room screen and its host.
    private var calendarEntry: RoomCalendarEntry {
        RoomCalendarEntry(center: calendar, sessionId: currentRoom?.sessionId ?? "", roomTitle: currentRoom?.title ?? "",
                          canAdd: CalendarCenter.canAdd(role: currentRoom?.membershipRole ?? ""),
                          isOffered: currentRoom.map { $0.direct == nil } ?? false,
                          onReauthenticationRequired: invalidateProtectedAuthentication)
    }

    private func roomChatScreen(_ route: RoomRoute, savedSummary: String?, direct: RoomDirectContext?) -> RoomChatScreen {
        RoomChatScreen(
            route: route,
            transport: roomTransport,
            sender: roomSender,
            actionSender: roomActionSender,
            identity: accountIdentity,
            ticketsTransport: ticketsTransport,
            ticketWriter: ticketWriter,
            ticketLeases: ticketLeases,
            ticketExtras: ticketExtras,
            admissionsTransport: admissionsTransport,
            admissionDecider: admissionDecider,
            openRoom: { link in open(link) },
            openChildRoom: { child in roomPath.append(child) },
            // A New agent's new chat: the room list reads it, and it opens as the room on screen, as a new room does.
            openNewRoom: { route in
                sessions.send(.refreshSessions)
                show(route)
            },
            receipts: roomReceipts,
            search: roomSearch,
            readMarker: roomReadMarker,
            reader: messageReader,
            onRenamed: { sessions.send(.refreshSessions) },
            // What the room list has of the room's summary, for a member who reads it without making one.
            savedSummary: savedSummary,
            onRead: { sessionId, sequence, caughtUp in
                sessions.noteRead(sessionId: sessionId, through: sequence, caughtUp: caughtUp)
            },
            direct: direct,
            onReauthenticationRequired: invalidateProtectedAuthentication
        )
    }

    /// Any room you are in, to ask whether drafting is on: a viewer's room answers the flag as well as any.
    private var calendarProbeRoom: String? {
        CalendarCenter.probeRoom(in: sessions.state.rows.map {
            (id: $0.sessionId, role: $0.membershipRole, isDirect: $0.isDirect)
        })
    }

    /// The rooms an event can be added to from Settings' calendar: rooms (not direct messages) you can write in.
    private var calendarRooms: [CalendarRoomChoice] {
        sessions.state.rows
            .filter { !$0.isDirect && CalendarCenter.canAdd(role: $0.membershipRole) }
            .map { CalendarRoomChoice(id: $0.sessionId, title: $0.title) }
    }

    /// The call whose summary is being read aloud, if any.
    private var readingCallId: String? {
        guard let id = messageReader.readingId, id.hasPrefix("call:") else { return nil }
        return String(id.dropFirst("call:".count))
    }

    /// A sheet over the room (the side panel over it is `SidePanelFrame`'s to say).
    private var coveredBySheet: Bool {
        presentsNotifications || presentsWaiting || presentsPocket || presentsActivity || presentsSettings
            || presentsNewRoom || presentsCallLog || roomFolders.sheet != nil
    }

    /// The room list has loaded or failed, so a room opened from a link knows its title and your role in it.
    private var roomListSettled: Bool {
        sessions.state.provenance != .unavailable || sessions.state.failure != nil
    }

    /// Opens the link iOS handed the app (a universal link) once the room list has settled. Each link opens once.
    @MainActor
    private func openPendingLinkIfReady() {
        guard roomListSettled else { return }
        if let link = incomingLinks.take() {
            // A link decides the room; the last room is not reopened over it.
            restoredLastRoom = true
            open(link)
        } else {
            restoreLastRoomIfReady()
        }
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
    @ObservedObject var reader: MessageReader

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
        .sheet(item: Binding(
            get: { details.serverCheckpoint },
            set: { if $0 == nil { details.closeServerCheckpoint() } }
        )) { row in
            ServerCheckpointView(row: row, reader: reader) { details.closeServerCheckpoint() }
        }
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
            SessionCheckpointListView(state: state, verifies: PocketGatewayTrust.verifiesBundles) { intent in
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
