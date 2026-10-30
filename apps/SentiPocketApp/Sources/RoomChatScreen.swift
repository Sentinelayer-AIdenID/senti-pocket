import SwiftUI
import PocketSyncClient
import PocketUI
import PocketVoice

/// Navigation value for an open room.
struct RoomRoute: Hashable {
    let sessionId: String
    let title: String
    /// owner, admin, contributor or viewer. A viewer can read but not post.
    var membershipRole: String = ""
    /// A message to open the room at (from a notification or link).
    var focusSequenceId: Int64?
    /// A ticket to open over the room (a link's `?ticket=`, like the web's ticket drawer).
    var focusTicketId: String?
    /// Opens the room's agent requests (a link's `?admission=`), for owners and admins.
    var opensAdmissions = false
    /// A breakout's own room: no agent requests or tickets of its own in v1-a.
    var isBreakout = false
}

/// A ticket opened from a link, shown over the room.
private struct LinkedTicket: Identifiable {
    let id: String
}

/// Hosts one room's live chat. The room streams while it is on screen and the app is active, and pauses (keeping
/// what it loaded) when it is closed or the app goes to the background; returning catches up before going live.
/// Links tapped in the room stay in the app (`RoomLinkRouter`): this room's messages, tickets and agent requests open
/// here, another room opens through `openRoom`, and other web links open in the browser.
struct RoomChatScreen: View {
    @StateObject private var coordinator: RoomChatCoordinator
    /// Who is working on what (the boxes' flight records), read only while the panel is open.
    @StateObject private var flight: FlightRecordCoordinator
    @State private var showsFlight = false
    /// A voice conversation in this room, while one is open.
    @State private var voiceRoom: VoiceRoomCoordinator?
    @State private var choosesVoicePartner = false
    @Environment(\.openURL) private var openExternalURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsTickets = false
    /// The tickets screen opens straight into a new ticket (the composer's "File a ticket").
    @State private var ticketsStartFiling = false
    @State private var showsAdmissions = false
    @State private var showsBreakouts = false
    @State private var showsSearch = false
    @State private var attachmentPreview: AttachmentPreviewItem?
    @State private var attachmentProblem: String?
    @State private var listenProblem: String?
    /// The app's one reader: one message is read at a time, wherever it was started.
    @ObservedObject private var reader: MessageReader
    @State private var openingAttachment = false
    @State private var linkedTicket: LinkedTicket?
    @State private var appliedRouteLinks = false
    private let route: RoomRoute
    private let ticketsTransport: (any RoomTicketsTransport)?
    private let admissionsTransport: (any RoomAdmissionsTransport)?
    private let admissionDecider: (any AdmissionDeciding)?
    private let ticketAnswerSender: (any RoomMessageSending)?
    /// Posting spoken turns and the transcript, as you; nil where you cannot post.
    private let voicePoster: (any VoiceRoomPosting)?
    private let ticketWriter: (any RoomTicketWriting)?
    private let ticketLeases: any TicketLeaseStoring
    private let ticketExtras: (any RoomTicketExtrasReading)?
    private let identity: (any AccountIdentityProviding)?
    private let search: (any RoomSearching)?
    private let openRoom: @MainActor (SentiLink) -> Void
    private let openChildRoom: @MainActor (RoomRoute) -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    init(
        route: RoomRoute,
        transport: any RoomTransport,
        sender: (any RoomMessageSending)? = nil,
        actionSender: (any RoomActionSending)? = nil,
        identity: (any AccountIdentityProviding)? = nil,
        ticketsTransport: (any RoomTicketsTransport)? = nil,
        ticketWriter: (any RoomTicketWriting)? = nil,
        ticketLeases: any TicketLeaseStoring = InMemoryTicketLeaseStore(),
        ticketExtras: (any RoomTicketExtrasReading)? = nil,
        admissionsTransport: (any RoomAdmissionsTransport)? = nil,
        admissionDecider: (any AdmissionDeciding)? = nil,
        openRoom: @escaping @MainActor (SentiLink) -> Void = { _ in },
        openChildRoom: @escaping @MainActor (RoomRoute) -> Void = { _ in },
        attachmentFetcher: any AttachmentFileFetching = URLSessionAttachmentFetcher(),
        receipts: (any RoomReceiptsClient)? = nil,
        search: (any RoomSearching)? = nil,
        reader: MessageReader,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.route = route
        self.reader = reader
        self.search = search
        self.ticketsTransport = ticketsTransport
        self.admissionsTransport = admissionsTransport
        self.admissionDecider = admissionDecider
        // A viewer cannot post, so cannot answer a ticket's decision either.
        self.ticketAnswerSender = route.membershipRole.lowercased() == "viewer" ? nil : sender
        self.voicePoster = route.membershipRole.lowercased() == "viewer" ? nil : sender as? any VoiceRoomPosting
        self.ticketWriter = ticketWriter
        self.ticketLeases = ticketLeases
        self.ticketExtras = ticketExtras
        self.identity = identity
        self.openRoom = openRoom
        self.openChildRoom = openChildRoom
        self.onReauthenticationRequired = onReauthenticationRequired
        _coordinator = StateObject(wrappedValue: RoomChatCoordinator(
            sessionId: route.sessionId,
            title: route.title,
            transport: transport,
            sender: sender,
            actionSender: actionSender,
            identity: identity,
            membershipRole: route.membershipRole,
            focusSequenceId: route.focusSequenceId,
            attachmentFetcher: attachmentFetcher,
            receipts: receipts,
            directory: ticketExtras,
            onReauthenticationRequired: onReauthenticationRequired
        ))
        _flight = StateObject(wrappedValue: FlightRecordCoordinator(
            sessionId: route.sessionId,
            mint: HTTPMintClient(tokenProvider: { SessionTokenStore.load() })
        ))
    }

    /// The room's agents for the Flight record: those here now, then any that said what they are working on,
    /// live work first.
    private var flightAgents: [FlightRecordState.Agent] {
        let work = coordinator.latestWork()
        var agents: [FlightRecordState.Agent] = []
        for person in coordinator.state.presence?.people ?? [] where !person.isHuman {
            let line = work[person.id]
            agents.append(FlightRecordState.Agent(id: person.id, isHere: true, isIdle: person.isIdle,
                                                  status: line?.text, statusAt: line?.at))
        }
        for (actor, line) in work where !actor.lowercased().hasPrefix("human-")
            && !agents.contains(where: { $0.id == actor }) {
            agents.append(FlightRecordState.Agent(id: actor, isHere: false, isIdle: false, status: line.text, statusAt: line.at))
        }
        return agents.sorted {
            let left = ($0.status.map { !$0.lowercased().hasPrefix("done") } ?? false ? 0 : 1, $0.isHere ? 0 : 1,
                        -($0.statusAt?.timeIntervalSince1970 ?? 0))
            let right = ($1.status.map { !$0.lowercased().hasPrefix("done") } ?? false ? 0 : 1, $1.isHere ? 0 : 1,
                         -($1.statusAt?.timeIntervalSince1970 ?? 0))
            return left < right
        }
    }

    /// The room's agents for ticket assignment, as the web builds them from the room (the member directory is not
    /// served yet): the agents present, then the agents who posted in what is loaded.
    private var ticketAssignRoster: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let present = (coordinator.state.presence?.people ?? []).filter { !$0.isHuman }.map(\.id)
        let authors = coordinator.state.rows.compactMap { row -> String? in
            if case .message(let message) = row, !message.isHuman { return message.authorId }
            return nil
        }
        for id in present + authors where !id.isEmpty && seen.insert(id.lowercased()).inserted {
            ids.append(id)
        }
        return ids
    }

    /// Whom you can talk with: the agents here now, then the agents who answered most recently.
    private var voicePartners: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        let present = (coordinator.state.presence?.people ?? []).filter { !$0.isHuman }.map(\.id)
        let authors = coordinator.state.rows.reversed().compactMap { row -> String? in
            if case .message(let message) = row, !message.isHuman { return message.authorId }
            return nil
        }
        for id in present + authors where !id.isEmpty && seen.insert(id.lowercased()).inserted {
            ids.append(id)
        }
        return Array(ids.prefix(8))
    }

    /// Whose message (or reply) is being read, for the player.
    private func readAloudTitle(for id: String) -> String? {
        if id.hasPrefix("msg:"), let sequence = Int64(id.dropFirst("msg:".count)),
           case .message(let message)? = coordinator.state.messageRow(for: sequence) {
            return message.authorName
        }
        if id.hasPrefix("reply:") {
            let replyId = String(id.dropFirst("reply:".count))
            for row in coordinator.state.rows {
                if case .message(let message) = row, message.inlineReplyId == replyId { return message.authorName }
            }
            return coordinator.state.thread?.replies.first { $0.id == replyId }?.authorName
        }
        return nil
    }

    private func startVoiceRoom(with agents: [String]) {
        guard voiceRoom == nil, let voicePoster else { return }
        reader.stop()
        let handles = coordinator.state.ownMentionHandles.filter { $0 != "all" }.sorted()
        let room = VoiceRoomCoordinator(
            sessionId: route.sessionId,
            with: agents,
            invited: agents.isEmpty ? voicePartners : agents,
            you: handles.first ?? "you",
            ownAuthorIds: Set(handles.map { "human-\($0)" }),
            listener: OnDeviceVoiceListener(),
            speaker: AgentVoiceSpeaker(),
            audio: PhoneVoiceRoomAudioSession(),
            poster: voicePoster,
            onEnded: { endVoiceRoom() }
        )
        coordinator.onLiveMessages = { [weak room] messages in room?.receive(messages) }
        coordinator.onNewReplies = { [weak room] replies in room?.receive(replies: replies) }
        coordinator.readsRepliesOften = true
        voiceRoom = room
        room.begin()
    }

    private func endVoiceRoom() {
        coordinator.onLiveMessages = nil
        coordinator.onNewReplies = nil
        coordinator.readsRepliesOften = false
        voiceRoom = nil
    }

    /// Contributors and above file and change tickets (the API's `min_role="contributor"`). An unknown role offers
    /// nothing: the API would decide, but a button it refuses is worse than none.
    private var writesTickets: Bool {
        ["owner", "admin", "contributor"].contains(route.membershipRole.lowercased())
    }

    /// Only owners and admins decide agent requests (the API enforces it; the screen follows it).
    private var decidesAdmissions: Bool {
        !route.isBreakout && admissionsTransport != nil && admissionDecider != nil
            && ["owner", "admin"].contains(route.membershipRole.lowercased())
    }

    /// Opens a breakout as its own room. Posting there follows the breakout's own permission, not the parent's.
    private func openBreakout(_ childSessionId: String) {
        let card = coordinator.state.breakouts[childSessionId]
        guard card?.canRead == true else { return }
        let role = card?.canPost == true ? (route.membershipRole.isEmpty ? "contributor" : route.membershipRole) : "viewer"
        openChildRoom(RoomRoute(
            sessionId: childSessionId,
            title: card?.title ?? "Breakout",
            membershipRole: role,
            isBreakout: true
        ))
    }

    private var linkAction: OpenURLAction {
        OpenURLAction { url in handle(url) }
    }

    var body: some View {
        RoomChatView(
            state: coordinator.state,
            readingAloudId: reader.readingId,
            composerActions: RoomComposerActions(
                canFileTicket: ticketsTransport != nil && writesTickets && !route.isBreakout,
                canSearch: search != nil
            )
        ) { intent in
            if case .openBreakout(let childSessionId) = intent {
                openBreakout(childSessionId)
            } else if case .openTickets(let filing) = intent {
                ticketsStartFiling = filing
                showsTickets = true
            } else if intent == .openSearch {
                showsSearch = true
            } else if case .openAttachment(let attachmentId) = intent {
                openAttachment(attachmentId)
            } else if case .readAloud(let id, let text) = intent {
                if reader.read(id: id, markdown: text, title: readAloudTitle(for: id)) == .unavailable {
                    listenProblem = "A call or briefing is using the audio. Listen when it ends."
                }
            } else if intent == .stopReadingAloud {
                reader.stop()
            } else {
                coordinator.send(intent)
            }
        }
        .toolbar {
            if voicePoster != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        choosesVoicePartner = true
                    } label: {
                        Label("Talk", systemImage: "waveform")
                    }
                    .disabled(voiceRoom != nil)
                    .accessibilityLabel("Talk with the agents by voice")
                    .accessibilityIdentifier("pocket.room.talk")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    flight.setAgents(flightAgents)
                    showsFlight = true
                } label: {
                    Label("Flight record", systemImage: "airplane")
                }
                .accessibilityLabel("Flight record: who is working on what")
                .accessibilityIdentifier("pocket.room.flight")
            }
            if decidesAdmissions {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsAdmissions = true
                    } label: {
                        Label("Agent requests", systemImage: "person.badge.shield.checkmark")
                    }
                    .accessibilityIdentifier("pocket.room.admissions")
                }
            }
            if !route.isBreakout, !coordinator.state.breakouts.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsBreakouts = true
                    } label: {
                        Label("Breakouts", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("pocket.room.breakouts.open")
                }
            }
            if ticketsTransport != nil, !route.isBreakout {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsTickets = true
                    } label: {
                        Label("Tickets", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("pocket.room.tickets")
                }
            }
        }
        .overlay {
            if showsFlight {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { showsFlight = false }
                        .accessibilityLabel("Close the flight record")
                        .accessibilityAddTraits(.isButton)
                    FlightRecordPanel(
                        state: flight.state,
                        onClose: { showsFlight = false },
                        onExpand: { flight.expand($0) },
                        onOpenConsole: { openExternalURL($0) }
                    )
                    .frame(maxWidth: 380)
                    .padding(.leading, 40)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                        if value.translation.width > 60 { showsFlight = false }
                    })
                    .transition(.move(edge: .trailing))
                }
                .onAppear { flight.start() }
                .onDisappear { flight.stop() }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showsFlight)
        .overlay(alignment: .bottom) {
            if let voiceRoom {
                VoiceRoomHost(room: voiceRoom)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: voiceRoom != nil)
        .overlay(alignment: .bottom) {
            // The Listen player: above the composer while a message is read (a voice room speaks on its own).
            if voiceRoom == nil, let playback = reader.playback {
                ReadAloudBar(state: ReadAloudBarState(
                    title: playback.title,
                    isPaused: playback.isPaused,
                    elapsedBefore: playback.elapsedBefore,
                    sentenceStartedAt: playback.sentenceStartedAt,
                    sentenceLength: playback.sentenceLength,
                    total: playback.total,
                    hasGoodVoice: playback.hasGoodVoice
                )) { action in
                    switch action {
                    case .togglePause: if playback.isPaused { reader.resume() } else { reader.pause() }
                    case .skip(let seconds): reader.skip(by: seconds)
                    case .close: reader.stop()
                    }
                }
                .padding(.bottom, 72)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: reader.playback == nil)
        .confirmationDialog("Talk with", isPresented: $choosesVoicePartner, titleVisibility: .visible) {
            ForEach(voicePartners, id: \.self) { agent in
                Button(agent) { startVoiceRoom(with: [agent]) }
            }
            Button("Everyone (a meeting)") { startVoiceRoom(with: []) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You talk; they answer in the room and the phone reads each answer in that agent's voice. Hanging up saves the transcript to the room.")
        }
        .onDisappear {
            if let voiceRoom { Task { await voiceRoom.hangUp() } }
            coordinator.onFeedback = nil
        }
        .onAppear {
            // The room on screen sounds and vibrates, except during a voice room, which speaks instead.
            coordinator.onFeedback = { event in
                guard voiceRoom == nil else { return }
                RoomFeedback.shared.play(event)
            }
        }
        .onChange(of: coordinator.state.presence) { _ in
            if showsFlight { flight.setAgents(flightAgents) }
        }
        .navigationDestination(isPresented: $showsAdmissions) {
            if let admissionsTransport, let admissionDecider {
                AdmissionsScreen(
                    sessionId: route.sessionId,
                    transport: admissionsTransport,
                    decider: admissionDecider,
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .onChange(of: showsTickets) { shown in
            if !shown { ticketsStartFiling = false }
        }
        .navigationDestination(isPresented: $showsTickets) {
            if let ticketsTransport {
                RoomTicketsScreen(
                    sessionId: route.sessionId,
                    transport: ticketsTransport,
                    sender: ticketAnswerSender,
                    writer: writesTickets ? ticketWriter : nil,
                    leases: ticketLeases,
                    identity: identity,
                    assignRoster: ticketAssignRoster,
                    extras: ticketExtras,
                    startsFiling: ticketsStartFiling,
                    onOpenMessage: { sequence in focus(on: sequence) },
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .navigationDestination(isPresented: $showsBreakouts) {
            RoomBreakoutsView(cards: Array(coordinator.state.breakouts.values)) { childSessionId in
                showsBreakouts = false
                openBreakout(childSessionId)
            }
        }
        // Room-wide actions sit under the room's title, so the toolbar keeps its width.
        .toolbarTitleMenu {
            if search != nil {
                Button {
                    showsSearch = true
                } label: {
                    Label("Search messages", systemImage: "magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showsSearch) {
            if let search {
                RoomSearchSheet(
                    sessionId: route.sessionId,
                    searcher: search,
                    onReauthenticationRequired: onReauthenticationRequired
                ) { sequenceId in
                    coordinator.focus(on: sequenceId)
                }
            }
        }
        .sheet(item: $attachmentPreview) { item in
            AttachmentQuickLook(url: item.url)
                .ignoresSafeArea()
        }
        .alert("Couldn't open the file", isPresented: Binding(
            get: { attachmentProblem != nil },
            set: { if !$0 { attachmentProblem = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentProblem = nil }
        } message: {
            Text(attachmentProblem ?? "")
        }
        .alert("Can't read aloud now", isPresented: Binding(
            get: { listenProblem != nil },
            set: { if !$0 { listenProblem = nil } }
        )) {
            Button("OK", role: .cancel) { listenProblem = nil }
        } message: {
            Text(listenProblem ?? "")
        }
        .sheet(item: $linkedTicket) { linked in
            if let ticketsTransport {
                RoomTicketLinkScreen(
                    sessionId: route.sessionId,
                    ticketId: linked.id,
                    transport: ticketsTransport,
                    sender: ticketAnswerSender,
                    writer: writesTickets ? ticketWriter : nil,
                    leases: ticketLeases,
                    identity: identity,
                    assignRoster: ticketAssignRoster,
                    extras: ticketExtras,
                    onOpenMessage: { sequence in focus(on: sequence) },
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .environment(\.openURL, linkAction)
        .onAppear {
            coordinator.resume()
            applyRouteLinksOnce()
        }
        .onDisappear {
            coordinator.pause()
            // Leaving the room stops what it was reading aloud.
            reader.stop()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: coordinator.resume()
            case .background: coordinator.pause()
            default: break
            }
        }
    }

    /// A link that opened this room may also name a ticket or the agent requests: open those once, over the room.
    private func applyRouteLinksOnce() {
        guard !appliedRouteLinks else { return }
        appliedRouteLinks = true
        if let ticketId = route.focusTicketId, ticketsTransport != nil {
            linkedTicket = LinkedTicket(id: ticketId)
        } else if route.opensAdmissions, decidesAdmissions {
            showsAdmissions = true
        }
    }

    /// Downloads the file and shows it full size; one open at a time.
    private func openAttachment(_ attachmentId: String) {
        guard !openingAttachment else { return }
        openingAttachment = true
        Task {
            defer { openingAttachment = false }
            do {
                attachmentPreview = AttachmentPreviewItem(url: try await coordinator.prepareAttachment(attachmentId))
            } catch AttachmentFetchError.tooLarge {
                attachmentProblem = "This file is too large to open on the phone."
            } catch let error as SessionTransportError where error == .accessDenied {
                attachmentProblem = "You no longer have access to this file."
            } catch {
                attachmentProblem = "Check your connection and try again. If it keeps failing, the file may still be processing."
            }
        }
    }

    /// Closes whatever covers the chat, then brings the message into view.
    private func focus(on sequence: Int64) {
        linkedTicket = nil
        showsTickets = false
        showsAdmissions = false
        coordinator.focus(on: sequence)
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch RoomLinkRouter.action(for: url, inRoom: route.sessionId) {
        case .focusMessage(let sequence):
            focus(on: sequence)
            return .handled
        case .openTicket(let ticketId):
            guard ticketsTransport != nil else { return .discarded }
            linkedTicket = LinkedTicket(id: ticketId)
            return .handled
        case .openAdmissions:
            guard decidesAdmissions else { return .discarded }
            linkedTicket = nil
            showsAdmissions = true
            return .handled
        case .openRoom(let link):
            openRoom(link)
            return .handled
        case .openInBrowser(let absolute):
            return .systemAction(absolute)
        case .ignore:
            return .discarded
        }
    }
}

/// The room's search in a sheet; choosing a match closes it and jumps there in the room.
private struct RoomSearchSheet: View {
    @StateObject private var model: RoomSearchModel
    private let onOpen: (Int64) -> Void

    init(
        sessionId: String,
        searcher: any RoomSearching,
        onReauthenticationRequired: @escaping @MainActor () -> Void,
        onOpen: @escaping (Int64) -> Void
    ) {
        _model = StateObject(wrappedValue: RoomSearchModel(
            sessionId: sessionId,
            searcher: searcher,
            onReauthenticationRequired: onReauthenticationRequired
        ))
        self.onOpen = onOpen
    }

    var body: some View {
        RoomSearchView(state: model.state) { intent in
            if case .open(let sequenceId) = intent {
                onOpen(sequenceId)
            } else {
                model.send(intent)
            }
        }
    }
}

/// Watches the voice room so its panel follows every change.
private struct VoiceRoomHost: View {
    @ObservedObject var room: VoiceRoomCoordinator

    var body: some View {
        VoiceRoomPanel(state: room.state, send: room.send)
    }
}
