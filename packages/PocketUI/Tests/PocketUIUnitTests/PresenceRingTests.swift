import XCTest
@testable import PocketUI

/// Carter (10-30): "Make it start curving around 6 and allow it to for a full circumference from there that goes all
/// the way to the back ... you can scroll that circle ... it's endless and can add as many as possible".
final class PresenceRingTests: XCTestCase {
    func test_up_to_six_sit_on_an_arc_centred_under_the_count_and_more_go_round_a_ring() {
        XCTAssertFalse(PresenceRingLayout.isRing(6))
        XCTAssertTrue(PresenceRingLayout.isRing(7))

        let arc = (0..<4).map { PresenceRingLayout.spot(index: $0, count: 4, rotation: 0) }
        XCTAssertEqual(arc[0].x, -arc[3].x, accuracy: 0.001, "the arc is even either side")
        XCTAssertEqual(arc[1].x, -arc[2].x, accuracy: 0.001)
        XCTAssertEqual(PresenceRingLayout.spot(index: 1, count: 3, rotation: 0).x, 0, accuracy: 0.001,
                       "the arc is centred: the count sits above it, not in its middle (Carter, 10-30)")
        XCTAssertEqual(PresenceRingLayout.spot(index: 0, count: 1, rotation: 0).x, 0, accuracy: 0.001, "one logo, centred")
        XCTAssertLessThan(arc[0].y, arc[1].y, "the ends curve back")
        XCTAssertEqual(PresenceRingLayout.spot(index: 0, count: 4, rotation: 1).x, arc[0].x, "the arc does not turn")
    }

    func test_the_ring_puts_the_front_large_and_bright_and_the_back_small_dim_and_higher() {
        let front = PresenceRingLayout.spot(index: 0, count: 8, rotation: 0)
        let back = PresenceRingLayout.spot(index: 4, count: 8, rotation: 0)
        XCTAssertEqual(front.depth, 1, accuracy: 0.001)
        XCTAssertEqual(front.x, 0, accuracy: 0.001)
        XCTAssertEqual(back.depth, -1, accuracy: 0.001)
        XCTAssertGreaterThan(front.scale, back.scale)
        XCTAssertGreaterThan(front.opacity, back.opacity)
        XCTAssertLessThan(back.y, front.y, "the back of the ring sits higher")
    }

    func test_turning_the_ring_brings_each_logo_to_the_front_in_turn() {
        let step = 2 * Double.pi / 8
        XCTAssertEqual(PresenceRingLayout.frontIndex(count: 8, rotation: 0), 0)
        XCTAssertEqual(PresenceRingLayout.frontIndex(count: 8, rotation: -step), 1)
        XCTAssertEqual(PresenceRingLayout.frontIndex(count: 8, rotation: step), 7, "either way round")
        XCTAssertEqual(PresenceRingLayout.frontIndex(count: 8, rotation: -8 * step), 0, "endless")
        XCTAssertNil(PresenceRingLayout.frontIndex(count: 5, rotation: 0), "the arc has no front to pass")
    }

    /// Carter (10-30): "whenever each one sends a message it scrolls to that one".
    func test_an_agent_that_just_posted_is_brought_to_the_front_the_short_way_round() {
        let count = 8
        let step = 2 * Double.pi / Double(count)
        for index in 0..<count {
            for start in [0, 1.3, -5.0, 40.0] {
                let turned = PresenceRingLayout.rotation(bringingToFront: index, count: count, from: start)
                XCTAssertEqual(PresenceRingLayout.frontIndex(count: count, rotation: turned), index)
                XCTAssertLessThanOrEqual(abs(turned - start), Double.pi + 0.0001, "never the long way round")
            }
        }
        XCTAssertEqual(PresenceRingLayout.rotation(bringingToFront: 7, count: count, from: 0), step, accuracy: 0.0001,
                       "one step back, not seven forward")
    }

    /// Carter (10-30): idle but not destroyed stays on the ring, greyed; a working agent is never greyed.
    func test_an_idle_agent_is_greyed_unless_it_is_working() {
        let present = [
            RoomChatPresence.Person(id: "pocket-forge", name: "pocket-forge", isHuman: false, isIdle: true),
            RoomChatPresence.Person(id: "claude-warden", name: "claude-warden", isHuman: false, isIdle: true),
            RoomChatPresence.Person(id: "sol-max", name: "sol-max", isHuman: false, isIdle: false)
        ]
        let agents = AgentLab.present(present, models: [:], signals: ["claude-warden": "m1"], boxes: ["astra-box"])
        let idle = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.isIdle) })
        XCTAssertEqual(idle["pocket-forge"], true)
        XCTAssertEqual(idle["claude-warden"], false, "it just posted: working, not greyed")
        XCTAssertEqual(idle["sol-max"], false)
        XCTAssertEqual(idle["astra-box"], true, "a running box not heard from waits greyed")
    }
}
