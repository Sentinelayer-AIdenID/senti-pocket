#if canImport(SwiftUI)
import SwiftUI

/// Who is in a room now, after how long ago it was active: a person with how many people, a bot (the
/// app's agent mark, as in the people list) with how many agents. Each hides at 0, and the whole is one element that
/// says it in words ("3 people and 2 agents online"). It takes the font and colour of the text around it.
struct RoomOnlineCounts: View {
    let activity: RoomListActivity

    var body: some View {
        if let description = activity.onlineDescription {
            HStack(spacing: 6) {
                if activity.showsHumans { count(activity.humansOnline, symbol: "person.fill") }
                if activity.showsAgents { count(activity.agentsOnline, symbol: "cpu") }
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
            .accessibilityIdentifier("pocket.rooms.online")
        }
    }

    private func count(_ value: Int, symbol: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text(verbatim: "\(value)")
                .monospacedDigit()
        }
    }
}

/// A count in a badge on the right of a row, as Discord shows unread messages: the number, "99+" past 99, a circle
/// for one digit. Nothing at 0. The rooms, the bell and Waiting on you share it.
struct PocketCountBadge: View {
    let count: Int
    /// What VoiceOver says; "5 unread" or "more than 99 unread" when not given.
    let accessibilityText: String?
    /// One digit is a circle: as wide as the badge is tall, at every text size.
    @ScaledMetric(relativeTo: .caption) private var minimumWidth: CGFloat = 20

    init(count: Int, accessibilityText: String? = nil) {
        self.count = count
        self.accessibilityText = accessibilityText
    }

    var body: some View {
        if let text = RoomListActivity.badgeText(for: count) {
            Text(verbatim: text)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: minimumWidth)
                .background(PocketPalette.accent, in: Capsule())
                .fixedSize()
                .accessibilityLabel(accessibilityText ?? RoomListActivity.unreadDescription(for: count) ?? text)
                .accessibilityIdentifier("pocket.rooms.unread")
        }
    }
}

/// How long ago, in the side panel's words, kept current each minute: "just now" within the minute (never "now ago"),
/// else "5m ago", "3h ago", "2d ago". In place of iOS's ticking relative time ("42 min, 12 sec"), which reads like a
/// timer (Carter, 2026-11-06, ticket 693f0cc5). It takes the font and colour of the text around it.
struct AgoText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.words(date, now: context.date))
        }
    }

    static func words(_ date: Date, now: Date = Date()) -> String {
        let age = PocketSidePanel.compactAge(of: date, now: now)
        return age == "now" ? "just now" : "\(age) ago"
    }
}
#endif
