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

    /// The catalog's ways to start, in its order (sentinelayer-api `src/data/agent_catalog/catalog.json`), word
    /// for word; the server's own list replaces them in the app.
    static let templates: [RoomTemplate] = [
        RoomTemplate(id: "personal-assistant",
                     name: "Personal assistant",
                     symbol: "person.crop.circle",
                     summary: "Your week, your lists and your follow-ups in one private room.",
                     roomType: "general",
                     starterAgents: ["pa01-personal-assistant"],
                     firstMessage: "I can plan your week, keep your lists and remind you what to follow up on. What "
                         + "is on your plate?"),
        RoomTemplate(id: "plan-a-trip",
                     name: "Plan a trip",
                     symbol: "airplane",
                     summary: "Dates, a day-by-day plan and a packing list for your next trip.",
                     roomType: "general",
                     starterAgents: ["pa01-personal-assistant"],
                     firstMessage: "I can help you pick dates, build a day-by-day plan and keep a packing list. "
                         + "Where are you headed?"),
        RoomTemplate(id: "budget-and-bills",
                     name: "Budget and bills",
                     symbol: "dollarsign.circle",
                     summary: "Your bills, due dates and a simple monthly budget, with reminders.",
                     roomType: "general",
                     starterAgents: ["pa01-personal-assistant"],
                     firstMessage: "Tell me your bills and when they are due, and I will keep the list, set "
                         + "reminders and help you plan a monthly budget."),
        RoomTemplate(id: "job-search",
                     name: "Job search",
                     symbol: "briefcase",
                     summary: "Track applications, get ready for interviews and never miss a follow-up.",
                     roomType: "general",
                     starterAgents: ["pa01-personal-assistant"],
                     firstMessage: "I can track your applications, help you get ready for interviews and remind you "
                         + "to follow up. What kind of job are you after?"),
        RoomTemplate(id: "side-project",
                     name: "Side project",
                     symbol: "hammer",
                     summary: "Turn an idea into steps, owners and a clear next move.",
                     roomType: "general",
                     starterAgents: ["cpg03-launch-coord"],
                     firstMessage: "I can turn your idea into steps, keep track of who does what and point out what "
                         + "is blocking you. What are you building?"),
        RoomTemplate(id: "family-and-home",
                     name: "Family and home",
                     symbol: "house",
                     summary: "The family calendar, shopping and chore lists, and reminders in one place.",
                     roomType: "general",
                     starterAgents: ["pa01-personal-assistant"],
                     firstMessage: "I can keep the family calendar, the shopping and chore lists, and reminders in "
                         + "one place. What is coming up this week?"),
        RoomTemplate(id: "study",
                     name: "Study",
                     symbol: "book",
                     summary: "Learn a topic step by step and keep track of what you still need to understand.",
                     roomType: "study",
                     starterAgents: [],
                     firstMessage: "I can explain a topic step by step, quiz you and keep a list of the questions "
                         + "you still have. What are you studying?"),
        RoomTemplate(id: "research",
                     name: "Research",
                     symbol: "magnifyingglass",
                     summary: "Gather sources, compare what they say and keep your findings in one list.",
                     roomType: "research",
                     starterAgents: [],
                     firstMessage: "I can gather sources, compare what they say and keep a list of findings with "
                         + "where each one came from. What do you want to find out?"),
        RoomTemplate(id: "conference",
                     name: "Conference",
                     symbol: "person.3",
                     summary: "Meetings with notes, action items and owners.",
                     roomType: "conference",
                     starterAgents: ["cpg03-launch-coord"],
                     firstMessage: "I can take notes, pull out the action items with an owner for each and write a "
                         + "short recap. What is the meeting about?"),
    ]

    @MainActor
    static var rootView: some View {
        let offered = stage == "kinds" ? nil : templates
        let picked = stage == "name" ? NewChatChoice.template(templates[0]) : nil
        return NewRoomSheet(creator: PreviewCreator(), templates: offered, picked: picked,
                            onCreated: { _, _ in }, onClose: {})
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ShotsDark") ? .dark : nil)
    }
}

/// Makes no chat: Create in the preview answers with a made-up id.
private struct PreviewCreator: RoomCreating {
    func create(title: String, start: RoomStart) async throws -> String { "preview-chat" }
}
#endif
