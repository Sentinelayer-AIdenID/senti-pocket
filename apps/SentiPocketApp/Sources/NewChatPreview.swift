#if DEBUG
import Foundation
import PocketSyncClient
import SwiftUI

/// DEBUG-only: `-PocketNewChatPreview` opens New chat on made-up ways to start, with no network and no sign-in, so it
/// can be built, run and screenshotted on a simulator. `-PocketNewChatStage` picks the screen: `start` (the Start with
/// cards, the default), `name` (the first made-up way to start, at its name step) or `kinds` (what shows where the
/// server offers none). `-ShotsDark` for screenshots taken from a UI test, which does not follow the simulator's
/// appearance. Never compiled into Release.
enum NewChatPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-PocketNewChatPreview") }

    static var stage: String { RootPreview.argument("-PocketNewChatStage") ?? "start" }

    /// The contract's seed (its ids, order, room types and starter agents). Names, symbols and summaries are stand-ins
    /// made from the ids and the starter agents until the API's own list can be read; the server's list replaces all
    /// of it in the app.
    static let templates: [RoomTemplate] = {
        let assistant = (id: "pa01-personal-assistant", name: "Personal Assistant",
                         symbol: "person.crop.circle.badge.checkmark")
        let launch = (id: "cpg03-launch-coord", name: "Launch Coordinator", symbol: "checklist")
        func startingWith(_ agent: (id: String, name: String, symbol: String), _ id: String,
                          _ name: String) -> RoomTemplate {
            RoomTemplate(id: id, name: name, symbol: agent.symbol, summary: "Starts with \(agent.name).",
                         starterAgents: [agent.id])
        }
        return [
            RoomTemplate(id: "personal-assistant", name: "Personal assistant", symbol: assistant.symbol,
                         summary: "Starts with \(assistant.name).", starterAgents: [assistant.id],
                         firstMessage: "Stand-in for the line Senti opens with; the server's own replaces it."),
            startingWith(assistant, "plan-a-trip", "Plan a trip"),
            startingWith(assistant, "budget-and-bills", "Budget and bills"),
            startingWith(assistant, "job-search", "Job search"),
            startingWith(launch, "side-project", "Side project"),
            startingWith(assistant, "family-and-home", "Family and home"),
            RoomTemplate(id: "study", name: "Study", symbol: RoomKind.study.symbol, summary: RoomKind.study.detail,
                         roomType: "study"),
            RoomTemplate(id: "research", name: "Research", symbol: RoomKind.research.symbol,
                         summary: RoomKind.research.detail, roomType: "research"),
            RoomTemplate(id: "conference", name: "Conference", symbol: RoomKind.conference.symbol,
                         summary: RoomKind.conference.detail, roomType: "conference",
                         starterAgents: [launch.id]),
        ]
    }()

    @MainActor
    static var rootView: some View {
        let offered = stage == "kinds" ? nil : templates
        let picked = stage == "name" ? NewChatChoice.template(templates[0]) : nil
        return NewRoomSheet(creator: PreviewCreator(), templates: offered, picked: picked,
                            onCreated: { _, _ in }, onClose: {})
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ShotsDark") ? .dark : nil)
    }
}

/// Makes nothing: the preview's Create only says it would.
private struct PreviewCreator: RoomCreating {
    func create(title: String, start: RoomStart) async throws -> String { "preview-chat" }
}
#endif
