import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI

/// The chat a New agent starts in when it starts in a new chat (sentinelayer-web `newAgentChatTitle`).
enum NewAgentChat {
    /// Members a chat started for one agent may hold: the web's (the Sessions page's own default).
    static let maxMembers = 4
    /// How much of the job the title carries.
    static let jobExcerpt = 60

    /// What the chat is called while the mint has still to name its agent: a start with no name and no job words that
    /// can be a title. Renamed to the agent's name once the mint answers (`AgentStartModel`).
    static let untitled = "Agent chat"

    /// The chat's name, never "New agent" (Carter, #61655: a chat made for an agent is called what it is for):
    /// "<name> · <the job's first 60 characters>" on one line, within the room-title cap, counted in code points as on
    /// the web; the job's words alone when the mint will make the name; the name alone with no job words. Nil when
    /// neither makes a title the API takes: the chat is `untitled` until the mint names its agent.
    static func title(agentName: String, job: String) -> String? {
        let name = oneLine(agentName)
        let excerpt = String(String.UnicodeScalarView(withoutLeadingMarks(oneLine(job)).unicodeScalars.prefix(jobExcerpt)))
            .trimmingCharacters(in: .whitespaces)
        let candidates = [name.isEmpty || excerpt.isEmpty ? "" : "\(name) · \(excerpt)", excerpt, name]
        for candidate in candidates where !candidate.isEmpty {
            let capped = String(String.UnicodeScalarView(candidate.unicodeScalars.prefix(RoomTitle.maximumLength)))
                .trimmingCharacters(in: .whitespaces)
            if let cleaned = RoomTitle.cleaned(capped) { return cleaned }
        }
        return nil
    }

    /// Control characters out, and every run of white space one space (the web's `oneLine`).
    private static func oneLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A job written as Markdown ("- fix the build", "## Fix"): its words without the marks a room title may not
    /// start with (`RoomTitle.cleaned`).
    private static func withoutLeadingMarks(_ text: String) -> String {
        var words = Substring(text)
        while let first = words.first, "#>*-".contains(first) {
            words = words.drop { "#>*-".contains($0) }.drop { $0 == " " }
        }
        return String(words)
    }
}

/// Whether the room offers New agent (sentinelayer-web `SessionMintProvider`, on for admins): to the room's owners and
/// admins, in a room of its own (a breakout has no agents of its own in v1-a), once the mint lists models for this
/// account, which it does only for accounts it admits. A button the mint would refuse is worse than none.
@MainActor
final class NewAgentOffer: ObservableObject {
    @Published private(set) var isOffered = false

    /// The waits before asking again when the mint gave no answer (unreachable, or busy).
    static let retryWaits: [TimeInterval] = [3, 10]

    /// Nil for anyone the room does not offer it to: they never ask the mint.
    private let mint: (any MintStarting)?
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// The mint answered for this account (its models, or a refusal): not asked again on this room screen.
    private var answered = false
    private var asking = false

    init(role: String, isBreakout: Bool, isDirect: Bool = false, mint: (any MintStarting)?,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.mint = Self.admits(role: role, isBreakout: isBreakout, isDirect: isDirect) ? mint : nil
        self.sleep = sleep
    }

    /// Owners and admins (the API's roles), in a room that is neither a breakout nor a direct message (the API refuses a
    /// new agent in a direct room). An unknown role offers nothing.
    static func admits(role: String, isBreakout: Bool, isDirect: Bool = false) -> Bool {
        !isBreakout && !isDirect && ["owner", "admin"].contains(role.lowercased())
    }

    /// Asks the mint until it answers for this account. No answer is asked again after a short wait, twice, and again
    /// each time the room is shown, so a network blip does not hide the button for the whole visit.
    func check() async {
        guard let mint, !answered, !asking else { return }
        asking = true
        defer { asking = false }
        for wait in [0] + Self.retryWaits {
            if wait > 0 { await sleep(wait) }
            if Task.isCancelled { return }
            do {
                let models = try await mint.models()
                answered = true
                isOffered = !models.isEmpty
                return
            } catch MintError.unavailable, MintError.capacity {
                continue
            } catch {
                if Task.isCancelled { return }
                answered = true
                return
            }
        }
    }
}

/// Who pays for the agent's model: today only the mint's own plan. The web's coming "Bring your own LLM" (your own
/// model plan or key) becomes a second case here, and with it a tab over the sheet's form, once its API is built; the
/// start, its key and its record on the phone stay as they are.
enum AgentFunding: String, CaseIterable, Identifiable {
    case mint

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mint: return "Mint"
        }
    }
}

/// The room's New agent (sentinelayer-web `NewAgentDialog`, from the button beside the room's title): where the agent
/// works, this chat or a new private chat made for it, over the start form. Like a ticket's agent, a start is kept on
/// the phone before it is sent, and one whose outcome is not known is checked again under its own key.
struct NewAgentSheet: View {
    @StateObject private var model: AgentStartModel
    @Environment(\.dismiss) private var dismiss
    @State private var funding: AgentFunding = .mint
    private let roomTitle: String
    /// Opens the new chat the agent started in.
    private let onOpenChat: @MainActor (RoomRoute) -> Void

    init(sessionId: String, roomTitle: String, mint: any MintStarting, chats: (any AgentChatCreating)?,
         onOpenChat: @escaping @MainActor (RoomRoute) -> Void) {
        self.init(
            model: AgentStartModel(newAgentIn: sessionId, mint: mint, chats: chats, ledger: .standard,
                                   account: RoomSendOutbox.account(token: SessionTokenStore.load())),
            roomTitle: roomTitle,
            onOpenChat: onOpenChat
        )
    }

    init(model: @autoclosure @escaping () -> AgentStartModel, roomTitle: String,
         onOpenChat: @escaping @MainActor (RoomRoute) -> Void) {
        _model = StateObject(wrappedValue: model())
        self.roomTitle = roomTitle
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        NavigationStack {
            Form {
                if AgentFunding.allCases.count > 1 {
                    Section {
                        Picker("Who pays", selection: $funding) {
                            ForEach(AgentFunding.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                switch funding {
                case .mint:
                    mintSections
                }
            }
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isStarted ? "Done" : "Cancel") { dismiss() }
                        .disabled(isStarting)
                        .accessibilityIdentifier("pocket.newAgent.close")
                }
            }
            .interactiveDismissDisabled(isStarting)
            .task { await model.load() }
            // Started in a new chat: Pocket goes there by itself (Carter, #60742); the button stays for a sheet that
            // opens on a start already made.
            .onChange(of: Self.chatToOpen(model.phase, startedChat: model.startedChat)) { route in
                if let route { onOpenChat(route) }
            }
        }
    }

    /// The chat Pocket opens once the agent started in a new one; nil for a start in this chat or one not started.
    /// You made the chat, so you own it.
    static func chatToOpen(_ phase: AgentStartModel.Phase, startedChat: MintStartLedger.NewChat?) -> RoomRoute? {
        guard case .started = phase, let chat = startedChat else { return nil }
        return RoomRoute(sessionId: chat.sessionId, title: chat.title, membershipRole: "owner")
    }

    @ViewBuilder
    private var mintSections: some View {
        switch model.phase {
        case .loading:
            Section { ProgressView("Asking the mint for its models…") }
        case .started(let started):
            startedSection(started)
        default:
            if model.offersNewChat {
                placeSection
            }
            AgentStartForm(
                model: model,
                namePrompt: "Generated when empty",
                jobFooter: "It posts a short plan in the room and works on its own machine.",
                jobPlaceholder: "What the agent should do, what done looks like, and where to report."
            )
        }
    }

    /// The web's "Where the agent works", in the New room sheet's way of choosing.
    private var placeSection: some View {
        Section {
            placeRow(.thisChat, title: "Start in this chat", symbol: "bubble.left",
                     detail: "It joins \(roomTitle.isEmpty ? "this room" : roomTitle) with its skills loaded.")
            placeRow(.newChat, title: "Start in a new chat", symbol: "plus.bubble",
                     detail: model.keptChat.map { "It goes to \($0.title), the chat made for your last try." }
                        ?? "A new private chat is made for it. You can go there once it starts.")
        } header: {
            Text("Where the agent works")
        }
    }

    private func placeRow(_ place: AgentStartModel.Place, title: String, symbol: String, detail: String) -> some View {
        Button {
            model.place = place
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                // The label's own colors: in a button, `.primary` would be the button's tint.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Color.primary)
                    Text(detail).font(.footnote).foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                if model.place == place {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        // Chosen with the start: a start being sent or checked keeps where it was sent.
        .disabled(model.phase != .ready)
        .accessibilityIdentifier(place == .thisChat ? "pocket.newAgent.thisChat" : "pocket.newAgent.newChat")
        .accessibilityAddTraits(model.place == place ? .isSelected : [])
    }

    private var isStarting: Bool {
        if case .starting = model.phase { return true }
        return false
    }

    private var isStarted: Bool {
        if case .started = model.phase { return true }
        return false
    }

    @ViewBuilder
    private func startedSection(_ started: MintUpResponse) -> some View {
        if let chat = model.startedChat {
            Section {
                Label("\(started.agentName) is starting in a new chat.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.teal)
                Text("It will post a short plan in the new chat, “\(chat.title)”. Its box shows in that chat's Room info.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    if let route = Self.chatToOpen(model.phase, startedChat: chat) { onOpenChat(route) }
                } label: {
                    Label("Go to the new chat", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pocket.newAgent.openChat")
            }
        } else {
            Section {
                Label("\(started.agentName) is starting on its own machine.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.teal)
                Text("It will post a short plan in the room. Its box shows in Room info.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
