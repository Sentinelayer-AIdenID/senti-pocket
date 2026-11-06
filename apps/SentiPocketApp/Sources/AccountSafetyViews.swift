import Foundation
import SwiftUI
import PocketUI
import UIKit

// SUPPORT CONTACT: the one address the app gives for help, and the policies (Settings, sign-in, the AI notice) are
// `PocketHelp` in PocketUI. To change them, change them there.
enum PocketSupport {
    static let email = PocketHelp.email

    static var mailURL: URL? { PocketHelp.mailURL }
}

/// Settings, Account: "Contact us", with the address, opening Mail.
struct SupportContactRow: View {
    var body: some View {
        if let url = PocketSupport.mailURL {
            Link(destination: url) {
                // Side by side where they fit; at large text sizes the address goes under the words, whole.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label("Contact us", systemImage: "envelope")
                        Spacer(minLength: 8)
                        Text(PocketSupport.email)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Contact us", systemImage: "envelope")
                        Text(PocketSupport.email)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // The address can be copied, for a phone without Mail set up.
            .contextMenu {
                Button {
                    UIPasteboard.general.string = PocketSupport.email
                } label: {
                    Label("Copy address", systemImage: "doc.on.doc")
                }
            }
            .accessibilityAction(named: "Copy address") { UIPasteboard.general.string = PocketSupport.email }
            .accessibilityIdentifier("settings.account.support")
        }
        Link(destination: PocketHelp.termsURL) {
            Label("Terms of Use", systemImage: "doc.text")
        }
        .accessibilityIdentifier("settings.account.terms")
        Link(destination: PocketHelp.privacyURL) {
            Label("Privacy Policy", systemImage: "hand.raised.square")
        }
        .accessibilityIdentifier("settings.account.privacy")
    }
}

/// Settings, Account, Blocked people: everyone this account blocked, people and agents, each with Unblock. Read again
/// from the server when it opens; before the API has blocks, or offline, the phone's copy shows.
struct BlockedPeopleView: View {
    @ObservedObject var blocks: BlockList

    var body: some View {
        List {
            if let refusal = blocks.refusal {
                Section {
                    Text(refusal)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.blocked.refusal")
                    Button("OK") { blocks.refusal = nil }
                }
            }
            if blocks.blocked.isEmpty {
                Text("You haven't blocked anyone.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.blocked.empty")
            } else {
                Section {
                    ForEach(blocks.blocked) { person in
                        HStack(spacing: 12) {
                            Image(systemName: person.actorId.hasPrefix("human-") ? "person.crop.circle" : "cpu")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name)
                                    .lineLimit(1)
                                Text(person.actorId.hasPrefix("human-") ? "Person" : "Agent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Unblock") { blocks.unblock(person.actorId) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Unblock \(person.name)")
                                .accessibilityIdentifier("settings.blocked.unblock.\(person.actorId)")
                        }
                    }
                } footer: {
                    Text(Self.covers)
                }
            }
        }
        .navigationTitle("Blocked people")
        .task { await blocks.sync() }
    }

    /// What blocking covers, as the question before it says it.
    static let covers: String = "Their messages and replies show as one line in every room, with Show to see one, "
        + "and room search hides their words. \(RoomBlocking.calls) \(RoomBlocking.byId) They aren't told when you "
        + "block or unblock them."
}

/// Settings, Account, AI and your messages: what the room's AI agents read, and the OK this account gave, which it can
/// withdraw. Withdrawn, the next send in a room with agents asks again.
struct AIConsentSettingsView: View {
    @ObservedObject var consent: AIConsent

    var body: some View {
        Form {
            Section {
                Text(AIConsentText.notice)
                    .accessibilityIdentifier("settings.aiConsent.notice")
            }
            Section {
                if let givenAt = consent.givenAt {
                    LabeledContent("You agreed", value: givenAt.formatted(date: .abbreviated, time: .omitted))
                    Button("Withdraw", role: .destructive) { consent.withdraw() }
                        .accessibilityIdentifier("settings.aiConsent.withdraw")
                } else {
                    Text("Not given. Pocket asks the next time you write in a room: a message, a reply, a file, a "
                         + "ticket or a call.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.aiConsent.notGiven")
                }
            } footer: {
                if consent.isGiven {
                    Text("Withdrawing doesn't remove what you already shared. Until you agree again, Pocket on this "
                         + "phone asks before you write in any room. Signing out forgets your answer here.")
                }
            }
        }
        .navigationTitle("AI and your messages")
    }
}

/// Settings, Account: Blocked people, AI and your messages, and the support contact.
struct AccountSafetyRows: View {
    let blocks: BlockList?
    let aiConsent: AIConsent?

    var body: some View {
        if let blocks {
            NavigationLink {
                BlockedPeopleView(blocks: blocks)
            } label: {
                Label("Blocked people", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("settings.account.blocked")
        }
        if let aiConsent {
            NavigationLink {
                AIConsentSettingsView(consent: aiConsent)
            } label: {
                Label("AI and your messages", systemImage: "cpu")
            }
            .accessibilityIdentifier("settings.account.aiConsent")
        }
        SupportContactRow()
    }
}
