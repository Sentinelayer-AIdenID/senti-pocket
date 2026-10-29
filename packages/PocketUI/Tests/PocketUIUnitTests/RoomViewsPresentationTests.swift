import Foundation
import XCTest
@testable import PocketUI

final class RoomViewsPresentationTests: XCTestCase {
    private let me = "aaaaaaaa-0000-4000-8000-000000000001"
    private let griff = "bbbbbbbb-0000-4000-8000-000000000002"
    private let sam = "cccccccc-0000-4000-8000-000000000003"
    private let names = ["human-bbbbbbbb-0000-4000-8000-000000000002": "griff"]
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func viewer(_ id: String, human: Bool = true) -> RoomChatViews.Viewer {
        RoomChatViews.Viewer(isHuman: human, actorId: id, viewedAt: at)
    }

    private func views(
        count: Int? = nil,
        _ viewers: [RoomChatViews.Viewer],
        selfViewed: Bool = false,
        author: String?
    ) -> RoomChatViews {
        RoomChatViews.make(
            viewedCount: count ?? viewers.count,
            viewers: viewers,
            selfViewed: selfViewed,
            authorActorId: author,
            ownAccountId: me,
            ownName: "mrrCarter",
            names: names,
            time: { _ in "10:42" }
        )
    }

    func test_the_line_names_viewers_like_the_web() {
        XCTAssertEqual(views([], author: nil).line, "Not yet viewed")
        XCTAssertEqual(views([viewer(griff)], author: nil).line, "Viewed by griff")
        XCTAssertEqual(views([viewer(griff), viewer("cobalt-warden", human: false)], author: nil).line,
                       "Viewed by griff and cobalt-warden", "an agent is named by its id")
        XCTAssertEqual(views([viewer(me), viewer(griff), viewer(sam), viewer("a1", human: false), viewer("a2", human: false)],
                             author: nil).line,
                       "Viewed by mrrCarter, griff, Signed-in viewer and 2 more",
                       "you by your login; a person presence never named is not shown by id")
        XCTAssertEqual(views(count: 7, [viewer(griff)], author: nil).line, "Viewed by griff and 6 more",
                       "views beyond the listed viewers are counted")
        XCTAssertEqual(views(count: 4, [], author: nil).line, "Viewed by 4 viewers")
    }

    func test_your_own_view_of_your_message_does_not_tick_it() {
        let own = views([viewer(me)], selfViewed: true, author: me)
        XCTAssertEqual(own.ticks, .sent, "the web shows this as seen; it is only you")
        XCTAssertEqual(own.seenBy, "Not yet seen")
        XCTAssertEqual(own.line, "Viewed by mrrCarter", "the line still lists every viewer, as on the web")

        let read = views([viewer(me), viewer(griff)], selfViewed: true, author: me)
        XCTAssertEqual(read.ticks, .seen)
        XCTAssertEqual(read.seenBy, "Seen by griff at 10:42")
    }

    func test_an_agent_author_is_left_out_and_others_count() {
        let agentMessage = views([viewer("cobalt-warden", human: false), viewer(me)], selfViewed: true, author: "cobalt-warden")
        XCTAssertEqual(agentMessage.ticks, .seen)
        XCTAssertEqual(agentMessage.seenBy, "Seen by You at 10:42")

        let unlisted = views(count: 6, [viewer(griff), viewer(sam), viewer(me), viewer("a1", human: false)], author: nil)
        XCTAssertEqual(unlisted.seenBy, "Seen by griff at 10:42, Signed-in viewer at 10:42, You at 10:42 and 3 more")
        XCTAssertEqual(views(count: 2, [], author: nil).seenBy, "Seen by 2 viewers")
    }

    func test_presence_counts_people_and_lists_them_before_agents() {
        let people = [
            RoomChatPresence.Person(id: "cobalt-warden", name: "cobalt-warden", isHuman: false, isIdle: false),
            RoomChatPresence.Person(id: "human-x", name: "griff", isHuman: true, isIdle: true)
        ]
        let presence = RoomChatPresence.make(isAvailable: true, humansOnline: 1, people: people)
        XCTAssertEqual(presence.label, "1 human here")
        XCTAssertEqual(presence.compactCount, "1")
        XCTAssertEqual(presence.people.map(\.name), ["griff", "cobalt-warden"])
        XCTAssertEqual(RoomChatPresence.make(isAvailable: true, humansOnline: 3, people: []).label, "3 humans here")
        XCTAssertEqual(RoomChatPresence.make(isAvailable: true, humansOnline: 0, people: []).label, "0 humans here")
        let unknown = RoomChatPresence.make(isAvailable: false, humansOnline: nil, people: people)
        XCTAssertEqual(unknown.label, "presence unavailable")
        XCTAssertEqual(unknown.compactCount, "?", "unknown never reads as zero")
        XCTAssertTrue(unknown.people.isEmpty, "unknown is never shown as an empty room")
    }
}
