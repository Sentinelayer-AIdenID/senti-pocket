#if DEBUG
import Combine
import Foundation
import SwiftUI
import PocketCall
import PocketContracts
import PocketSyncClient
import PocketUI

/// DEBUG-only: `-PocketRootPreview` hosts the signed-in app's own root (`AuthenticatedRootView`: the side panel, the
/// bell and Waiting on you, folders, direct messages and the room on screen) on scripted data, with no network and no
/// sign-in, so its background work can be profiled and the side panel driven on a simulator. Made-up rooms and words
/// only. Never compiled into Release.
///
/// Options:
/// - `-PocketRootRoom long|mid|none|<room id>`: the room open at launch. `long` holds 1,000 messages, `mid` 165 (the
///   room loads its newest 100, then the rest with Load earlier); `room-000` to `room-137` hold 30 each, so the start of
///   the room is in reach. Default `mid`.
/// - `-PocketRootActivity`: the open room's Activity shows a few events and actions (the server's own types, and one
///   this app does not know); without it Activity is not served here, as before.
/// - `-PocketRootCreates`: the preview can make a chat, so the side panel offers New chat; without it, as before.
/// - `-PocketRootStream <posts per second>`: messages arriving in the open room (default none).
/// - `-PocketRootOneListPage`: every room in the list's first page, so the side panel lists all of them (the API
///   pages the list by 50).
/// - `-PocketRootThreadReading`: a moment after launch, the open room's newest message opens its thread and its first
///   reply is read aloud (made-up words), for pictures of the Listen bar over a thread.
/// - `-PocketRootInlineReplies`: every message with replies shows its newest reply in the room, as a row to answer in
///   place (a reply to a reply, from the room's box).
/// - `-PocketRootAIConsentGiven`: this account has already said OK to sharing with AI, so a first send is not asked
///   first (for a test of what follows a send, as on a phone that said OK before). Without it the preview asks.
enum RootPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-PocketRootPreview") }

    /// `-PocketRootAIConsentGiven`, honored in the root preview only: without `-PocketRootPreview` it does nothing. This
    /// whole file is DEBUG only, so a Release build has neither the flag nor this check.
    static func startsWithAIConsentGiven(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains("-PocketRootPreview") && arguments.contains("-PocketRootAIConsentGiven")
    }

    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The room open at launch.
    static var openRoomId: String? {
        switch argument("-PocketRootRoom") ?? "mid" {
        case "long": return RootPreviewAPI.longRoom
        case "none": return nil
        case let id where RootPreviewAPI.rooms.contains(where: { $0.id == id }): return id
        default: return RootPreviewAPI.midRoom
        }
    }

    @MainActor
    static func rootView(whisperModel: WhisperModelProvisioningCoordinator, incomingLinks: IncomingLinkInbox) -> some View {
        if ProcessInfo.processInfo.arguments.contains("-PocketRootThreadReading") { readInAThreadSoon() }
        // The root reopens the room opened last once the room list has loaded, as the app does after a launch.
        UserDefaults.standard.set(openRoomId ?? "", forKey: "pocket.lastRoomId")
        // The freeze watch runs as in the app, so a stall here is written down where the app writes one.
        MainThreadWatch.shared.start()
        meter.start()
        return AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: whisperModel,
            incomingLinks: incomingLinks,
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
    }

    /// Darwin notifications a test or the Mac's shell posts (`xcrun simctl spawn <sim> notifyutil -p <name>`) to open
    /// and close the side panel without touching the screen.
    static let openDrawerSignal = "com.plexaura.sentipocket.preview.root.drawer.open"
    static let closeDrawerSignal = "com.plexaura.sentipocket.preview.root.drawer.close"

    /// The side panel's requested state, from those signals: true opens it.
    static let drawerRequests: AnyPublisher<Bool, Never> = {
        guard isRequested else { return drawerSubject.eraseToAnyPublisher() }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [openDrawerSignal, closeDrawerSignal] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let open = (name?.rawValue as String?) == RootPreview.openDrawerSignal
                DispatchQueue.main.async { drawerSubject.send(open) }
            }, name as CFString, nil, .deliverImmediately)
        }
        return drawerSubject.eraseToAnyPublisher()
    }()

    private static let drawerSubject = PassthroughSubject<Bool, Never>()

    /// Opens or closes the side panel of a root hosted in a test, as the signals do in the preview.
    static func requestDrawer(_ open: Bool) { drawerSubject.send(open) }

    /// `-PocketRootThreadReading`: the newest message's thread, then its first reply read aloud, as taps would.
    private static func readInAThreadSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            requestRoom(.openThread(sequenceId: 165))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var words = RootPreviewWords(seed: 165)
                requestRoom(.readAloud(id: RoomReadAloud.reply("reply-165-1"),
                                       text: (0..<6).map { _ in words.sentence() }.joined(separator: " ")))
            }
        }
    }

    /// What a hosted test asks of the room on screen, as a tap there would (`RoomChatScreen.handle`).
    static let roomRequests = PassthroughSubject<RoomChatIntent, Never>()

    static func requestRoom(_ intent: RoomChatIntent) { roomRequests.send(intent) }

    /// What the main thread did between two signals, for profiles of the root (`RootPreviewMeter`).
    static let meter = RootPreviewMeter()

    static let api = RootPreviewAPI(
        postsPerSecond: Double(argument("-PocketRootStream") ?? "") ?? 0,
        onePage: ProcessInfo.processInfo.arguments.contains("-PocketRootOneListPage"),
        openRoomId: openRoomId
    )
}

/// Measures the main thread of the root preview between two Darwin signals (`…preview.root.measure.start` and
/// `…measure.stop`): how long its run loop was busy (from waking to waiting again), the longest such stretch, how many
/// times each of the root's objects announced a change, how often the root's body ran and how many message rows were
/// drawn. `stop` writes them as one JSON line to `Library/Caches/root-measure.json` in the app's container, and to the
/// log (`BGAUDIT-METER`), where a run a UI test launched can be read too. Instruments' Time
/// Profiler cannot record without a signed-in desktop on the build Mac; this needs none. Used on the main thread only.
final class RootPreviewMeter: @unchecked Sendable {
    static let startSignal = "com.plexaura.sentipocket.preview.root.measure.start"
    static let stopSignal = "com.plexaura.sentipocket.preview.root.measure.stop"

    private var observer: CFRunLoopObserver?
    private var wokeAt: CFAbsoluteTime?
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var busy: Double = 0
    private var longest: Double = 0
    private var over50 = 0
    private var over250 = 0
    private var changes: [String: Int] = [:]
    private var watching: [String: AnyCancellable] = [:]
    private var rowsAtStart = 0
    private(set) var rootBodies = 0
    private var rootBodiesAtStart = 0

    func start() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            self?.ran(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in [Self.startSignal, Self.stopSignal] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let starts = (name?.rawValue as String?) == RootPreviewMeter.startSignal
                DispatchQueue.main.async { starts ? RootPreview.meter.reset() : RootPreview.meter.write() }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    /// Counts each change `object` announces under `name`.
    func watch<Object: ObservableObject>(_ name: String, _ object: Object) {
        watching[name] = object.objectWillChange.sink { [weak self] _ in self?.changes[name, default: 0] += 1 }
    }

    func rootBodyRan() { rootBodies += 1 }

    /// Room screens made (`RoomChatScreen.init`, which reads the Keychain) and room screen bodies run, so far.
    private(set) var roomScreens = 0
    private(set) var roomScreenBodies = 0
    private var roomScreensAtStart = 0
    private var roomScreenBodiesAtStart = 0

    func roomScreenMade() { roomScreens += 1 }

    func roomScreenBodyRan() { roomScreenBodies += 1 }

    /// Where each read-aloud bar and its controls were last laid out, by place ("app", "room", "thread").
    private(set) var readAloudBars: [String: [String: CGRect]] = [:]

    func readAloudBarLaidOut(_ place: String, _ frames: [String: CGRect]) { readAloudBars[place] = frames }

    func forgetReadAloudBars() { readAloudBars = [:] }

    /// Times the root asked for its side panel's rooms to be placed (`placeSidePanelRooms`), open or not.
    private(set) var sidePanelPlacements = 0

    func sidePanelPlaced() { sidePanelPlacements += 1 }

    /// Whether the room's calendar entry offered Calendar the last time its body ran (nil before it ran): it watches
    /// the calendar itself, so an answer that turns the calendar on reaches it without the root drawing again.
    private(set) var calendarEntryOffers: Bool?

    func calendarEntryRan(offers: Bool) { calendarEntryOffers = offers }

    /// Forgets what an earlier window's calendar entry said, so a test reads only its own root's entry.
    func forgetCalendarEntry() { calendarEntryOffers = nil }

    private func ran(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting {
            wokeAt = now
        } else if let woke = wokeAt {
            let stretch = (now - woke) * 1_000
            busy += stretch
            longest = max(longest, stretch)
            if stretch > 50 { over50 += 1 }
            if stretch > 250 { over250 += 1 }
            wokeAt = nil
        }
    }

    func reset() {
        startedAt = CFAbsoluteTimeGetCurrent()
        busy = 0
        longest = 0
        over50 = 0
        over250 = 0
        changes = [:]
        rowsAtStart = RenderTrace.snapshot().draws
        rootBodiesAtStart = rootBodies
        roomScreensAtStart = roomScreens
        roomScreenBodiesAtStart = roomScreenBodies
    }

    func write() {
        let seconds = CFAbsoluteTimeGetCurrent() - startedAt
        let line: [String: Any] = [
            "seconds": (seconds * 10).rounded() / 10,
            "busyMs": busy.rounded(),
            "busyMsPerMinute": (busy / max(seconds, 1) * 60).rounded(),
            "longestMs": (longest * 10).rounded() / 10,
            "stretchesOver50ms": over50,
            "stretchesOver250ms": over250,
            "rootBodies": rootBodies - rootBodiesAtStart,
            "roomScreensMade": roomScreens - roomScreensAtStart,
            "roomScreenBodies": roomScreenBodies - roomScreenBodiesAtStart,
            "rowDraws": RenderTrace.snapshot().draws - rowsAtStart,
            "changes": changes
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        NSLog("BGAUDIT-METER %@", String(decoding: data, as: UTF8.self))
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: caches.appendingPathComponent("root-measure.json"))
    }
}

/// Made-up words for the scripted rooms, the same on every launch.
struct RootPreviewWords {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }

    private static let syllables = ["ka", "lor", "vem", "tis", "ub", "ran", "qel", "mo", "sa", "dri", "fen", "ol", "pex",
                                    "zu", "ny", "bar", "cil", "te", "wom", "ash", "ery", "gol", "hin", "jat", "ul"]

    mutating func word() -> String {
        (0..<(1 + next(3))).map { _ in Self.syllables[next(Self.syllables.count)] }.joined()
    }

    mutating func sentence() -> String {
        let words = (0..<(4 + next(12))).map { _ in word() }
        return words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + "."
    }

    mutating func title() -> String {
        (0..<(1 + next(3))).map { _ in word().capitalized }.joined(separator: " ")
    }

    /// A message as agents write them: short lines, paragraphs, lists, code and tables, now and then long.
    mutating func message() -> String {
        switch next(20) {
        case 0..<7:
            return sentence()
        case 7..<12:
            return (0..<(2 + next(4))).map { _ in sentence() }.joined(separator: " ")
        case 12..<15:
            return "**\(title())**\n\n" + (0..<(3 + next(5))).map { _ in "- \(sentence())" }.joined(separator: "\n")
        case 15..<17:
            let code = (0..<(3 + next(8))).map { _ in "let \(word()) = \(word())(\(word()), \(next(900)))" }
            return sentence() + "\n```\n" + code.joined(separator: "\n") + "\n```\n" + sentence()
        case 17:
            let rows = (0..<(4 + next(8))).map { _ in "| \(word()) | \(next(100)) | \(word()) \(word()) |" }
            return "| \(word()) | \(word()) | \(word()) |\n|---|---|---|\n" + rows.joined(separator: "\n")
        default:
            // A long report: several sections, as a box's review packet.
            return (0..<(3 + next(4))).map { _ in
                "## \(title())\n\n" + (0..<(2 + next(4))).map { _ in sentence() }.joined(separator: " ")
                    + "\n\n" + (0..<(2 + next(4))).map { _ in "1. \(sentence())" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
    }
}

/// The scripted Senti API behind the root preview: 160 rooms in five folders with twenty direct messages, the bell,
/// Waiting on you, and rooms whose messages arrive at a steady pace. Lists are made and decoded as JSON, off the main
/// thread, as the live client does.
final class RootPreviewAPI: @unchecked Sendable {
    static let longRoom = "room-long"
    static let midRoom = "room-mid"
    static let agents = ["review-agent", "build-agent", "plan-agent", "docs-agent", "test-agent", "ops-agent"]
    static let me = "human-alex"

    private let postsPerSecond: Double
    private let onePage: Bool
    private let started = Date()
    private let lock = NSLock()
    private var histories: [String: [RoomMessage]] = [:]

    /// The room open at launch, where messages arrive.
    let openRoomId: String?
    private var calls: [String: Int] = [:]

    init(postsPerSecond: Double, onePage: Bool, openRoomId: String?) {
        self.postsPerSecond = postsPerSecond
        self.onePage = onePage
        self.openRoomId = openRoomId
    }

    /// How many times each read was asked for: "rooms", "bell", "waiting", "folders", "dmSettings", and the open room's
    /// "history" (a page of its messages), "actions" (reactions and replies), "views" (who viewed what) and "presence".
    func callCount(_ name: String) -> Int { lock.withLock { calls[name, default: 0] } }

    /// All the reads above, together: a hosted test waits until this stops moving.
    var totalCalls: Int { lock.withLock { calls.values.reduce(0, +) } }

    private func count(_ name: String) { lock.withLock { calls[name, default: 0] += 1 } }

    /// Whether the preview can make a chat (`-PocketRootCreates`).
    static let createsRooms = ProcessInfo.processInfo.arguments.contains("-PocketRootCreates")

    var services: RootServices {
        let sender: any RoomMessageSending & RoomActionSending
        if Self.createsRooms {
            sender = RootPreviewCreatingSender()
        } else {
            sender = RootPreviewSender()
        }
        return RootServices(
            sessions: self, room: self, tickets: self, admissions: self, search: self, notifications: self,
            notificationMarker: self, callLog: self, waiting: self, checkpoints: self, directMessages: self,
            roomFolders: self, admissionDecider: self, sender: sender, actionSender: sender, ticketWriter: self,
            ticketLeases: InMemoryTicketLeaseStore(), ticketExtras: self, identity: self, receipts: self, readMarker: self,
            registersPush: false
        )
    }

    // MARK: The rooms

    struct Room {
        let id: String
        let title: String
        let folderId: String?
        let summary: String?
        let unread: Int
        let humans: Int
        let agents: Int
        let minutesAgo: Int
        let direct: (name: String, isAgent: Bool, origin: String?)?
        let messages: Int
    }

    static let folders: [RoomFolder] = (0..<5).map { index in
        var words = RootPreviewWords(seed: UInt64(900 + index))
        return RoomFolder(id: "folder-\(index)", name: words.title(), position: index, roomCount: 0)
    }

    static let rooms: [Room] = {
        var words = RootPreviewWords(seed: 7)
        var rooms = [
            Room(id: longRoom, title: "Long room", folderId: "folder-0", summary: words.sentence(), unread: 0, humans: 2,
                 agents: 5, minutesAgo: 1, direct: nil, messages: 1_000),
            // In the first folder with the long room, so the side panel shows both without scrolling.
            Room(id: midRoom, title: "Review room", folderId: "folder-0", summary: words.sentence(), unread: 0, humans: 1,
                 agents: 4, minutesAgo: 2, direct: nil, messages: 165)
        ]
        for index in 0..<138 {
            let folder = words.next(3) == 0 ? nil : "folder-\(words.next(5))"
            let summary = words.next(4) == 0 ? nil : (0..<(1 + words.next(3))).map { _ in words.sentence() }.joined(separator: " ")
            rooms.append(Room(id: String(format: "room-%03d", index), title: words.title(), folderId: folder, summary: summary,
                              unread: words.next(4) == 0 ? 1 + words.next(40) : 0, humans: words.next(3),
                              agents: words.next(6), minutesAgo: 3 + index * 17, direct: nil, messages: 30))
        }
        for index in 0..<20 {
            let isAgent = index % 3 != 0
            let name = isAgent ? agents[index % agents.count] : words.word().capitalized
            let origin = index % 4 == 3 ? nil : rooms[words.next(rooms.count)].id
            rooms.append(Room(id: String(format: "dm-%03d", index), title: name, folderId: nil, summary: nil,
                              unread: index % 5 == 0 ? 2 : 0, humans: 0, agents: 0, minutesAgo: 5 + index * 41,
                              direct: (name, isAgent, origin), messages: 12))
        }
        return rooms.sorted { $0.minutesAgo < $1.minutesAgo }
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func stamp(_ date: Date) -> String { Self.iso.string(from: date) }

    private func json(_ room: Room) -> [String: Any] {
        var object: [String: Any] = [
            "sessionId": room.id, "status": "active", "archiveStatus": "live", "visibility": "private",
            "membershipRole": room.id == Self.midRoom || room.id == Self.longRoom ? "owner" : "contributor",
            "title": room.title, "agentCount": room.agents, "eventCount": room.messages, "totalCostUsd": 0,
            "lastActivityAt": stamp(lastActivity(room)),
            "online": ["humans": room.humans, "agents": room.agents],
            "unread": room.unread > 0 ? ["count": room.unread, "firstUnreadSequenceId": room.messages - room.unread + 1]
                : ["count": 0] as [String: Any],
            "lastReadSequenceId": room.messages - room.unread
        ]
        if let summary = room.summary { object["summaryText"] = summary }
        if let folderId = room.folderId { object["folderId"] = folderId }
        if let direct = room.direct {
            object["kind"] = "direct"
            object["counterpart"] = ["senderId": direct.isAgent ? direct.name : "human-\(direct.name.lowercased())",
                                     "kind": direct.isAgent ? "agent" : "human", "displayName": direct.name]
            if let origin = direct.origin { object["originRoomId"] = origin }
        }
        return object
    }

    /// The open room's newest message moves its activity time on while messages arrive; every other room stays put.
    private func lastActivity(_ room: Room) -> Date {
        if postsPerSecond > 0, room.id == openRoomId { return arrivedCount(at: Date()) > 0 ? Date() : started }
        return started.addingTimeInterval(-Double(room.minutesAgo) * 60)
    }

    // MARK: Messages

    private func history(_ roomId: String) -> [RoomMessage] {
        lock.lock()
        defer { lock.unlock() }
        if let history = histories[roomId] { return history }
        let count = Self.rooms.first { $0.id == roomId }?.messages ?? 20
        var words = RootPreviewWords(seed: UInt64(abs(roomId.hashValue % 10_000)) + 11)
        let made = (1...count).map { index -> RoomMessage in
            let human = words.next(6) == 0
            let author = human ? Self.me : Self.agents[words.next(Self.agents.count)]
            return message(Int64(index), author: author, text: human ? words.sentence() : words.message(),
                           at: started.addingTimeInterval(-Double(count - index) * 47))
        }
        histories[roomId] = made
        return made
    }

    private func message(_ sequence: Int64, author: String, text: String, at date: Date) -> RoomMessage {
        RoomMessage(id: String(format: "00000000-0000-4000-8000-%012lld", sequence), sequenceId: sequence, kind: .message,
                    authorId: author, authorName: RoomMessage.isHumanAuthor(author) ? "Alex" : author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: text, timestamp: stamp(date))
    }

    /// Messages that arrived in the open room since launch, at `postsPerSecond`.
    private func arrivedCount(at date: Date) -> Int {
        guard postsPerSecond > 0 else { return 0 }
        return max(0, Int(date.timeIntervalSince(started) * postsPerSecond))
    }

    private func arrival(_ index: Int, in roomId: String) -> RoomMessage {
        let base = Int64(history(roomId).count)
        var words = RootPreviewWords(seed: UInt64(50_000 + index))
        return message(base + Int64(index), author: Self.agents[index % Self.agents.count], text: words.message(),
                       at: started.addingTimeInterval(Double(index) / postsPerSecond))
    }

    private func allMessages(_ roomId: String) -> [RoomMessage] {
        let arrived = roomId == openRoomId ? arrivedCount(at: Date()) : 0
        return history(roomId) + (0..<arrived).map { arrival($0 + 1, in: roomId) }
    }
}

extension RootPreviewAPI: SessionTransport {
    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        count("rooms")
        let start = Int(cursor ?? "0") ?? 0
        let size = onePage ? Self.rooms.count : limit
        let page = Array(Self.rooms.dropFirst(start).prefix(size))
        let next = start + page.count < Self.rooms.count ? String(start + page.count) : nil
        let body: [String: Any] = ["sessions": page.map(json), "count": page.count, "include_archived": includeArchived,
                                   "next_cursor": next as Any, "has_more": next != nil]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(SessionListPage.self, from: data)
    }

    func listEvents(sessionId: String, after: String?, fromSequence: Int64?, limit: Int) async throws -> SessionEventForwardPage {
        guard Self.servesActivity else { throw SessionTransportError.notConfigured }
        return try Self.activityEvents(sessionId: sessionId)
    }

    func listEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> SessionEventBeforePage {
        throw SessionTransportError.notConfigured
    }

    func listActions(sessionId: String, targetSequenceId: Int64?, targetActionId: String?, limit: Int) async throws
        -> SessionActionPage {
        guard Self.servesActivity else { throw SessionTransportError.notConfigured }
        return try Self.activityActions(sessionId: sessionId)
    }

    /// Whether the open room's Activity is served (`-PocketRootActivity`).
    static let servesActivity = ProcessInfo.processInfo.arguments.contains("-PocketRootActivity")

    /// A few of a room's events for Activity, as the server writes them: its own types, and one this app does not know
    /// (it reads as an update). Made-up words only.
    static func activityEvents(sessionId: String) throws -> SessionEventForwardPage {
        let rows: [(type: String, name: String, text: String?, minutes: Double)] = [
            ("session_message", "Alex", "Can someone check the release notes before lunch?", 42),
            ("agent_response", "review-agent", "The notes read well. Two links were old; I fixed them.", 38),
            ("session_titled", "Alex", nil, 31),
            ("room_event_reminder", "Senti", "Design review in 15 minutes.", 15),
            ("file_lock", "build-agent", nil, 9)
        ]
        let now = Date()
        let events: [[String: Any]] = rows.enumerated().map { index, row in
            let at = ISO8601DateFormatter().string(from: now.addingTimeInterval(-row.minutes * 60))
            var event: [String: Any] = [
                "id": "preview-event-\(index)", "event": row.type, "agent": ["displayName": row.name],
                "agentId": row.name, "agentModel": "", "payload": [String: Any](), "ts": at, "timestamp": at,
                "cursor": "c\(index)",
                "sequenceId": 7_000 + index, "sessionId": sessionId, "source": "preview"
            ]
            if let text = row.text { event["payload"] = ["text": text] }
            return event
        }
        let data = try JSONSerialization.data(withJSONObject: ["events": events])
        return try JSONDecoder().decode(SessionEventForwardPage.self, from: data)
    }

    /// A few of a room's actions for Activity, as the server writes them (one of a type this app does not know).
    static func activityActions(sessionId: String) throws -> SessionActionPage {
        let rows: [(type: String, actor: String, target: Int, minutes: Double)] = [
            ("ack", "Alex", 7_001, 37), ("like", "Sam", 7_001, 36), ("view", "Sam", 7_000, 35),
            ("working_on", "review-agent", 0, 30), ("escalate", "ops-agent", 7_003, 12)
        ]
        let now = Date()
        let actions: [[String: Any]] = rows.enumerated().map { index, row in
            [
                "id": "preview-action-\(index)", "sessionId": sessionId, "targetSequenceId": row.target,
                "targetCursor": NSNull(), "targetActionId": NSNull(), "actionType": row.type, "actorKind": "human",
                "actorId": row.actor, "actorUserId": NSNull(), "actorRole": NSNull(), "note": NSNull(), "metadata": [String: Any](),
                "idempotencyKey": "preview-\(index)",
                "createdAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-row.minutes * 60))
            ]
        }
        let page: [String: Any] = ["sessionId": sessionId, "count": actions.count, "projection": [String: Any](),
                                   "actions": actions]
        let data = try JSONSerialization.data(withJSONObject: page)
        return try JSONDecoder().decode(SessionActionPage.self, from: data)
    }

    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage {
        throw SessionTransportError.notConfigured
    }
}

extension RootPreviewAPI: RoomTransport {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        count("history")
        try? await Task.sleep(nanoseconds: 150_000_000)
        let all = allMessages(sessionId).filter { $0.sequenceId < (beforeSequence ?? .max) }
        let page = Array(all.suffix(limit))
        let more = all.count > page.count
        return RoomEventPage(messages: page, nextBeforeSequence: more ? page.first?.sequenceId : nil, hasMore: more)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        let after = allMessages(sessionId).filter { $0.sequenceId > fromSequence }
        let page = Array(after.prefix(limit))
        return RoomEventPage(messages: page, hasMore: after.count > page.count)
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                continuation.yield(.opened)
                continuation.yield(.frame(.control))
                guard postsPerSecond > 0, sessionId == openRoomId else { return }
                var sent = arrivedCount(at: Date())
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / postsPerSecond))
                    let now = arrivedCount(at: Date())
                    while sent < now, !Task.isCancelled {
                        sent += 1
                        continuation.yield(.frame(.message(arrival(sent, in: sessionId))))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        count("actions")
        let messages = history(sessionId)
        guard let newest = messages.last?.sequenceId else { return RoomActionsPage() }
        if let targetSequenceId {
            let replies = (1...3).map { index in
                RoomReply(id: "reply-\(targetSequenceId)-\(index)", targetSequenceId: targetSequenceId,
                          authorId: Self.agents[index % Self.agents.count], text: "Reply \(index) to message \(targetSequenceId).",
                          createdAt: stamp(started.addingTimeInterval(Double(index - 10) * 60)))
            }
            return RoomActionsPage(replies: replies)
        }
        var byTarget: [Int64: RoomReactionSummary] = [:]
        // With -PocketRootInlineReplies, each of these messages' newest reply is shown in the room as a row,
        // to answer in place (a reply to a reply, from the room's box).
        let inline = ProcessInfo.processInfo.arguments.contains("-PocketRootInlineReplies")
        var replies: [RoomReply] = []
        for target in stride(from: newest, to: max(newest - 120, 0), by: -7) {
            byTarget[target] = RoomReactionSummary(targetSequenceId: target, counts: ["ack": 1, "like": 2, "reply": 3],
                                                   actorsByType: ["ack": [Self.agents[Int(target) % Self.agents.count]]],
                                                   replyTotal: 3)
            if inline {
                replies.append(RoomReply(id: "reply-\(target)-3", targetSequenceId: target,
                                         authorId: Self.agents[3 % Self.agents.count], text: "Reply 3 to message \(target).",
                                         createdAt: stamp(started.addingTimeInterval(-Double(newest - target) * 47 + 20))))
            }
        }
        return RoomActionsPage(byTarget: byTarget, replies: replies)
    }
}

extension RootPreviewAPI: RoomTicketsTransport, RoomAdmissionsTransport, RoomSearching, CheckpointTransport {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [], hasMore: false, cursor: 0)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }

    func roomAdmissions(sessionId: String) async throws -> RoomAdmissionsPage {
        RoomAdmissionsPage(admissions: [])
    }

    func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage {
        let matches = allMessages(sessionId).reversed()
            .filter { $0.sequenceId < (beforeSequence ?? .max) && $0.text.localizedCaseInsensitiveContains(query) }
            .prefix(limit)
            .map { RoomSearchResult(sequenceId: $0.sequenceId, snippet: String($0.text.prefix(160)), message: $0) }
        return RoomSearchPage(query: query, results: Array(matches))
    }

    func fetchExactCheckpoint(sessionId: String, checkpointId: String) async throws -> VerifiedBundle {
        throw SessionTransportError.notConfigured
    }
}

extension RootPreviewAPI: NotificationsTransport, NotificationReadMarking, WaitingTransport, CallLogTransport {
    func notifications() async throws -> SentiNotificationsPage {
        count("bell")
        var words = RootPreviewWords(seed: 33)
        let rooms = Self.rooms.filter { $0.direct == nil }
        return SentiNotificationsPage(notifications: (0..<40).map { index in
            let room = rooms[words.next(rooms.count)]
            return SentiNotification(id: "note-\(index)", kind: index % 3 == 0 ? "mention" : "message", sessionId: room.id,
                                     title: words.title(), body: words.sentence(), isRead: index >= 6,
                                     createdAt: stamp(started.addingTimeInterval(-Double(index) * 600)))
        })
    }

    func markRead(id: String) async throws {}

    func waiting(limit: Int) async throws -> SentiWaitingPage {
        count("waiting")
        var words = RootPreviewWords(seed: 44)
        let items = (0..<6).map { index -> SentiWaitingItem in
            let room = Self.rooms[index * 3]
            return SentiWaitingItem(roomId: room.id, roomTitle: room.title, ticketId: "ticket-\(index)", title: words.title(),
                                    question: words.sentence(), options: ["Yes", "No"], custom: true,
                                    askedAt: stamp(started.addingTimeInterval(-Double(index) * 900)))
        }
        return SentiWaitingPage(total: items.count, items: Array(items.prefix(limit)))
    }

    func calls(limit: Int, cursor: String?) async throws -> SentiCallLogPage {
        SentiCallLogPage(calls: [])
    }
}

extension RootPreviewAPI: DirectMessaging, RoomFoldersServing {
    func openDirectMessage(with targetSenderId: String, from contextRoomId: String) async throws -> DirectMessage {
        throw SessionTransportError.notConfigured
    }

    func directMessage(_ sessionId: String) async throws -> DirectMessage {
        guard let room = Self.rooms.first(where: { $0.id == sessionId }), let direct = room.direct else {
            throw SessionTransportError.notConfigured
        }
        return DirectMessage(sessionId: sessionId,
                             counterpart: SessionCounterpart(senderId: direct.isAgent ? direct.name : "human-\(direct.name)",
                                                             kind: direct.isAgent ? "agent" : "human", displayName: direct.name),
                             originRoom: nil, mutualRooms: [], memoryShare: [], created: false)
    }

    func setMemoryShare(_ sessionId: String, roomId: String, enabled: Bool) async throws -> [DirectMemoryShare] { [] }

    func directMessageSettings() async throws -> DirectMessagesAllowance? {
        count("dmSettings")
        return .sharedRooms
    }

    func setDirectMessageSettings(_ allowance: DirectMessagesAllowance) async throws -> DirectMessagesAllowance? { allowance }

    func folders() async throws -> [RoomFolder] {
        count("folders")
        return Self.folders
    }

    func createFolder(named name: String, in parentFolderId: String?, idempotencyKey: String?) async throws -> RoomFolder {
        throw SessionTransportError.notConfigured
    }

    func renameFolder(_ folderId: String, to name: String) async throws -> RoomFolder { throw SessionTransportError.notConfigured }

    func moveFolder(_ folderId: String, to position: Int) async throws -> RoomFolder { throw SessionTransportError.notConfigured }

    func moveFolder(_ folderId: String, into parentFolderId: String?) async throws -> RoomFolder {
        throw SessionTransportError.notConfigured
    }

    func deleteFolder(_ folderId: String) async throws { throw SessionTransportError.notConfigured }

    func file(room sessionId: String, in folderId: String) async throws { throw SessionTransportError.notConfigured }

    func unfile(room sessionId: String, from folderId: String) async throws { throw SessionTransportError.notConfigured }
}

extension RootPreviewAPI: AdmissionDeciding, RoomTicketWriting, RoomTicketExtrasReading, AccountIdentityProviding {
    func decide(sessionId: String, admissionId: String, approve: Bool, grantedActions: [String], ttlSeconds: Int?) async throws {}

    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult {
        throw RoomSendError.rejected
    }

    func comments(sessionId: String, ticketId: String, after: Int64) async throws -> RoomTicketCommentsPage {
        RoomTicketCommentsPage(comments: [], cursor: after)
    }

    func memberDirectory(sessionId: String, cursor: String?) async throws -> RoomDirectoryPage {
        RoomDirectoryPage(members: [])
    }

    func currentAccount() async -> SignedInAccount? {
        SignedInAccount(githubUsername: "alex", accountId: "6f1c2b9e-0000-4000-8000-00000000000a")
    }
}

extension RootPreviewAPI: RoomReceiptsClient, RoomReadMarking {
    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {}

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] {
        count("views")
        // Each viewer saw each message once, at launch: a read again finds what it found before.
        let seen = stamp(started)
        return targets.map { target in
            let viewers = Self.agents.prefix(2).map { RoomViewer(isHuman: false, actorId: $0, viewedAt: seen) }
            return RoomViewSummary(kind: target.kind, id: target.id, revision: target.revision,
                                   viewedCount: viewers.count, viewers: Array(viewers))
        }
    }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? { 90 }

    func presence(sessionId: String) async throws -> RoomPresence {
        count("presence")
        return RoomPresence(isAvailable: true,
                            participants: [RoomPresentParticipant(id: Self.me, isHuman: true, displayName: "Alex")]
                                + Self.agents.prefix(4).map { RoomPresentParticipant(id: $0, isHuman: false) },
                            humansOnline: 1, agentsOnline: 4, ttlSeconds: 90)
    }

    func markRead(sessionId: String, through sequenceId: Int64) async throws -> RoomReadReceipt {
        RoomReadReceipt(outcome: .recorded, lastReadSequenceId: sequenceId)
    }
}

/// Sends and actions succeed after a moment, as the API answers them.
private struct RootPreviewSender: RoomMessageSending, RoomActionSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}

/// The preview's sender that can also make a chat (`-PocketRootCreates`): the side panel offers New chat.
private struct RootPreviewCreatingSender: RoomMessageSending, RoomActionSending, RoomCreating {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func create(title: String, kind: RoomKind) async throws -> String {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return "room-made-" + String(UUID().uuidString.prefix(8)).lowercased()
    }
}
#endif
