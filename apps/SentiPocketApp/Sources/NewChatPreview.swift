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

    /// Made up for screenshots; the server's own list replaces them in the app.
    static let templates: [RoomTemplate] = [
        RoomTemplate(id: "preview-week", name: "Plan my week", symbol: "calendar",
                     summary: "Your week, your lists and your follow-ups in one place.",
                     firstMessage: "Tell me what's coming up and I'll lay out your week, with time for what matters."),
        RoomTemplate(id: "preview-study", name: "Study together", symbol: "book",
                     summary: "Notes, explanations and practice questions with friends.", roomType: "study"),
        RoomTemplate(id: "preview-research", name: "Research", symbol: "magnifyingglass",
                     summary: "Sources, findings and a written answer you can check.", roomType: "research"),
        RoomTemplate(id: "preview-meetings", name: "Meetings", symbol: "person.3",
                     summary: "An agenda, live notes and the follow-ups.", roomType: "conference"),
        RoomTemplate(id: "preview-trip", name: "Plan a trip", symbol: "airplane",
                     summary: "Dates, places and a packing list everyone can see."),
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

/// Makes nothing: the preview's Create only says it would.
private struct PreviewCreator: RoomCreating {
    func create(title: String, start: RoomStart) async throws -> String { "preview-chat" }
}
#endif
