import Foundation
import PocketUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Inviting people into a room from the phone, the two ways the web does (Carter, #55414: "How do I invite people to
/// rooms here like I used to do in web?"): a join link to share (`POST /invitations/join-links`), or an invite by
/// email or username (`POST /members`, which adds someone who already has an account and emails anyone else).
protocol RoomInviting: Sendable {
    func createInviteLink(sessionId: String, role: RoomInviteRole) async throws -> URL
    func invite(sessionId: String, who: String, role: RoomInviteRole) async throws -> RoomInviteOutcome
}

/// What an invitee can do in the room. Join links offer these two only (the API's `_JOIN_LINK_ROLES`).
enum RoomInviteRole: String, CaseIterable, Identifiable, Sendable {
    case contributor
    case viewer

    var id: String { rawValue }
    var name: String { self == .contributor ? "Contributor" : "Viewer" }
    var explainer: String {
        self == .contributor ? "Contributors read and post." : "Viewers read and react, but can't post."
    }
}

/// How an invite by email or username went.
enum RoomInviteOutcome: Equatable, Sendable {
    /// They already had an account and are in the room now.
    case added(String)
    /// An invitation is saved; the email went out, or didn't (and why).
    case invited(emailSent: Bool, reason: String?)

    /// The API's answer (`SessionMemberMutationResponse`): `member` when added, `invited`/`invitation` with
    /// `emailDelivery` when invited.
    init?(json data: Data, who: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["invited"] as? Bool == true || object["invitation"] is [String: Any] {
            let delivery = object["emailDelivery"] as? [String: Any]
            let reason = (delivery?["reason"] as? String) ?? (delivery?["status"] as? String)
            self = .invited(emailSent: delivery?["sent"] as? Bool ?? false, reason: reason?.isEmpty == false ? reason : nil)
        } else if let member = object["member"] as? [String: Any] {
            let name = ["displayName", "githubLogin", "login", "email"].lazy
                .compactMap { (member[$0] as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
            self = .added(name ?? who)
        } else {
            return nil
        }
    }

    var message: String {
        switch self {
        case .added(let name):
            return "\(name) is in the room now."
        case .invited(true, _):
            return "Invited. They'll get an email, and the room is waiting for them when they sign in."
        case .invited(false, let reason):
            let why = reason.map { " (\($0))" } ?? ""
            return "The invitation is saved, but the email didn't go out\(why). They can accept it from their Sessions page "
                + "once they sign in with that address, or send them the link instead."
        }
    }
}

/// What a refused invite means, from the status and the API's own message when it has one.
enum RoomInviteFailure {
    static func message(status: Int, data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = (object?["detail"] as? String)
            ?? ((object?["detail"] as? [String: Any])?["message"] as? String)
            ?? ((object?["error"] as? [String: Any])?["message"] as? String)
        switch status {
        case 403: return "Only the room's owner or an admin can invite people."
        case 404: return "No account has that name. Invite them by email, or send them the link."
        case 429: return "That's a lot of invites at once. Try again in a minute."
        default:
            if let detail, !detail.isEmpty, detail.count <= 240 { return detail }
            return "The invite didn't go through (error \(status)). Try again."
        }
    }
}

struct RoomInviteError: Error, Equatable {
    let message: String
}

extension HTTPRoomMessageSender: RoomInviting {
    func createInviteLink(sessionId: String, role: RoomInviteRole) async throws -> URL {
        let (data, http) = try await sessionMutation(
            sessionId: sessionId, path: "invitations/join-links",
            routeTemplate: "POST /api/v1/sessions/{session_id}/invitations/join-links",
            keyPrefix: "join-link", body: ["role": role.rawValue]
        )
        guard (200..<300).contains(http.statusCode) else {
            throw RoomInviteError(message: RoomInviteFailure.message(status: http.statusCode, data: data))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let link = (object?["inviteUrl"] as? String).flatMap(URL.init(string:)), link.scheme == "https" else {
            throw RoomInviteError(message: "The link came back empty. Try again.")
        }
        return link
    }

    func invite(sessionId: String, who: String, role: RoomInviteRole) async throws -> RoomInviteOutcome {
        let (data, http) = try await sessionMutation(
            sessionId: sessionId, path: "members",
            routeTemplate: "POST /api/v1/sessions/{session_id}/members",
            keyPrefix: "member", body: ["userIdentifier": who, "role": role.rawValue]
        )
        guard (200..<300).contains(http.statusCode) else {
            throw RoomInviteError(message: RoomInviteFailure.message(status: http.statusCode, data: data))
        }
        return RoomInviteOutcome(json: data, who: who) ?? .invited(emailSent: false, reason: nil)
    }
}

/// The invite sheet: the role first, then a link to share, or an invite by email or GitHub username.
struct RoomInviteSheet: View {
    let sessionId: String
    let roomTitle: String
    let inviter: any RoomInviting
    var onClose: () -> Void

    @State private var role: RoomInviteRole = .contributor
    @State private var link: URL?
    @State private var linkWorking = false
    @State private var linkProblem: String?
    @State private var copied = false
    @State private var who = ""
    @State private var inviting = false
    @State private var outcome: String?
    @State private var outcomeIsProblem = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("They join as", selection: $role) {
                        ForEach(RoomInviteRole.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pocket.invite.role")
                } header: {
                    Text("They join as")
                } footer: {
                    Text(role.explainer)
                }

                Section {
                    if let link {
                        ShareLink(item: link, subject: Text("Join \(roomTitle) on Senti"),
                                  message: Text("Join me in \(roomTitle) on Senti.")) {
                            Label("Share the link", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("pocket.invite.share")
                        Button {
                            copy(link)
                        } label: {
                            Label(copied ? "Copied" : "Copy the link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    } else {
                        Button {
                            Task { await makeLink() }
                        } label: {
                            Label(linkWorking ? "Making the link…" : "Make an invite link", systemImage: "link")
                        }
                        .disabled(linkWorking)
                        .accessibilityIdentifier("pocket.invite.makeLink")
                    }
                    if let linkProblem {
                        Text(linkProblem).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Invite link")
                } footer: {
                    Text("Anyone who opens it and signs in joins as a \(role.name.lowercased()).")
                }

                Section {
                    TextField("Email or GitHub username", text: $who)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                        .submitLabel(.send)
                        .onSubmit { Task { await invite() } }
                        .accessibilityIdentifier("pocket.invite.who")
                    Button(inviting ? "Inviting…" : "Invite") {
                        Task { await invite() }
                    }
                    .disabled(inviting || who.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("pocket.invite.send")
                    if let outcome {
                        Text(outcome)
                            .font(.footnote)
                            .foregroundStyle(outcomeIsProblem ? .red : .secondary)
                            .accessibilityIdentifier("pocket.invite.outcome")
                    }
                } header: {
                    Text("Invite by email or username")
                }
            }
            .navigationTitle("Invite people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
            // A link is made for one role.
            .onChange(of: role) { _ in
                link = nil
                copied = false
            }
        }
    }

    private func makeLink() async {
        linkWorking = true
        linkProblem = nil
        defer { linkWorking = false }
        do {
            link = try await inviter.createInviteLink(sessionId: sessionId, role: role)
        } catch let error as RoomInviteError {
            linkProblem = error.message
        } catch RoomSendError.reauthenticationRequired {
            linkProblem = "Sign in again to invite people."
        } catch {
            linkProblem = "The link couldn't be made. Check your connection and try again."
        }
    }

    private func invite() async {
        let name = who.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !inviting else { return }
        inviting = true
        outcome = nil
        defer { inviting = false }
        do {
            let result = try await inviter.invite(sessionId: sessionId, who: name, role: role)
            outcome = result.message
            if case .invited(false, _) = result { outcomeIsProblem = true } else { outcomeIsProblem = false }
            who = ""
        } catch let error as RoomInviteError {
            outcome = error.message
            outcomeIsProblem = true
        } catch RoomSendError.reauthenticationRequired {
            outcome = "Sign in again to invite people."
            outcomeIsProblem = true
        } catch {
            outcome = "The invite didn't go through. Check your connection and try again."
            outcomeIsProblem = true
        }
    }

    private func copy(_ link: URL) {
        #if canImport(UIKit)
        UIPasteboard.general.string = link.absoluteString
        #endif
        copied = true
    }
}
