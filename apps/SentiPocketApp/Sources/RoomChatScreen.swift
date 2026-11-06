import SwiftUI
import UIKit
import PocketSyncClient
import PocketUI
import PocketVoice

/// When the room's running boxes are read again: with the room in sight and the app in front.
struct RoomBoxPoll: Equatable {
    let covered: Bool
    let active: Bool
    var runs: Bool { !covered && active }

    /// How often, in nanoseconds.
    static let interval: UInt64 = 60_000_000_000
}

/// Whether the app covers the room (the side panel, or a sheet over it), read here and only here: the room's coordinator
/// keeps what arrives unshown while it is covered, and the room's boxes are read again only while it can be seen and the
/// app is in front. The room's screen never reads it, so it and its rows draw nothing when the side panel opens.
struct RoomCoverWatch: ViewModifier {
    let coversItself: Bool
    let coordinator: RoomChatCoordinator
    let flight: FlightRecordCoordinator
    @Environment(\.roomIsCovered) private var coveredFromOutside
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let poll = RoomBoxPoll(covered: coveredFromOutside || coversItself, active: scenePhase == .active)
        return content
            .onAppear { coordinator.isCovered = coveredFromOutside }
            .onChange(of: coveredFromOutside) { covered in coordinator.isCovered = covered }
            // The room's running boxes, for the ring and its count (their names only), kept fresh while the room can be
            // seen (#269) and the app is in front.
            .task(id: poll) {
                guard poll.runs else { return }
                while !Task.isCancelled {
                    await flight.refreshBoxes()
                    try? await Task.sleep(nanoseconds: RoomBoxPoll.interval)
                }
            }
    }
}

/// Navigation value for an open room.
struct RoomRoute: Hashable {
    let sessionId: String
    let title: String
    /// owner, admin, contributor or viewer. A viewer can read but not post.
    var membershipRole: String = ""
    /// A message to open the room at (from a notification or link).
    var focusSequenceId: Int64?
    /// A reply in that message's thread to open the thread at (a reply notification's `?reply=`).
    var focusReplyId: String?
    /// A ticket to open over the room (a link's `?ticket=`, like the web's ticket drawer).
    var focusTicketId: String?
    /// Opens the room's agent requests (a link's `?admission=`), for owners and admins.
    var opensAdmissions = false
    /// A breakout's own room: no agent requests or tickets of its own in v1-a.
    var isBreakout = false
    /// What the room list knew about your reading when the room was opened from it: the room opens at your first
    /// unread message.
    var readMark: RoomReadMark?
    /// A direct message: whom it is with and the room it started from. Nil for a room.
    var direct: DirectRoomInfo?
}

extension RoomRoute {
    /// The controls that change who is in a room or what it is: New agent, Invite, Rename and agent requests. A room's
    /// alone: a breakout follows its parent, and a direct message has none (the API refuses them in a direct room).
    var hasRoomControls: Bool { !isBreakout && direct == nil }

    /// The owner renames a room (the API's rule).
    var canRename: Bool { hasRoomControls && membershipRole.lowercased() == "owner" }

    /// Owners and admins invite people (the API enforces it).
    var canInvite: Bool { hasRoomControls && ["owner", "admin"].contains(membershipRole.lowercased()) }

    /// A profile card offers Message from a room, never from inside a direct message: the server would be sent the
    /// direct message itself as the room you share.
    var cardsOfferMessage: Bool { direct == nil }

    /// The room already open, asked for again with nothing new (picked again in the side panel), stays as it is,
    /// where you are in it: an unread count the room list made before you read it there never reopens it at an old
    /// unread line. Anything else opens as asked.
    static func keepingOpenRoom(_ current: RoomRoute?, for route: RoomRoute) -> RoomRoute {
        guard let current else { return route }
        var same = route
        same.readMark = current.readMark
        return same == current ? current : route
    }
}

extension RoomReadMark {
    /// What the room list knows about your reading of a room, for opening it at your first unread message.
    init(row: SessionRowPresentation) {
        self.init(
            unreadCount: row.activity.unread,
            firstUnreadSequenceId: row.firstUnreadSequenceId,
            lastReadSequenceId: row.lastReadSequenceId
        )
    }
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
    /// The call's waveform: your microphone and the agent's words.
    @State private var voiceMeter = VoiceLevelMeter()
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
    /// Photos, videos and files sent from this phone: picked, uploaded with progress, and posted as one message.
    @StateObject private var media: RoomMediaUploadCoordinator
    /// A photo or video opened full screen, and a file being shared.
    @State private var mediaViewer: RoomMediaViewerItem?
    @State private var shareItem: RoomShareItem?
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
    /// Starting agents, for tickets and from New agent (the mint admits only some accounts; the tickets screen and the
    /// New agent button each ask once). The mint is the build's `SENTI_MINT_URL`; a build without one offers no agents.
    private let agentMint: any MintStarting
    /// Whether this room shows New agent: to its owners and admins, once the mint admits the account.
    @StateObject private var newAgentOffer: NewAgentOffer
    @State private var showsNewAgent = false
    /// Makes the new chat a New agent can start in.
    private let chatCreator: (any AgentChatCreating)?
    /// Opens a chat made here as the room on screen.
    private let openNewRoom: @MainActor (RoomRoute) -> Void
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
    /// The room's saved summary as the room list has it: what a member who isn't the owner reads.
    private let savedSummary: String?
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
    /// This account's OK for what it shares to reach the room's AI agents. The room's box and threads ask in place;
    /// a call, a ticket's answer and a crash report ask here.
    private let aiConsent: AIConsent?
    /// What waits on that answer.
    @State private var consentHeld: AIConsentHeld?
    /// A problem report from the summary sheet, waiting on that answer there.
    @State private var summaryConsentHeld: AIConsentHeld?
    /// Who this account blocked, for room search.
    private let blocks: BlockList?
    /// Direct messages, where they are on: avatars open profile cards, and a direct message gets its switch.
    private let directContext: RoomDirectContext?
    /// The profile open over the room.
    @State private var profileTarget: RoomProfileTarget?
    /// Block, asked from a profile card once the card has gone.
    @State private var blockingFromCard: RoomBlockTarget?
    /// Someone's messages in the room, for their profile (`GET /events/by-author`).
    private let authorMessages: (any RoomAuthorMessagesReading)?
    /// The rooms you share with someone, for their card.
    private let sharedRooms: (any SharedRoomsReading)?

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
        openNewRoom: @escaping @MainActor (RoomRoute) -> Void = { _ in },
        mint: (any MintStarting)? = nil,
        attachmentFetcher: any AttachmentFileFetching = URLSessionAttachmentFetcher(),
        receipts: (any RoomReceiptsClient)? = nil,
        search: (any RoomSearching)? = nil,
        readMarker: (any RoomReadMarking)? = nil,
        reader: MessageReader,
        onRenamed: @escaping @MainActor () -> Void = {},
        savedSummary: String? = nil,
        onRead: @escaping @MainActor (_ sessionId: String, _ through: Int64, _ caughtUp: Bool) -> Void = { _, _, _ in },
        blocks: BlockList? = nil,
        aiConsent: AIConsent? = nil,
        direct: RoomDirectContext? = nil,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        #if DEBUG
        RootPreview.meter.roomScreenMade()
        #endif
        self.route = route
        self.aiConsent = aiConsent
        self.blocks = blocks
        self.directContext = direct
        self.authorMessages = transport as? any RoomAuthorMessagesReading
        self.sharedRooms = transport as? any SharedRoomsReading
        self.reader = reader
        self.search = search
        self.ticketsTransport = ticketsTransport
        self.admissionsTransport = admissionsTransport
        self.admissionDecider = admissionDecider
        // A viewer cannot post, so cannot answer a ticket's decision either.
        self.ticketAnswerSender = route.membershipRole.lowercased() == "viewer" ? nil : sender
        self.voicePoster = route.membershipRole.lowercased() == "viewer" ? nil : sender as? any VoiceRoomPosting
        self.summaryGenerator = sender as? any RoomSummaryGenerating
        self.savedSummary = savedSummary
        self.inviter = sender as? any RoomInviting
        self.ticketWriter = ticketWriter
        self.ticketLeases = ticketLeases
        self.ticketExtras = ticketExtras
        self.identity = identity
        self.openRoom = openRoom
        self.openChildRoom = openChildRoom
        self.openNewRoom = openNewRoom
        let agentMint = mint ?? HTTPMintClient(
            baseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_MINT_URL"]),
            // No cache and no cookie store for a request that carries the person's token.
            urlSession: SentiHTTPTransportPolicy.protectedReadSession,
            tokenProvider: { SessionTokenStore.load() }
        )
        self.agentMint = agentMint
        _newAgentOffer = StateObject(wrappedValue: NewAgentOffer(role: route.membershipRole, isBreakout: route.isBreakout,
                                                                 isDirect: route.direct != nil, mint: agentMint))
        self.chatCreator = sender as? any AgentChatCreating
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
            // The API lets the owner rename a room, and nobody a breakout or a direct message.
            canRename: route.canRename,
            // Owners and admins invite people (the API enforces it); a breakout follows its parent room, and a direct
            // message is between two.
            canInvite: route.canInvite,
            // Thread summaries are written on the phone, where Apple's on-device model is available.
            summarizer: OnDeviceThreadSummarizer(),
            focusSequenceId: route.focusSequenceId,
            attachmentFetcher: attachmentFetcher,
            receipts: receipts,
            directory: ticketExtras,
            readMark: route.readMark,
            readMarker: readMarker,
            onRead: { [sessionId = route.sessionId] sequence, caughtUp in onRead(sessionId, sequence, caughtUp) },
            // A send cut off by a kill comes back after a relaunch under its own client id.
            outbox: .standard,
            outboxAccount: RoomSendOutbox.account(token: SessionTokenStore.load()),
            // Off unless this build turns them on (the `SentiEmojiReactions` Info.plist key).
            emojiReactions: RoomEmojiReactions.isEnabled,
            // Report and Block (App Store guideline 1.2): reports go through the room's own sender, as you.
            reporter: sender as? any RoomReporting,
            blocks: blocks,
            aiConsent: aiConsent,
            onReauthenticationRequired: onReauthenticationRequired
        ))
        // Files go up through the room's own sender (init, complete, the message) and straight to storage for the
        // bytes. A viewer cannot post, so has nothing to send them with.
        // Bound to the account signed in now: its files are kept under it, and their uploads carry only its token, so
        // another account signing in here never sees or posts them (warden, #298 review).
        let account = RoomSendOutbox.account(token: SessionTokenStore.load())
        var mediaUploader: (any RoomMediaUploading)? = route.membershipRole.lowercased() == "viewer"
            ? nil
            : (sender as? HTTPRoomMessageSender).map { HTTPRoomMediaUploader(api: $0.bound(toAccount: account)) }
        #if DEBUG
        if RoomPreview.isComposerTrayRequested { mediaUploader = RoomPreviewUploader() }
        #endif
        _media = StateObject(wrappedValue: RoomMediaUploadCoordinator.forRoom(route.sessionId, account: account,
                                                                              uploader: mediaUploader,
                                                                              aiConsent: aiConsent) {
            RoomMediaUploadCoordinator(
                sessionId: route.sessionId,
                account: account,
                uploader: mediaUploader,
                canUseCamera: UIImagePickerController.isSourceTypeAvailable(.camera),
                canPaste: { UIPasteboard.general.hasImages },
                aiConsent: aiConsent
            )
        })
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

    /// `answering` is the agent's call you picked up, if this is one: it does not ring, and its reason and brief
    /// ground the quick answers.
    private func startVoiceRoom(with agents: [String], answering call: RoomCallDesk.Call? = nil) {
        guard voiceRoom == nil, let voicePoster else { return }
        reader.stop()
        let handles = coordinator.state.ownMentionHandles.filter { $0 != "all" }.sorted()
        let meter = voiceMeter
        meter.reset()
        let listener = OnDeviceVoiceListener()
        let heard = HeardLevel()
        listener.onLevel = { level in
            meter.hear(level, from: .you)
            heard.room?.hear(level: level)
        }
        let speaker = AgentVoiceSpeaker()
        speaker.onWord = { length in meter.hear(VoiceLevelMeter.level(wordLength: length), from: .agent) }
        let room = VoiceRoomCoordinator(
            sessionId: route.sessionId,
            with: agents,
            invited: agents.isEmpty ? voicePartners : agents,
            you: handles.first ?? "you",
            ownAuthorIds: Set(handles.map { "human-\($0)" }),
            listener: listener,
            speaker: speaker,
            // An agent's call you answered talks inside the system call, whose audio CallKit owns.
            audio: call == nil ? PhoneVoiceRoomAudioSession() : CallKitVoiceRoomAudioSession(),
            ringer: RingbackTone(),
            // "Bring warden into this call": the same agents the Add button offers.
            addable: { voicePartners },
            // Its Mute is the call screen's.
            callScreen: call.map { RoomCallScreen(desk: .shared, uuid: $0.uuid) },
            poster: voicePoster,
            voiceLine: voicePoster as? any VoiceLining,
            endpointer: voicePoster as? any VoiceEndpointing,
            // A turn names the call only when the server said its voice line reads call briefs.
            ringCallId: call?.details?.briefsVoiceLine == true ? call?.doorbell.callId : nil,
            about: call?.details?.reason,
            // Asked before the call starts (`afterAIConsent`); without it the call posts nothing.
            mayShareWithAgents: { [aiConsent] in aiConsent?.isGiven ?? true },
            onEnded: { endVoiceRoom() },
            onRecordFailed: { [weak coordinator] failure in coordinator?.show(notice: failure) }
        )
        // The call fills the screen, over the room and its bars, until you hang up. Without its screen
        // there would be no way to hang up, so the call does not start, nothing of it is left wired, and you are told
        // (warden, #267).
        let host = VoiceRoomHost(room: room, meter: meter, partnerLab: partnerLab(of: room), addable: { voicePartners })
        guard VoiceCallWindow.shared.show(host) else {
            CrashReporter.shared.note("voice call refused: no call screen")
            if let answeredCall {
                RoomCallDesk.shared.voiceRoomEnded(answeredCall)
                self.answeredCall = nil
            }
            coordinator.show(notice: "The call screen could not open, so the call did not start. Try again.")
            return
        }
        coordinator.onLiveMessages = { [weak room] messages in room?.receive(messages) }
        coordinator.onNewReplies = { [weak room] replies in room?.receive(replies: replies) }
        coordinator.readsRepliesOften = true
        // Answered with Pocket in the background, the room was resting: the call needs it live.
        coordinator.resume()
        heard.room = room
        voiceRoom = room
        CrashReporter.shared.note(agents.isEmpty ? "voice meeting began" : "voice call began")
        // Muted on the call screen before this room took the call: it starts muted, as the call screen shows.
        if let call, callDesk.muted.contains(call.uuid) { room.callScreenMuted(true) }
        room.begin(rings: call == nil)
    }

    /// This room's own covers: its call, or a profile card. Whether the app covers it (a sheet or the side panel) is read
    /// only by `RoomCoverWatch`, so this screen and its rows never draw again when the side panel opens or closes.
    private var coversItself: Bool { voiceRoom != nil || profileTarget != nil }

    /// The called agent's lab as the room's presence reports it, for the call screen's logo; nil in a meeting.
    private func partnerLab(of room: VoiceRoomCoordinator) -> AgentLab? {
        guard room.state.with.count == 1, let partner = room.state.with.first else { return nil }
        let person = coordinator.state.presence?.people.first { $0.id.lowercased() == partner.lowercased() }
        return AgentLab.of(id: partner, model: nil, reported: person?.lab)
    }

    private func endVoiceRoom() {
        CrashReporter.shared.note("voice room ended")
        coordinator.onLiveMessages = nil
        coordinator.onNewReplies = nil
        coordinator.readsRepliesOften = false
        voiceRoom = nil
        VoiceCallWindow.shared.hide()
        voiceMeter.reset()
        // A call that ended in the background lets the room rest again.
        if scenePhase == .background { coordinator.pause() }
        if let answeredCall {
            RoomCallDesk.shared.voiceRoomEnded(answeredCall)
            self.answeredCall = nil
        }
    }

    /// An agent's call answered on the call screen: once this room has it and CallKit has given it audio, the voice
    /// room starts with the caller inside the system call, with Pocket in front or not.
    private func takeAnsweredCall() {
        guard voiceRoom == nil, voicePoster != nil, let call = callDesk.takeWaiting(for: route.sessionId),
              let partner = call.partner else { return }
        answeredCall = call
        CrashReporter.shared.note("call answered")
        // An agent's call answered before this account said OK: nothing is said to it until you do, and Not now ends
        // the call.
        afterAIConsent({
            guard RoomCallDesk.shared.isLive(call.uuid) else {
                answeredCall = nil
                return
            }
            startVoiceRoom(with: [partner], answering: call)
        }, onDecline: {
            RoomCallDesk.shared.voiceRoomEnded(call)
            answeredCall = nil
        })
    }

    /// Runs `action` once this account has said OK to sharing with AI (App Store guideline 5.1.2(i)), asking first if it
    /// has not, whatever the room. Asked `after` a moment when something else is leaving the screen (an alert).
    private func afterAIConsent(after: TimeInterval = 0, _ action: @escaping () -> Void,
                                onDecline: @escaping () -> Void = {}) {
        guard let aiConsent, aiConsent.asks else {
            action()
            return
        }
        let held = AIConsentHeld(action, onDecline: onDecline)
        if after > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { consentHeld = held }
        } else {
            consentHeld = held
        }
    }

    /// Contributors and above file and change tickets (the API's `min_role="contributor"`). An unknown role offers
    /// nothing: the API would decide, but a button it refuses is worse than none.
    private var writesTickets: Bool {
        ["owner", "admin", "contributor"].contains(route.membershipRole.lowercased())
    }

    /// Only the room's owner makes its summary (the API enforces it); every other member reads the saved one. A role
    /// not known yet leaves it to the server.
    private var makesSummary: Bool {
        let role = route.membershipRole.lowercased()
        return role == "owner" || role.isEmpty
    }

    /// Only owners and admins decide agent requests (the API enforces it; the screen follows it).
    private var decidesAdmissions: Bool {
        route.hasRoomControls && admissionsTransport != nil && admissionDecider != nil
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

    /// Every avatar and name opens its owner's profile and messages (Carter, 11-04: "tap anyone"), in the room, on the
    /// people ring and in the people list. Message is offered only where direct messages are on and reach them.
    private var profileOpener: RoomProfileOpener? {
        RoomProfileOpener.members(ownMentionHandles: coordinator.state.ownMentionHandles) { target in
            CrashReporter.shared.note("profile card opened")
            profileTarget = target
        }
    }

    /// Message on someone's card: where direct messages are on, from a room (never from inside a direct message), once
    /// the room knows who you are, and never to yourself or the room's own voices.
    private func profileOffersMessage(_ target: RoomProfileTarget) -> Bool {
        guard directContext != nil, route.cardsOfferMessage, let opener = profileOpener, !opener.ownAuthorIds.isEmpty else {
            return false
        }
        return RoomProfile.opens(senderId: target.senderId, ownAuthorIds: opener.ownAuthorIds)
    }

    /// Block on someone's card: where the app has blocks, once the room knows who you are, and never on yourself, the
    /// room's own voices or someone already blocked (`RoomMemberBlock.offers`).
    private func profileOffersBlock(_ target: RoomProfileTarget, alreadyBlocked: Bool) -> Bool {
        guard blocks != nil, let opener = profileOpener else { return false }
        return RoomMemberBlock.offers(senderId: target.senderId, ownAuthorIds: opener.ownAuthorIds,
                                      alreadyBlocked: alreadyBlocked)
    }

    /// The box an agent's profile is about, while it runs: its live steps come from the Flight record.
    private func profileBox(_ target: RoomProfileTarget) -> FlightRecordState.Box? {
        guard target.isAgent else { return nil }
        return flight.state.boxes.first { $0.name.lowercased() == target.senderId.lowercased() }
    }

    /// The room the card names as shared before the server lists them: this room, or in a direct message the room it
    /// started from.
    private var profileSharedRoom: String? {
        route.direct == nil ? coordinator.state.title : route.direct?.originTitle
    }

    /// The compact header's switch starts open: only in a DEBUG preview (`-PocketDMMemoryOpen`).
    private var directMemoryOpen: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-PocketDMMemoryOpen")
        #else
        return false
        #endif
    }

    var body: some View {
        #if DEBUG
        let _ = RootPreview.meter.roomScreenBodyRan()
        #endif
        RoomChatView(
            state: coordinator.state,
            readingAloudId: reader.readingId,
            composerActions: RoomComposerActions(
                canFileTicket: ticketsTransport != nil && writesTickets && !route.isBreakout,
                canSearch: search != nil
            ),
            roster: roster,
            media: media.canUpload && coordinator.state.composer.canPost ? media.board : nil
        ) { intent in
            if case .bottomFlapHeld(let rows, let longest) = intent {
                // The room's bottom marker flapped and the reader's place was held still:
                // one line for the freeze recorder, with what may have kept it moving, never what the room says.
                CrashReporter.shared.note("bottom marker flapped, held \(Int(RoomBottomSettle.holdTime)) s (\(rows) rows, "
                    + "longest message \(longest) chars, voice room \(voiceRoom == nil ? "off" : "on"))")
                return
            }
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
            } else if case .shareAttachment(let attachmentId) = intent {
                shareAttachment(attachmentId)
            } else if case .readAloud(let id, let text) = intent {
                ReadAloudSource.shared.reading(in: route.sessionId)
                if reader.read(id: id, markdown: text, title: readAloudTitle(for: id)) == .unavailable {
                    listenProblem = "A call or briefing is using the audio. Listen when it ends."
                }
            } else if intent == .stopReadingAloud {
                reader.stop()
            } else if intent == .openInvite {
                // An invite writes to the room too: the first write asks.
                afterAIConsent { showsInvite = true }
            } else if intent == .peopleOpened {
                // Which boxes still run, so the people list shows them as here or ended.
                Task { await flight.refresh() }
            } else {
                coordinator.send(intent)
            }
        }
        // A sheet, the side panel or a call's window covers the room: its moving parts (the presence ring) rest
        // underneath (#265, #269). The app's cover passes through as it is, read only by what rests.
        .transformEnvironment(\.roomIsCovered) { [coversItself] covered in covered = covered || coversItself }
        .environment(\.roomProfileOpener, profileOpener)
        // A thread opens its photos, files and pickers over itself.
        .environment(\.roomSheetMediaHost, RoomSheetMediaHost {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .modifier(mediaPresenters(isActive: true))
        })
        // A direct message: whom it is with, the room you share, and for an agent whether it may use this chat there.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let info = route.direct {
                DirectRoomHeaderHost(
                    info: info,
                    sessionId: route.sessionId,
                    center: directContext?.center,
                    memoryOpen: directMemoryOpen,
                    openRoom: { openRoom(SentiLink(sessionId: $0)) }
                )
            }
        }
        .sheet(item: $profileTarget) { target in
            let box = profileBox(target)
            let blocked = blocks?.isBlocked(target.senderId) == true
            RoomProfileSheet(
                target: target,
                roomId: route.sessionId,
                sharedRoom: profileSharedRoom,
                // Never to someone you blocked.
                canMessage: profileOffersMessage(target) && !blocked,
                context: directContext,
                sharedRooms: sharedRooms,
                messages: authorMessages,
                box: box,
                // Someone you blocked: their messages are not listed.
                isBlocked: blocked,
                // Block as from a message, with the one the card hands over (the newest of theirs), never by their id
                // alone; asked once the card has gone, so the question is never dropped.
                onBlock: profileOffersBlock(target, alreadyBlocked: blocked) ? { sequence in
                    profileTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        blockingFromCard = RoomBlockTarget(actorId: target.senderId, name: target.name,
                                                           sequenceId: sequence)
                    }
                } : nil,
                onOpenMessage: { sequence in
                    profileTarget = nil
                    // Once the sheet has gone, the room brings the message into view by its own focus path.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focus(on: sequence) }
                },
                onOpenFlight: box == nil ? nil : {
                    CrashReporter.shared.note("flight record opened")
                    flight.setAgents(flightAgents)
                    flight.setPeople(roster.members)
                    showsFlight = true
                    profileTarget = nil
                },
                onReauthenticationRequired: onReauthenticationRequired,
                onClose: { profileTarget = nil }
            )
            // An agent's profile reads the room's boxes, so a box shows its live steps; the steps of the one it is
            // about read often while it shows.
            .onAppear {
                guard target.isAgent else { return }
                flight.start()
                if let box { flight.expand(box.id) }
            }
            .onChange(of: box?.id) { id in flight.expand(id) }
            .onDisappear {
                guard target.isAgent, !showsFlight else { return }
                flight.expand(nil)
                flight.stop()
            }
        }
        .roomBlockConfirmation($blockingFromCard) { coordinator.send($0) }
        .toolbar {
            // New agent (Carter: "I don't think I see a new agent button on mobile, put that"), beside the title as on
            // the web, for owners and admins the mint admits. The first of the room's buttons: iOS keeps the title whole
            // and moves the buttons that do not fit into its More menu from the last one back, so this is the last to
            // go there, and is in that menu, by its name, under a title too long for any button.
            if newAgentOffer.isOffered {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // Starting an agent writes to the room: the first write asks.
                        afterAIConsent { showsNewAgent = true }
                    } label: {
                        Label("New agent", systemImage: "cpu")
                    }
                    .accessibilityHint("Starts an agent in this room or in a new chat")
                    .accessibilityIdentifier("pocket.room.newAgent")
                }
            }
            if voicePoster != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // A call shares what you say with the agents: the first one asks first.
                        afterAIConsent {
                            choosesVoicePartner = true
                            // Which boxes still run, so the picker offers no box that ended.
                            Task { await flight.refresh() }
                        }
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
            // The owner makes the room's summary; every other member reads the one it has.
            if summaryGenerator != nil, makesSummary || savedSummary != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showsSummary = true
                    } label: {
                        Label(makesSummary ? "Summarize this room" : "Room summary", systemImage: "text.badge.star")
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
        // Tick one agent or several, or call everyone as a meeting.
        .sheet(isPresented: $choosesVoicePartner) {
            VoiceCallPicker(partners: voicePartners, onCall: { agents in
                choosesVoicePartner = false
                startVoiceRoom(with: agents)
            }, onCancel: {
                choosesVoicePartner = false
            })
            .presentationDetents([.medium, .large])
        }
        .aiConsentPrompt($consentHeld) { coordinator.send(.allowAIAgents) }
        .onDisappear {
            if let voiceRoom { Task { await voiceRoom.hangUp() } }
            coordinator.onFeedback = nil
        }
        .onAppear {
            // A message with files asks its AI question here, as a text does.
            media.askAIConsent = { held in consentHeld = held }
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
                RoomSummarySheet(sessionId: route.sessionId, roomTitle: coordinator.state.title,
                                 generator: makesSummary ? summaryGenerator : nil, saved: savedSummary,
                                 reader: reader, onClose: { showsSummary = false },
                                 onReport: coordinator.state.composer.canPost ? { text in
                                     // Asked here, over the summary, before the report goes to the room.
                                     if aiConsent?.asks == true {
                                         summaryConsentHeld = AIConsentHeld { coordinator.send(.sendMessage(text: text)) }
                                     } else {
                                         coordinator.send(.sendMessage(text: text))
                                     }
                                 } : nil)
                .aiConsentPrompt($summaryConsentHeld) { coordinator.send(.allowAIAgents) }
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
                        mint: writesTickets ? agentMint : nil,
                        startsFiling: ticketsStartFiling,
                        aiConsent: aiConsent,
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
        .sheet(isPresented: $showsNewAgent) {
            NewAgentSheet(sessionId: route.sessionId, roomTitle: coordinator.state.title, mint: agentMint,
                          chats: chatCreator) { chat in
                // The sheet closes first, then the new chat opens in place of this room.
                showsNewAgent = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { openNewRoom(chat) }
            }
        }
        .onChange(of: showsNewAgent) { shown in if shown { CrashReporter.shared.note("new agent opened") } }
        .task { await newAgentOffer.check() }
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
                    isBlocked: { [blocks] in blocks?.isBlocked($0) ?? false },
                    onReauthenticationRequired: onReauthenticationRequired,
                    onOpen: { sequenceId in coordinator.focus(on: sequenceId) },
                    // A ticket opens over the room once the search has closed; other links follow the room's rules.
                    onOpenURL: { url in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { _ = handle(url) }
                    }
                )
            }
        }
        // Photos, videos and files opened from the room, and the pickers its composer opens; while a thread is open,
        // the thread presents them over itself instead (`roomSheetMediaHost`).
        .modifier(mediaPresenters(isActive: coordinator.state.thread == nil))
        .sheet(item: $consolePage) { page in
            SafariSheet(url: page.url)
                .ignoresSafeArea()
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
                CrashReporter.shared.note("crash report sent to the room")
                // Once the alert has gone, as a typed send waits a turn: the alert leaving and the new row are never
                // laid out in one update. Handled only once the room has it: a lost send offers it again next time.
                DispatchQueue.main.async {
                    // Posted to the room, so its agents read it too: the first send there asks first. Not now leaves
                    // the reports to be offered again.
                    afterAIConsent(after: 0.4) {
                        coordinator.sendCrashReport(CrashReportText.message(reports)) { crashes.markHandled(reports) }
                    }
                }
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
        #if DEBUG
        .task {
            if RoomPreview.isComposerTrayRequested, media.board.tray.isEmpty { media.add(RoomPreview.composerTraySources()) }
        }
        #endif
        // The mint's boxes for this room, as the Flight record reads them: the chat's own agent and the composer's hint.
        .onChange(of: [Set(flight.state.boxes.map(\.name)), flight.state.endedBoxNames]) { boxes in
            coordinator.setBoxes(running: boxes[0], ended: boxes[1])
        }
        .modifier(RoomCoverWatch(coversItself: coversItself, coordinator: coordinator, flight: flight))
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
                    mint: writesTickets ? agentMint : nil,
                    aiConsent: aiConsent,
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
            #if DEBUG
            if RoomPreview.isLeaderboardSheetRequested { coordinator.send(.openLeaderboard) }
            if RootPreview.isRequested {
                RootPreview.meter.watch("room", coordinator)
                RootPreview.meter.watch("roomFlight", flight)
            }
            #endif
            takeAnsweredCall()
            connectMedia()
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
                // Back in front: a mint that gave no answer for New agent is asked again.
                Task { await newAgentOffer.check() }
            // A call keeps the room live in the background: its answers come through the room.
            case .background where voiceRoom == nil: coordinator.pause()
            default: break
            }
        }
        .onReceive(callDesk.$waiting) { _ in takeAnsweredCall() }
        // Muted on the phone's own call screen, or by the panel's Mute performed there: the voice room stops
        // listening (warden, #281). Never sent back as the panel's Mute, which would ask the call screen again.
        .onReceive(callDesk.$muted) { muted in
            guard let answeredCall, let voiceRoom else { return }
            voiceRoom.callScreenMuted(muted.contains(answeredCall.uuid))
        }
        // Hung up on the phone's own call screen: the voice room ends with it.
        .onReceive(callDesk.$hungUp) { uuid in
            guard let uuid, answeredCall?.uuid == uuid else { return }
            guard let voiceRoom else {
                // Hung up while the AI question was still asked: the question goes with the call.
                consentHeld = nil
                answeredCall = nil
                return
            }
            Task { await voiceRoom.hangUp() }
        }
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

    /// A link that opened this room may also name a reply, a ticket or the agent requests: open those once, over the
    /// room. A reply opens its thread at it.
    private func applyRouteLinksOnce() {
        guard !appliedRouteLinks else { return }
        appliedRouteLinks = true
        if let replyId = route.focusReplyId, let sequence = route.focusSequenceId {
            coordinator.openThread(sequence, at: replyId)
        } else if let ticketId = route.focusTicketId, ticketsTransport != nil {
            linkedTicket = LinkedTicket(id: ticketId)
        } else if route.opensAdmissions, decidesAdmissions {
            showsAdmissions = true
        }
    }

    /// The room and its uploads, joined: a sent message's card goes when the room shows it, the room is read the moment
    /// it posts, and its photos' previews made here show at once.
    private func connectMedia() {
        let room = coordinator
        let outgoing = media
        room.onOwnEcho = { [weak outgoing] clientIds in outgoing?.echoed(clientIds) }
        outgoing.onPosted = { [weak room] in room?.pullLatest() }
        // A reply with files: posted only where the API takes them, and read back into its thread before its card goes.
        room.onReplyAttachmentSupport = { [weak outgoing] support in outgoing?.replyAttachments = support }
        outgoing.onReplyPosted = { [weak room] target, text in
            await room?.replyPosted(to: target.sequenceId, answering: target.replyId, text: text)
        }
        // "Send as a new message" carried a reply's words: their saved draft in the thread goes once it posts.
        outgoing.onReplyDraftSent = { [weak room] target, text in
            room?.forgetReplyDraft(thread: target.sequenceId, answering: target.replyId, text: text)
        }
        outgoing.onPreviewReady = { [weak room] attachmentId, data in room?.seedPreview(data, for: attachmentId) }
        outgoing.onReauthenticationRequired = onReauthenticationRequired
    }

    /// The viewers, the file preview, the share sheet, the pickers and the "Couldn't open the file" alert, presented
    /// from the room or (`isActive` there) from a sheet over it.
    private func mediaPresenters(isActive: Bool) -> RoomMediaPresenters {
        RoomMediaPresenters(
            isActive: isActive,
            media: media,
            coordinator: coordinator,
            attachmentPreview: $attachmentPreview,
            mediaViewer: $mediaViewer,
            shareItem: $shareItem,
            attachmentProblem: $attachmentProblem
        )
    }

    /// A photo opens in the zoomable viewer (its preview at once), a video plays from its storage link, and any other
    /// file downloads and shows full size; one open at a time.
    private func openAttachment(_ attachmentId: String) {
        guard !openingAttachment else { return }
        if let info = coordinator.attachmentInfo(attachmentId) {
            switch info.kind {
            case .image:
                mediaViewer = .image(attachmentId: attachmentId, filename: info.filename,
                                     preview: coordinator.loadedPreview(attachmentId))
                return
            case .video:
                openingAttachment = true
                Task {
                    defer { openingAttachment = false }
                    do {
                        // A fresh link, so the whole hour is ahead of the player.
                        let link = try await coordinator.mediaLink(attachmentId, fresh: true)
                        mediaViewer = .video(attachmentId: attachmentId, url: link.url)
                    } catch {
                        attachmentProblem = Self.openProblem(error)
                    }
                }
                return
            default:
                break
            }
        }
        openingAttachment = true
        Task {
            defer { openingAttachment = false }
            do {
                let file = try await coordinator.prepareAttachment(attachmentId)
                attachmentPreview = AttachmentPreviewItem(url: try AttachmentFiles.forQuickLook(file))
            } catch {
                attachmentProblem = Self.openProblem(error)
            }
        }
    }

    /// Downloads the file (as a download, with its safe name) and offers the share sheet: Save to Files, AirDrop,
    /// another app.
    private func shareAttachment(_ attachmentId: String) {
        guard !openingAttachment else { return }
        openingAttachment = true
        Task {
            defer { openingAttachment = false }
            do {
                shareItem = RoomShareItem(url: try await coordinator.prepareAttachment(attachmentId, asDownload: true))
            } catch {
                attachmentProblem = Self.openProblem(error)
            }
        }
    }

    private static func openProblem(_ error: Error) -> String {
        if case AttachmentFetchError.tooLarge? = error as? AttachmentFetchError {
            return "This file is too large to open on the phone."
        }
        if let error = error as? SessionTransportError, error == .accessDenied {
            return "You no longer have access to this file."
        }
        return "Check your connection and try again. If it keeps failing, the file may still be processing."
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
        isBlocked: @escaping @MainActor (String) -> Bool,
        onReauthenticationRequired: @escaping @MainActor () -> Void,
        onOpen: @escaping (Int64) -> Void,
        onOpenURL: @escaping (URL) -> Void
    ) {
        _model = StateObject(wrappedValue: RoomSearchModel(
            sessionId: sessionId,
            searcher: searcher,
            people: people,
            artifacts: { [weak artifacts] in (artifacts?.artifacts ?? [], artifacts?.isLoading ?? false) },
            isBlocked: isBlocked,
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
struct VoiceRoomHost: View {
    @ObservedObject var room: VoiceRoomCoordinator
    let meter: VoiceLevelMeter
    let partnerLab: AgentLab?
    /// Who could be brought into the call now.
    let addable: () -> [String]

    var body: some View {
        VoiceRoomPanel(state: room.state, meter: meter, partnerLab: partnerLab, addable: addable, send: room.send)
    }
}

/// The call the microphone's level goes to, set once the call exists (the listener is made before it).
@MainActor
private final class HeardLevel {
    weak var room: VoiceRoomCoordinator?
}

/// What a photo, video or file opens in, and the photo, camera and file pickers: presented by the room, or by a sheet
/// over it (a thread), since the room under a sheet cannot present anything. Only the active one presents.
private struct RoomMediaPresenters: ViewModifier {
    let isActive: Bool
    let media: RoomMediaUploadCoordinator
    let coordinator: RoomChatCoordinator
    @Binding var attachmentPreview: AttachmentPreviewItem?
    @Binding var mediaViewer: RoomMediaViewerItem?
    @Binding var shareItem: RoomShareItem?
    @Binding var attachmentProblem: String?

    /// The binding as this presenter sees it: nothing while it is not the active one.
    private func gated<Item>(_ binding: Binding<Item?>) -> Binding<Item?> {
        let isActive = self.isActive
        return Binding(get: { isActive ? binding.wrappedValue : nil }, set: { binding.wrappedValue = $0 })
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: gated($attachmentPreview)) { item in
                AttachmentQuickLook(url: item.url)
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: gated($mediaViewer)) { item in
                switch item {
                case .image(let attachmentId, let filename, let preview):
                    RoomImageViewer(
                        filename: filename,
                        preview: preview,
                        loadOriginal: { try await coordinator.prepareAttachment(attachmentId) },
                        onClose: { mediaViewer = nil }
                    )
                case .video(let attachmentId, let url):
                    RoomVideoViewer(
                        url: url,
                        // A link that stops working mid-play (it expired, or storage refused it) is asked for again.
                        refresh: { try await coordinator.mediaLink(attachmentId, fresh: true).url },
                        onClose: { mediaViewer = nil }
                    )
                }
            }
            .sheet(item: gated($shareItem)) { item in
                RoomShareSheet(items: [item.url], deletesWhenDone: true)
                    .presentationDetents([.medium, .large])
            }
            // The photo, camera and file pickers, opened from a composer's attach sheet.
            .background(
                RoomMediaPickerHost(
                    requests: media.pickers,
                    isActive: isActive,
                    remaining: { media.pickerRemaining },
                    onPicked: { media.add($0) },
                    onRefused: { media.refuse($0) }
                )
            )
            .alert("Couldn't open the file", isPresented: Binding(
                get: { isActive && attachmentProblem != nil },
                set: { if !$0 { attachmentProblem = nil } }
            )) {
                Button("OK", role: .cancel) { attachmentProblem = nil }
            } message: {
                Text(attachmentProblem ?? "")
            }
    }
}
