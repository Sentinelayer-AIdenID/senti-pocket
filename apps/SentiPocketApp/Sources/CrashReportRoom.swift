import Foundation
import PocketSyncClient
import SwiftUI

// Where a person's crash reports go when they choose to send them: a private room of their own, which the team's
// account is asked into when the build names one, and never a room anyone else is in. (Carter, 11-06: a report was
// offered "in the next room you open" and went into a room with other people in it.)

/// The kept reports room: its id, and the team's account once it is in the room, so it is not taken for someone else.
struct ReportRoom: Codable, Equatable, Sendable {
    let sessionId: String
    var supportUserId: String?
}

/// Where the reports room is kept for the signed-in person.
protocol ReportRoomKeeping: Sendable {
    /// The room kept for this person (their account id), if any. Another person's room is never returned (and is
    /// dropped).
    func room(for person: String) -> ReportRoom?
    /// Keeps this room for this person, in place of any room kept before, theirs or anyone else's.
    func keep(_ room: ReportRoom, for person: String)
    /// Drops the kept room: on sign-out, on a refused credential (another account may sign in next) and with the
    /// account's deletion (`SignInCoordinator.clearPersonalState`).
    func forgetAll()
}

/// One record in the app's defaults: whose it is (their account id) and their room. A room id is no secret.
struct ReportRoomStore: ReportRoomKeeping, @unchecked Sendable {
    static let live = ReportRoomStore(defaults: .standard)
    static let key = "pocket.reportsRoom"

    let defaults: UserDefaults

    private struct Record: Codable {
        let person: String
        let room: ReportRoom
    }

    func room(for person: String) -> ReportRoom? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.person == person.lowercased() else {
            forgetAll()
            return nil
        }
        return record.room
    }

    func keep(_ room: ReportRoom, for person: String) {
        guard let data = try? JSONEncoder().encode(Record(person: person.lowercased(), room: room)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func forgetAll() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The rule every report goes through before it is posted.
enum ReportRoomSafety {
    /// Who besides you would read a report posted in this room: anyone at all in a room that is not private, every
    /// member who is neither you nor the team's account, and anyone invited. Empty only for a private room that holds
    /// you (and the team's account, once it is in) and has no invitation open.
    static func others(in membership: RoomMembershipSnapshot, viewer: String, support: String?) -> [String] {
        var others: [String] = []
        if membership.visibility != "private" { others.append("anyone: the room is not private") }
        let allowed = Set([viewer.lowercased()] + (support.map { [$0.lowercased()] } ?? []))
        others += membership.memberUserIds.filter { !allowed.contains($0) }
        if membership.pendingInvitationCount > 0 { others.append("\(membership.pendingInvitationCount) invited") }
        return others
    }
}

/// The team's account that reports are shared with, from the build's `SENTI_SUPPORT_MEMBER`: set when an archive is
/// made, never in the source. A GitHub login; an empty value, an unexpanded placeholder or anything else is none.
enum SupportMember {
    static let infoPlistKey = "SENTI_SUPPORT_MEMBER"

    static func login(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed.count <= 39,
              trimmed.range(of: #"^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return trimmed.lowercased()
    }

    static func configured(infoDictionary: [String: Any]) -> String? {
        login(infoDictionary[infoPlistKey] as? String)
    }

    static var configured: String? {
        configured(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}

/// What reporting needs from the Senti API, as you.
protocol ReportRoomAPI: Sendable {
    /// `POST /api/v1/sessions`: a new private room; its id.
    func createReportRoom(title: String, maxMembers: Int, sessionId: String, idempotencyKey: String) async throws -> String
    /// `GET /sessions/{id}/members`: everyone in the room and everyone invited. A room that is gone, or no longer
    /// yours, throws `SessionTransportError.accessDenied`.
    func reportRoomMembership(sessionId: String) async throws -> RoomMembershipSnapshot
    /// `POST /sessions/{id}/human-message`, under the given client id (the API keeps one copy per id).
    func sendReport(sessionId: String, text: String, clientId: String) async throws
    /// `POST /sessions/{id}/members`: adds an existing account by its login; its user id once it is in the room.
    func addReportRoomMember(sessionId: String, login: String) async throws -> String?
}

struct HTTPReportRooms: ReportRoomAPI, @unchecked Sendable {
    let sender: HTTPRoomMessageSender
    let transport: HTTPSessionTransport

    func createReportRoom(title: String, maxMembers: Int, sessionId: String, idempotencyKey: String) async throws -> String {
        try await sender.createRoom(title: title, roomType: "general", maxMembers: maxMembers, sessionId: sessionId,
                                    idempotencyKey: idempotencyKey)
    }

    func reportRoomMembership(sessionId: String) async throws -> RoomMembershipSnapshot {
        try await transport.roomMembership(sessionId: sessionId)
    }

    func sendReport(sessionId: String, text: String, clientId: String) async throws {
        try await sender.sendHumanMessage(sessionId: sessionId, text: text, clientId: clientId)
    }

    func addReportRoomMember(sessionId: String, login: String) async throws -> String? {
        try await sender.addReportRoomMember(sessionId: sessionId, login: login)
    }
}

extension HTTPRoomMessageSender {
    /// `POST /api/v1/sessions/{id}/members` for the team's account, as a contributor so the team can answer. The user
    /// id comes back in `member.userId` once the account is in the room.
    func addReportRoomMember(sessionId: String, login: String) async throws -> String? {
        let (data, http) = try await sessionMutation(
            sessionId: sessionId, path: "members",
            routeTemplate: "POST /api/v1/sessions/{session_id}/members",
            keyPrefix: "member", body: ["userIdentifier": login, "role": "contributor"]
        )
        guard (200..<300).contains(http.statusCode) else {
            throw RoomInviteError(message: RoomInviteFailure.message(status: http.statusCode, data: data))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let userId = (object?["member"] as? [String: Any])?["userId"] as? String,
              UUID(uuidString: userId) != nil else { return nil }
        return userId.lowercased()
    }
}

/// Sends the crash reports a person chose to share to their reports room, and says whether they got there.
@MainActor
final class CrashReportDelivery {
    enum Outcome: Equatable {
        case sent(sessionId: String)
        case notSent
    }

    /// What the room is called in the person's list of rooms.
    static let roomTitle = "Pocket reports"
    /// The person and the team's account: nobody else fits.
    static let roomSize = 2

    private let api: any ReportRoomAPI
    private let rooms: any ReportRoomKeeping
    /// The team's account (a GitHub login), or nil when the build names none: then nobody is asked in.
    private let supportLogin: String?
    private let makeId: () -> String
    private let note: @MainActor (String) -> Void

    init(api: any ReportRoomAPI, rooms: any ReportRoomKeeping, supportLogin: String?,
         makeId: @escaping () -> String = { UUID().uuidString.lowercased() },
         note: @escaping @MainActor (String) -> Void = { CrashReporter.shared.note($0) }) {
        self.api = api
        self.rooms = rooms
        self.supportLogin = SupportMember.login(supportLogin)
        self.makeId = makeId
        self.note = note
    }

    /// Posts `text` in this person's reports room: the kept one if it is still theirs alone, else a new one. A room
    /// that is gone or no longer theirs, or that anyone else is in or invited to, is dropped (never posted in, never
    /// deleted) and a new one is made. `.notSent` leaves the reports on the phone, to offer again.
    func deliver(_ text: String, clientId: String, person: String?) async -> Outcome {
        guard let person = person?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !person.isEmpty else {
            return .notSent
        }
        var room = rooms.room(for: person)
        // Three rooms at most, the kept one counting as one: a room made a moment ago that already has someone else in
        // it, or cannot be read, is not made again and again.
        for _ in 0..<3 {
            if room == nil {
                let id = makeId()
                do {
                    let made = try await api.createReportRoom(title: Self.roomTitle, maxMembers: Self.roomSize,
                                                              sessionId: id, idempotencyKey: "create-" + id)
                    room = ReportRoom(sessionId: made, supportUserId: nil)
                } catch {
                    return .notSent
                }
                if let room { rooms.keep(room, for: person) }
            }
            guard let current = room else { return .notSent }
            let membership: RoomMembershipSnapshot
            do {
                membership = try await api.reportRoomMembership(sessionId: current.sessionId)
            } catch SessionTransportError.accessDenied {
                // Deleted, or no longer this person's: a new one.
                rooms.forgetAll()
                room = nil
                continue
            } catch {
                return .notSent
            }
            guard ReportRoomSafety.others(in: membership, viewer: person, support: current.supportUserId).isEmpty else {
                note("reports room not theirs alone: a new one is made")
                rooms.forgetAll()
                room = nil
                continue
            }
            do {
                try await api.sendReport(sessionId: current.sessionId, text: text, clientId: clientId)
            } catch RoomSendError.notAllowed {
                rooms.forgetAll()
                room = nil
                continue
            } catch {
                return .notSent
            }
            await addSupport(to: current, person: person)
            return .sent(sessionId: current.sessionId)
        }
        return .notSent
    }

    /// Asks the team's account into the room once, after the report is in it. When that fails the report stays where
    /// it is and the team is asked again with the next one.
    private func addSupport(to room: ReportRoom, person: String) async {
        guard let supportLogin, room.supportUserId == nil else { return }
        guard let userId = try? await api.addReportRoomMember(sessionId: room.sessionId, login: supportLogin) else {
            return
        }
        var joined = room
        joined.supportUserId = userId
        rooms.keep(joined, for: person)
    }
}

/// The one offer to send crash reports, for the whole app, once each launch and only while the app is in front (not
/// when iOS starts it in the background for a call): "Send to the team" posts them in the person's own reports room
/// (`CrashReportDelivery`); "Not now" keeps them on the phone, where Settings shares them. Behind the root, watching
/// only the reports, so a new report draws this and not the root.
struct CrashReportOffer: View {
    let api: (any ReportRoomAPI)?
    let identity: any AccountIdentityProviding
    @ObservedObject private var crashes = CrashReporter.shared
    @Environment(\.scenePhase) private var scenePhase
    /// A moment has passed since the app opened, so iOS could hand over its own crash records first and both go together.
    @State private var settled = false
    @State private var offered = false
    @State private var presented = false

    static let message = "Send what the phone recorded to the team so it can be fixed? It goes to a private room of "
        + "yours that only the team is asked into. It has where the app stopped and your last few taps, never your "
        + "messages."

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .alert("Pocket closed unexpectedly", isPresented: $presented) {
                Button("Send to the team") { send(crashes.unhandled) }
                Button("Not now", role: .cancel) { crashes.markHandled(crashes.unhandled) }
            } message: {
                Text(Self.message)
            }
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                settled = true
                offer()
            }
            .onChange(of: crashes.unhandled.count) { _ in offer() }
            .onChange(of: scenePhase) { _ in offer() }
    }

    private func offer() {
        guard api != nil, settled, !offered, scenePhase == .active, !crashes.unhandled.isEmpty else { return }
        offered = true
        presented = true
    }

    private func send(_ reports: [CrashReport]) {
        guard let api, !reports.isEmpty else { return }
        CrashReporter.shared.note("crash report sent to the team")
        let delivery = CrashReportDelivery(api: api, rooms: ReportRoomStore.live, supportLogin: SupportMember.configured)
        Task { @MainActor in
            let person = await identity.currentAccount()?.accountId
            let outcome = await delivery.deliver(CrashReportText.message(reports),
                                                 clientId: CrashReportText.clientId(for: reports), person: person)
            // Handled only once the room has them: a report that did not get there is offered again next time.
            if case .sent = outcome { crashes.markHandled(reports) }
        }
    }
}
