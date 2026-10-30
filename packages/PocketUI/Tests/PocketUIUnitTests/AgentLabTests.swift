import XCTest
@testable import PocketUI

/// Carter, #55428: "Whichever labs you come from put that icon there with its number badge and also pulsate ... to
/// show they're working. Or idle."
final class AgentLabTests: XCTestCase {
    func test_a_lab_comes_from_the_model_then_the_name() {
        XCTAssertEqual(AgentLab.of(id: "lab-box-1", model: "deepseek-v4-pro"), .deepseek)
        XCTAssertEqual(AgentLab.of(id: "anything", model: "gpt-6-astra"), .openai)
        XCTAssertEqual(AgentLab.of(id: "claude-warden", model: nil), .anthropic)
        XCTAssertEqual(AgentLab.of(id: "codex-helper", model: nil), .openai)
        XCTAssertEqual(AgentLab.of(id: "ds-room-warden", model: nil), .deepseek)
        XCTAssertEqual(AgentLab.of(id: "astra-council", model: nil), .openai)
        XCTAssertEqual(AgentLab.of(id: "kimi-max", model: nil), .moonshot)
        XCTAssertEqual(AgentLab.of(id: "ticket-keeper", model: "unknown"), .other)
        XCTAssertNil(AgentLab.other.initial, "an unknown lab shows a chip, not a letter")
    }

    func test_agents_here_group_by_lab_with_counts_and_whether_any_is_working() {
        let present = [
            RoomChatPresence.Person(id: "human-carter", name: "carter", isHuman: true, isIdle: false),
            RoomChatPresence.Person(id: "claude-warden", name: "claude-warden", isHuman: false, isIdle: true),
            RoomChatPresence.Person(id: "Claude-Warden", name: "claude-warden", isHuman: false, isIdle: false),
            RoomChatPresence.Person(id: "pocket-forge", name: "pocket-forge", isHuman: false, isIdle: false),
            RoomChatPresence.Person(id: "ds-box-1", name: "ds-box-1", isHuman: false, isIdle: true),
            RoomChatPresence.Person(id: "lab-box-2", name: "lab-box-2", isHuman: false, isIdle: false)
        ]
        let groups = AgentLab.groups(present: present, models: ["pocket-forge": "claude-opus", "lab-box-2": "deepseek-v4-flash"])
        XCTAssertEqual(groups, [
            AgentLab.Group(lab: .anthropic, count: 2, isWorking: true),
            AgentLab.Group(lab: .deepseek, count: 2, isWorking: true)
        ])
        let idle = AgentLab.groups(present: [present[4]], models: [:])
        XCTAssertEqual(idle, [AgentLab.Group(lab: .deepseek, count: 1, isWorking: false)])
    }
}
