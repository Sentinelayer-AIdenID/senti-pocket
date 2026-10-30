import Foundation
import XCTest
@testable import PocketUI

final class RoomRosterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String, _ minutesAgo: Double, human: Bool = false) -> RoomRoster.Post {
        RoomRoster.Post(authorId: id, name: id, isHuman: human, at: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Carter (10-30): everyone who came, not only who is here, with green, gray or red, and what each one is.
    func test_everyone_who_came_is_listed_with_how_they_are() throws {
        let roster = RoomRoster.build(
            posts: [
                post("human-mrrcarter", 2, human: true), post("human-mrrcarter", 90, human: true),
                post("claude-warden", 30), post("old-agent", 300), post("respawn-orchestrator", 1),
                post("ds-old-box", 200), post("ds-live-box", 3)
            ],
            present: [
                RoomChatPresence.Person(id: "human-mrrcarter", name: "mrrcarter", isHuman: true, isIdle: false),
                RoomChatPresence.Person(id: "pocket-forge", name: "pocket-forge", isHuman: false, isIdle: true)
            ],
            runningBoxes: [RoomRoster.Box(name: "ds-live-box", model: "deepseek-v4-pro", effort: "high", phase: "working",
                                          job: "Fix the bell", lastActivity: now.addingTimeInterval(-60))],
            endedBoxes: ["ds-old-box"],
            now: now
        )
        let byId = Dictionary(uniqueKeysWithValues: roster.members.map { ($0.id, $0) })
        XCTAssertNil(byId["respawn-orchestrator"], "the room's own services are not people in it")
        XCTAssertEqual(byId["human-mrrcarter"]?.status, .here)
        XCTAssertEqual(byId["human-mrrcarter"]?.posts, 2)
        XCTAssertEqual(byId["human-mrrcarter"]?.timeHere, 88 * 60, "from the first post seen to the last")
        XCTAssertEqual(byId["pocket-forge"]?.status, .idle, "here but idle")
        XCTAssertEqual(byId["claude-warden"]?.status, .idle, "heard from within the hour")
        XCTAssertEqual(byId["old-agent"]?.status, .gone)
        XCTAssertEqual(byId["ds-old-box"]?.status, .ended)
        XCTAssertEqual(byId["ds-old-box"]?.kind, .box)
        let live = try XCTUnwrap(byId["ds-live-box"])
        XCTAssertEqual(live.status, .here, "active a minute ago")
        XCTAssertEqual(live.model, "deepseek-v4-pro")
        XCTAssertEqual(live.effort, "high")
        XCTAssertEqual(live.job, "Fix the bell")
        XCTAssertEqual(roster.members.map(\.status), roster.members.map(\.status).sorted(), "here first, then idle, gone, ended")
    }

    /// Carter, #55524: "the presence indicator said I was idle and I moved to active but it kept my name in idle
    /// still". Presence names a person `human-<user id>` and gives their login (API #1055); their posts are
    /// `human-<login>`.
    func test_a_person_here_is_one_member_with_their_posts_and_here_if_any_device_is() throws {
        let account = "human-6c1f2a9e-0b7d-4c55-9e2a-1f0d3b8a7c42"
        let roster = RoomRoster.build(
            posts: [post("human-mrrcarter", 2, human: true), post("human-mrrcarter", 30, human: true)],
            present: [
                RoomChatPresence.Person(id: account, name: "mrrCarter", isHuman: true, isIdle: true, login: "mrrCarter"),
                RoomChatPresence.Person(id: account, name: "mrrCarter", isHuman: true, isIdle: false, login: "mrrCarter")
            ],
            runningBoxes: [], endedBoxes: [], now: now
        )
        let people = roster.members.filter { $0.kind == .person }
        XCTAssertEqual(people.count, 1, "not one here and one idle")
        let carter = try XCTUnwrap(people.first)
        XCTAssertEqual(carter.id, "human-mrrcarter")
        XCTAssertEqual(carter.status, .here, "active on one device is here")
        XCTAssertEqual(carter.posts, 2)
    }

    func test_a_person_without_a_login_matches_their_posts_by_account() throws {
        let account = "human-0d9e8f7a-1111-4222-8333-944455556666"
        let roster = RoomRoster.build(
            posts: [post(account, 5, human: true)],
            present: [RoomChatPresence.Person(id: account, name: "jake", isHuman: true, isIdle: false)],
            runningBoxes: [], endedBoxes: [], now: now
        )
        XCTAssertEqual(roster.members.count, 1)
        XCTAssertEqual(roster.members.first?.status, .here)
        XCTAssertEqual(roster.members.first?.posts, 1)
    }

    func test_a_box_that_ended_but_runs_again_under_its_name_is_listed_once_as_running() {
        let roster = RoomRoster.build(
            posts: [], present: [],
            runningBoxes: [RoomRoster.Box(name: "ds-web", model: "m", phase: "ready", lastActivity: nil)],
            endedBoxes: ["ds-web"], now: now
        )
        XCTAssertEqual(roster.members.count, 1)
        XCTAssertEqual(roster.members.first?.status, .idle, "running, quiet for now")
    }
}
