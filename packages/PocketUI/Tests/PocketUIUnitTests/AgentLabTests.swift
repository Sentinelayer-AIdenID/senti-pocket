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
        XCTAssertEqual(AgentLab.of(id: "claude-warden", model: "deepseek-v4-pro"), .deepseek, "the model wins over the name")
        XCTAssertNil(AgentLab.other.initial, "an unknown lab shows a chip, not a letter")
    }

    /// Warden, #254: the match was on any substring.
    func test_a_lab_is_matched_on_whole_words_with_a_version_after_never_inside_a_word() {
        XCTAssertEqual(AgentLab.of(id: "octopus-helper", model: nil), .other, "opus inside octopus")
        XCTAssertEqual(AgentLab.of(id: "pocket-astra-test", model: nil), .other, "astra only as the name's start")
        XCTAssertEqual(AgentLab.of(id: "box", model: "gpt4o"), .openai, "a version right after the word")
        XCTAssertEqual(AgentLab.of(id: "box", model: "Claude-Opus-5-5"), .anthropic)
        XCTAssertEqual(AgentLab.of(id: "box", model: "glm-4.6"), .zhipu)
        XCTAssertEqual(AgentLab.of(id: "gptzero-fan", model: nil), .other, "letters after the word make another word")
    }
}

/// Carter, #55506: every agent's own lab logo, working ones first, capped then "+N".
final class AgentLogoTests: XCTestCase {
    private func person(_ id: String, human: Bool = false) -> RoomChatPresence.Person {
        RoomChatPresence.Person(id: id, name: id, isHuman: human, isIdle: false)
    }

    func test_each_agent_shows_once_working_first_with_its_labs_logo() {
        let present = [person("ds-box-1"), person("claude-warden"), person("CLAUDE-WARDEN"),
                       person("human-carter", human: true), person("astra-council")]
        let agents = AgentLab.present(present, models: [:], working: ["claude-warden", "astra-council"])
        XCTAssertEqual(agents.map(\.id), ["astra-council", "claude-warden", "ds-box-1"])
        XCTAssertEqual(agents.map(\.lab), [.openai, .anthropic, .deepseek])
        XCTAssertEqual(agents.map(\.isWorking), [true, true, false])
        XCTAssertEqual(AgentLab.anthropic.logoAsset, "LabClaude")
        XCTAssertNil(AgentLab.xai.logoAsset, "no logo carried: the initial shows")
    }

    func test_six_logos_show_then_a_count_of_the_rest() {
        let ids = (1...8).map { "box-\($0)" }
        let agents = AgentLab.present(ids.map { person($0) }, models: [:], working: ["box-8"])
        let cut = AgentLab.shown(agents)
        XCTAssertEqual(cut.shown.count, 6)
        XCTAssertEqual(cut.more, 2)
        XCTAssertEqual(cut.shown.first?.id, "box-8", "a working agent is never the one hidden")
        XCTAssertEqual(AgentLab.shown(Array(agents.prefix(6))).more, 0, "six fit with no count")
    }

    /// Warden, #254: presence stays "active" while an agent's listener is connected, so it pulsed all the time.
    func test_working_is_preparing_a_reply_or_a_post_in_the_last_two_minutes_not_presence() {
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        func input(_ id: String, _ author: String, minutesAgo: Double) -> RoomChatMessageInput {
            RoomChatMessageInput(id: id, sequenceId: Int64(1000 - minutesAgo), kind: .message, authorId: author,
                                 authorName: author, isHuman: author.hasPrefix("human-"), text: "x", timestamp: "",
                                 date: now.addingTimeInterval(-minutesAgo * 60))
        }
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [
                input("a", "ds-box-1", minutesAgo: 30),
                input("b", "Claude-Warden", minutesAgo: 1),
                input("c", "human-mrrcarter", minutesAgo: 0.5)
            ],
            composingAgents: ["astra-council"]
        )
        XCTAssertEqual(state.workingAgentIds(now: now), ["claude-warden", "astra-council"])
    }
}
