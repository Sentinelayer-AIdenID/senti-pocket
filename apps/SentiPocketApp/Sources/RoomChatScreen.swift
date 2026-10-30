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
    /// The room's artifacts (PRs, tickets, files, links, code), read on their own when the panel opens.
    @StateObject private var artifacts: RoomArtifactsCoordinator
    @State private var showsArtifacts = false
    /// A voice conversation in this room, while one is open.
    @State private var voiceRoom: VoiceRoomCoordinator?
    @State private var choosesVoicePartner = false
    @Environment(\.openURL) private var openExternalURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsTickets = false
    /// The room's summary, made on request (Carter, 10-30).
    @State private var showsSummary = false
    @State private var showsInvite = false
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
    /// The times the app closed unexpectedly, offered once each to send to this room.
    @ObservedObject private var crashes = CrashReporter.shared
    @ObservedObject private var readingSource = ReadAloudSource.shared
    @State private var offersCrashReports = false
    /// A box's console, shown in the app.
    @State private var consolePage: InAppPage?
    /// Starting agents for tickets (the mint admits only some accounts; the tickets screen asks once). The mint is
    /// the build's `SENTI_MINT_URL`; a build without one offers no agents.
    private let ticketMint = HTTPMintClient(
        baseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_MINT_URL"]),
        // No cache and no cookie store for a request that carries the person's token.
        urlSession: SentiHTTPTransportPolicy.protectedReadSession,
        tokenProvider: { SessionTokenStore.load() }
    )
    /// Agents' calls answered on the call screen; the one this room's voice room is for.
    @ObservedObject private var callDesk = RoomCallDesk.shared
    @State private var answeredCall: RoomCallDesk.Call?
    private let route: RoomRoute
    private let ticketsTransport: (any RoomTicketsTransport)?
    private let admissionsTransport: (any RoomAdmissionsTransport)?
    private let admissionDecider: (any AdmissionDeciding)?
    private let ticketAnswerSender: (any RoomMessageSending)?
    /// Posting spoken turns and the transcript, as you; nil where you cannot post.
    private let voicePoster: (any VoiceRoomPosting)?
    private let summaryGenerator: (any RoomSummaryGenerating)?
    private let inviter: (any RoomInviting)?
    private let ticketWriter: (any RoomTicketWriting)?
    private let ticketLeases: any TicketLeaseStoring
    private let ticketExtras: (any RoomTicketExtrasReading)?
    private let identity: (any AccountIdentityProviding)?
    private let search: (any RoomSearching)?
    private let openRoom: @MainActor (SentiLink) -> Void
    private let openChildRoom: @MainActor (RoomRoute) -> Void
    private let onReauthenticationRequired: @MainActor () -> Void
    /// The room was renamed here: the room list reads the new name.
    private let onRenamed: @MainActor () -> Void

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
        onRenamed: @escaping @MainActor () -> Void = {},
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
        self.summaryGenerator = sender as? any RoomSummaryGenerating
        self.inviter = sender as? any RoomInviting
        self.ticketWriter = ticketWriter
        self.ticketLeases = ticketLeases
        self.ticketExtras = ticketExtras
        self.identity = identity
        self.openRoom = openRoom
        self.openChildRoom = openChildRoom
        self.onRenamed = onRenamed
        self.onReauthenticationRequired = onReauthenticationRequired
        _coordinator = StateObject(wrappedValue: RoomChatCoordinator(
            sessionId: route.sessionId,
            title: route.title,
            transport: transport,
            sender: sender,
            actionSender: actionSender,
            identity: identity,
            membershipRole: route.membershipRole,
            // The API lets the owner rename a room, and nobody a breakout.
            canRename: route.membershipRole.lowercased() == "owner" && !route.isBreakout,
            // Owners and admins invite people (the API enforces it); a breakout follows its parent room.
            canInvite: ["owner", "admin"].contains(route.membershipRole.lowercased()) && !route.isBreakout,
            // Thread summaries are written on the phone, where Apple's on-device model is available.
            summarizer: OnDeviceThreadSummarizer(),
            focusSequenceId: route.focusSequenceId,
            attachmentFetcher: attachmentFetcher,
            receipts: receipts,
            directory: ticketExtras,
            onReauthenticationRequired: onReauthenticationRequired
        ))
        _artifacts = StateObject(wrappedValue: RoomArtifactsCoordinator(sessionId: route.sessionId, transport: transport))
        _flight = StateObject(wrappedValue: FlightRecordCoordinator(
            sessionId: route.sessionId,
            mint: HTTPMintClient(
                baseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_MINT_URL"]),
                // No cache and no cookie store for a request that carries the person's token.
                urlSession: SentiHTTPTransportPolicy.protectedReadSession,
                tokenProvider: { SessionTokenStore.load() }
            )
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

    /// Everyone the search can find: who is here, then everyone who wrote in what is loaded, people and agents.
    private var searchPeople: [RoomSearchPerson] {
        var people: [RoomSearchPerson] = []
        var seen = Set<String>()
        for person in coordinator.state.presence?.people ?? [] where seen.insert(person.id.lowercased()).inserted {
            people.append(RoomSearchPerson(authorId: person.id, name: person.isHuman ? String(person.id.dropFirst("human-".count)) : person.id,
                                           isHuman: person.isHuman))
        }
        for row in coordinator.state.rows.reversed() {
            guard case .message(let message) = row, !message.authorId.isEmpty,
                  seen.insert(message.authorId.lowercased()).inserted else { continue }
            people.append(RoomSearchPerson(authorId: message.authorId, name: message.authorName, isHuman: message.isHuman))
        }
        return people
    }

    /// Whom you can talk with (Carter, #55061): the agents here now, then those heard from within the hour, then the
    /// boxes still running. A box that ended, or an agent long gone, is not offered.
    private var voicePartners: [String] {
        var posts: [VoiceCallRoster.Post] = []
        var endedBoxes = flight.state.endedBoxNames
        for row in coordinator.state.rows.reversed() {
            guard case .message(let message) = row else { continue }
            if let box = message.box, box.isEnded { endedBoxes.insert(box.launch.name.lowercased()) }
            if !message.isHuman { posts.append(VoiceCallRoster.Post(authorId: message.authorId, at: message.date)) }
        }
        return VoiceCallRoster.partners(
            present: (coordinator.state.presence?.people ?? []).filter { !$0.isHuman }.map(\.id),
            posts: posts,
            runningBoxes: flight.state.boxes.map(\.name),
            endedBoxes: endedBoxes,
            now: Date()
        )
    }

    /// The message being read, brought into view (Carter, #55229); a reply opens its thread.
    private func showReadingMessage() {
        guard let id = reader.readingId else { return }
        if id.hasPrefix("msg:"), let sequence = Int64(id.dropFirst("msg:".count)) {
            coordinator.send(.jumpToMessage(sequenceId: sequence))
        } else if id.hasPrefix("reply:") {
            let replyId = String(id.dropFirst("reply:".count))
            let shown = coordinator.state.rows.lazy.compactMap { row -> Int64? in
                if case .message(let message) = row, message.inlineReplyId == replyId { return message.sequenceId }
                return nil
            }.first
            if let parent = shown ?? coordinator.state.thread?.parent.sequenceId {
                coordinator.send(.openThread(sequenceId: parent))
            }
        } else if let thread = RoomReadAloud.summaryThread(id) {
            // A thread's summary: its thread (warden, #257).
            coordinator.send(.openThread(sequenceId: thread))
        }
    }

    /// Everyone who came (Carter, 10-30): who posted and when, who is here now, and the boxes the Flight record knows.
    private var roster: RoomRoster {
        var posts: [RoomRoster.Post] = []
        for row in coordinator.state.rows {
            guard case .message(let message) = row else { continue }
            posts.append(RoomRoster.Post(authorId: message.authorId, name: message.authorName, isHuman: message.isHuman,
                                         at: message.date))
        }
        let boxes = flight.state.boxes.map {
            RoomRoster.Box(name: $0.name, model: $0.model, phase: $0.phase, job: $0.job, lastActivity: $0.lastActivity,
                           expiresAt: $0.expiresAt)
        }
        return RoomRoster.build(posts: posts, present: coordinator.state.presence?.people ?? [], runningBoxes: boxes,
                                endedBoxes: flight.state.endedBoxNames, now: Date())
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
        if id.hasPrefix("summary:") { return "Thread summary" }
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
        CrashReporter.shared.note(agents.isEmpty ? "voice meeting began" : "voice call began")
        room.begin()
    }

    private func endVoiceRoom() {
        CrashReporter.shared.note("voice room ended")
        coordinator.onLiveMessages = nil
        coordinator.onNewReplies = nil
        coordinator.readsRepliesOften = false
        voiceRoom = nil
        if let answeredCall {
            RoomCallDesk.shared.voiceRoomEnded(answeredCall)
            self.answeredCall = nil
        }
    }

    /// An agent's call answered on the call screen: once this room is on screen with the app in front, the system
    /// call ends (freeing its audio) and the voice room starts with the caller.
    private func takeAnsweredCall() {
        guard UIApplication.shared.applicationState == .active, voiceRoom == nil, voicePoster != nil,
              let call = callDesk.takeWaiting(for: route.sessionId) else { return }
        answeredCall = call
        CrashReporter.shared.note("call answered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { startVoiceRoom(with: [call.partner]) }
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
            ),
            roster: roster
        ) { intent in
            CrashReporter.shared.note(intent, rows: coordinator.state.rows.count)
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
                ReadAloudSource.shared.reading(in: route.sessionId)
                if reader.read(id: id, markdown: text, title: readAloudTitle(for: id)) == .unavailable {
                    listenProblem = "A call or briefing is using the audio. Listen when it ends."
                }
            } else if intent == .stopReadingAloud {
                reader.stop()
            } else if intent == .openInvite {
                showsInvite = true
            } else if intent == .peopleOpened {
                // Which boxes still run, so the people list shows them as here or ended.
                Task { await flight.refresh() }
            } else {
                coordinator.send(intent)
            }
        }
        .toolbar {
            if voicePoster != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        choosesVoicePartner = true
                        // Which boxes still run, so the picker offers no box that ended.
                        Task { await flight.refresh() }
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
                    CrashReporter.shared.note("flight record opened")
                    flight.setAgents(flightAgents)
                    flight.setPeople(roster.members)
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
            if summaryGenerator != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsSummary = true
                    } label: {
                        Label("Summarize this room", systemImage: "text.badge.star")
                    }
                    .accessibilityIdentifier("pocket.room.summary.open")
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
                        // The console opens in the app (Carter, #55006); anything not https goes nowhere.
                        onOpenConsole: { url in
                            CrashReporter.shared.note("console opened")
                            consolePage = InAppPage(url: url)
                        }
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
        .overlay {
            if showsArtifacts {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { showsArtifacts = false }
                        .accessibilityLabel("Close artifacts")
                        .accessibilityAddTraits(.isButton)
                    RoomArtifactsPanel(
                        artifacts: artifacts.artifacts,
                        isLoading: artifacts.isLoading,
                        messagesRead: artifacts.messagesRead,
                        onClose: { showsArtifacts = false },
                        onOpenMessage: { sequence in
                            showsArtifacts = false
                            focus(on: sequence)
                        },
                        onOpen: { url in
                            showsArtifacts = false
                            // Senti links (a ticket, a message) stay in the app; anything else opens in the browser.
                            if case .openInBrowser(let absolute) = RoomLinkRouter.action(for: url, inRoom: route.sessionId) {
                                openExternalURL(absolute)
                            } else {
                                _ = handle(url)
                            }
                        }
                    )
                    .frame(maxWidth: 380)
                    .padding(.leading, 40)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                        if value.translation.width > 60 { showsArtifacts = false }
                    })
                    .transition(.move(edge: .trailing))
                }
                .onDisappear { artifacts.close() }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showsArtifacts)
        .overlay(alignment: .bottom) {
            if let voiceRoom {
                VoiceRoomHost(room: voiceRoom)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: voiceRoom != nil)
        .overlay(alignment: .bottom) {
            // The Listen player: above the composer while this room's message is read (a voice room speaks on its
            // own). Reading from another room, the app's own player shows instead, over every screen.
            if voiceRoom == nil, let playback = reader.playback,
               readingSource.sessionId == nil || readingSource.sessionId == route.sessionId {
                ReadAloudPlayer(reader: reader, playback: playback, onShowMessage: showReadingMessage)
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
            Text("You talk; they answer in the room and the phone reads each answer in that agent's voice. The whole conversation stays in the room as the call's card.")
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
            if showsFlight {
                flight.setAgents(flightAgents)
                flight.setPeople(roster.members)
            }
        }
        // Agent requests, Tickets and Breakouts open as sheets over the room, never pushed onto its navigation. Pushed
        // from the toolbar's overflow, Tickets froze the app in an endless layout pass on iOS 26 until the system
        // ended it (Carter's crash report, 10-30; reproduced on the simulator, and gone as a sheet): the room kept
        // re-rendering under the pushed screen and rebuilt it, and its search bar changed the room's layout again.
        .sheet(isPresented: $showsAdmissions) {
            if let admissionsTransport, let admissionDecider {
                NavigationStack {
                    AdmissionsScreen(
                        sessionId: route.sessionId,
                        transport: admissionsTransport,
                        decider: admissionDecider,
                        onReauthenticationRequired: onReauthenticationRequired
                    )
                    .toolbar { doneButton { showsAdmissions = false } }
                }
                .environment(\.openURL, linkAction)
            }
        }
        .onChange(of: showsTickets) { shown in
            if shown {
                CrashReporter.shared.note("tickets opened")
            } else {
                ticketsStartFiling = false
            }
        }
        .onChange(of: showsAdmissions) { shown in if shown { CrashReporter.shared.note("agent requests opened") } }
        .onChange(of: showsBreakouts) { shown in if shown { CrashReporter.shared.note("breakouts opened") } }
        .onChange(of: choosesVoicePartner) { shown in if shown { CrashReporter.shared.note("talk opened") } }
        .sheet(isPresented: $showsSummary) {
            if let summaryGenerator {
                RoomSummarySheet(sessionId: route.sessionId, roomTitle: coordinator.state.title, generator: summaryGenerator,
                                 reader: reader, onClose: { showsSummary = false },
                                 onReport: coordinator.state.composer.canPost ? { coordinator.send(.sendMessage(text: $0)) } : nil)
            }
        }
        .onChange(of: showsSummary) { open in
            if open { CrashReporter.shared.note("summary opened") }
        }
        .onChange(of: coordinator.state.title) { _ in onRenamed() }
        .sheet(isPresented: $showsInvite) {
            if let inviter {
                RoomInviteSheet(sessionId: route.sessionId, roomTitle: coordinator.state.title, inviter: inviter,
                                onClose: { showsInvite = false })
            }
        }
        .sheet(isPresented: $showsTickets) {
            if let ticketsTransport {
                NavigationStack {
                    RoomTicketsScreen(
                        sessionId: route.sessionId,
                        transport: ticketsTransport,
                        sender: ticketAnswerSender,
                        writer: writesTickets ? ticketWriter : nil,
                        leases: ticketLeases,
                        identity: identity,
                        assignRoster: ticketAssignRoster,
                        extras: ticketExtras,
                        mint: writesTickets ? ticketMint : nil,
                        startsFiling: ticketsStartFiling,
                        onOpenMessage: { sequence in
                            // The sheet closes first, then the room goes to the message.
                            showsTickets = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focus(on: sequence) }
                        },
                        onReauthenticationRequired: onReauthenticationRequired
                    )
                    .toolbar { doneButton { showsTickets = false } }
                }
                .environment(\.openURL, linkAction)
            }
        }
        .sheet(isPresented: $showsBreakouts) {
            NavigationStack {
                RoomBreakoutsView(cards: Array(coordinator.state.breakouts.values)) { childSessionId in
                    showsBreakouts = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openBreakout(childSessionId) }
                }
                .toolbar { doneButton { showsBreakouts = false } }
            }
        }
        // Room-wide actions sit under the room's title, so the toolbar keeps its width.
        .toolbarTitleMenu {
            Button {
                CrashReporter.shared.note("artifacts opened")
                showsArtifacts = true
                artifacts.open()
            } label: {
                Label("Artifacts", systemImage: "square.stack.3d.up")
            }
            if search != nil {
                Button {
                    showsSearch = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showsSearch) {
            if let search {
                RoomSearchSheet(
                    sessionId: route.sessionId,
                    searcher: search,
                    artifacts: artifacts,
                    people: { searchPeople },
                    onReauthenticationRequired: onReauthenticationRequired,
                    onOpen: { sequenceId in coordinator.focus(on: sequenceId) },
                    // A ticket opens over the room once the search has closed; other links follow the room's rules.
                    onOpenURL: { url in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { _ = handle(url) }
                    }
                )
            }
        }
        .sheet(item: $attachmentPreview) { item in
            AttachmentQuickLook(url: item.url)
                .ignoresSafeArea()
        }
        .sheet(item: $consolePage) { page in
            SafariSheet(url: page.url)
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
        .alert("Pocket closed unexpectedly", isPresented: $offersCrashReports) {
            Button("Send to this room") {
                let reports = crashes.unhandled
                coordinator.send(.sendMessage(text: CrashReportText.message(reports)))
                crashes.markHandled(reports)
            }
            Button("Not now", role: .cancel) { crashes.markHandled(crashes.unhandled) }
        } message: {
            Text("Send what the phone recorded to this room so it can be fixed? It has where the app stopped and your last few taps, never your messages.")
        }
        .task {
            // A moment after the room opens, so iOS can hand over its own crash records first and both go together.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            offerCrashReports()
        }
        .onChange(of: crashes.unhandled.count) { _ in offerCrashReports() }
        .onChange(of: coordinator.state.composer.canPost) { _ in offerCrashReports() }
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
                    mint: writesTickets ? ticketMint : nil,
                    onOpenMessage: { sequence in focus(on: sequence) },
                    onReauthenticationRequired: onReauthenticationRequired
                )
                .environment(\.openURL, linkAction)
            }
        }
        .environment(\.openURL, linkAction)
        .onAppear {
            CrashReporter.shared.note("room opened")
            coordinator.resume()
            applyRouteLinksOnce()
            takeAnsweredCall()
        }
        .onDisappear {
            CrashReporter.shared.note("room closed")
            coordinator.pause()
            // Reading aloud goes on after you leave (Carter, 10-30); the app's player follows you to the next screen.
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                coordinator.resume()
                takeAnsweredCall()
            case .background: coordinator.pause()
            default: break
            }
        }
        .onReceive(callDesk.$waiting) { _ in takeAnsweredCall() }
    }

    /// Done, on a screen shown as a sheet over the room.
    private func doneButton(_ close: @escaping () -> Void) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: close)
        }
    }

    /// Offers the unsent crash reports where they can be posted: in a room you can write in, with nothing else asked.
    private func offerCrashReports() {
        guard !crashes.unhandled.isEmpty, coordinator.state.composer.canPost, voiceRoom == nil else { return }
        offersCrashReports = true
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

    /// A link tapped inside the thread sheet: the sheet closes first, then the ticket or message opens over the room
    /// (Carter: a ticket from a thread did nothing until he left the thread; the room cannot show a second sheet).
    private func afterClosingThread(_ open: @escaping () -> Void) {
        guard coordinator.state.thread != nil else {
            open()
            return
        }
        coordinator.send(.closeThread)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open() }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch RoomLinkRouter.action(for: url, inRoom: route.sessionId) {
        case .focusMessage(let sequence):
            afterClosingThread { focus(on: sequence) }
            return .handled
        case .openTicket(let ticketId):
            guard ticketsTransport != nil else { return .discarded }
            afterClosingThread { linkedTicket = LinkedTicket(id: ticketId) }
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
    /// The room's shared things, read when the search opens (and kept for a minute).
    @ObservedObject private var artifacts: RoomArtifactsCoordinator
    private let onOpen: (Int64) -> Void
    private let onOpenURL: (URL) -> Void

    init(
        sessionId: String,
        searcher: any RoomSearching,
        artifacts: RoomArtifactsCoordinator,
        people: @escaping @MainActor () -> [RoomSearchPerson],
        onReauthenticationRequired: @escaping @MainActor () -> Void,
        onOpen: @escaping (Int64) -> Void,
        onOpenURL: @escaping (URL) -> Void
    ) {
        _model = StateObject(wrappedValue: RoomSearchModel(
            sessionId: sessionId,
            searcher: searcher,
            people: people,
            artifacts: { [weak artifacts] in (artifacts?.artifacts ?? [], artifacts?.isLoading ?? false) },
            onReauthenticationRequired: onReauthenticationRequired
        ))
        _artifacts = ObservedObject(wrappedValue: artifacts)
        self.onOpen = onOpen
        self.onOpenURL = onOpenURL
    }

    var body: some View {
        RoomSearchView(state: model.state) { intent in
            switch intent {
            case .open(let sequenceId):
                onOpen(sequenceId)
            case .openArtifact(let artifact):
                // A ticket opens over the room; anything else goes to the message that shared it.
                if artifact.kind == .ticket, let url = artifact.url {
                    onOpenURL(url)
                } else {
                    onOpen(artifact.sequenceId)
                }
            default:
                model.send(intent)
            }
        }
        .onAppear { artifacts.open() }
        .onChange(of: artifacts.artifacts.count) { _ in model.sourcesChanged() }
        .onChange(of: artifacts.isLoading) { _ in model.sourcesChanged() }
    }
}

/// Watches the voice room so its panel follows every change.
private struct VoiceRoomHost: View {
    @ObservedObject var room: VoiceRoomCoordinator

    var body: some View {
        VoiceRoomPanel(state: room.state, send: room.send)
    }
}
