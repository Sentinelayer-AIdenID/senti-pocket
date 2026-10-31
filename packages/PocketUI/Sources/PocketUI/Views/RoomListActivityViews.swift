#if canImport(SwiftUI)
import SwiftUI

/// Who is in a room now, after how long ago it was active (Carter, 10-31): a person with how many people, a bot (the
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
                .imageScale(.small)
            Text(verbatim: "\(value)")
                .monospacedDigit()
        }
    }
}

/// A count in a badge on the right of a row, as Discord shows unread messages: the number, "99+" past 99, a circle
/// for one digit. Nothing at 0. The rooms, the bell and Waiting on you share it.
struct PocketCountBadge: View {
    let count: Int
    /// What VoiceOver says, which carries the whole count past 99.
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
                .accessibilityLabel(accessibilityText ?? "\(count) unread")
                .accessibilityIdentifier("pocket.rooms.unread")
        }
    }
}
#endif
