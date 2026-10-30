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
        XCTAssertEqual(AgentLab.of(id: "pocket-forge", model: nil, reported: "anthropic"), .anthropic,
                       "Carter, #55533: forge is Claude, as the server says from its model")
        XCTAssertEqual(AgentLab.of(id: "claude-like-name", model: nil, reported: "deepseek"), .deepseek,
                       "the server's lab wins over the name")
        XCTAssertEqual(AgentLab.of(id: "astra-brand-s", model: nil, reported: "other"), .openai,
                       "an agent that sent no model is guessed from its name")
        XCTAssertEqual(AgentLab.of(id: "sol-max", model: nil, reported: "other"), .other, "and nothing is invented")
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
        let agents = AgentLab.present(present, models: [:], signals: ["claude-warden": "m9", "astra-council": "m8"])
        XCTAssertEqual(agents.map(\.id), ["astra-council", "claude-warden", "ds-box-1"])
        XCTAssertEqual(agents.map(\.lab), [.openai, .anthropic, .deepseek])
        XCTAssertEqual(agents.map(\.isWorking), [true, true, false])
        XCTAssertEqual(AgentLab.anthropic.logoAsset, "LabClaude")
        XCTAssertNil(AgentLab.xai.logoAsset, "no logo carried: the initial shows")
    }

    func test_six_logos_show_then_a_count_of_the_rest() {
        let ids = (1...8).map { "box-\($0)" }
        let agents = AgentLab.present(ids.map { person($0) }, models: [:], signals: ["box-8": "m1"])
        let cut = AgentLab.shown(agents)
        XCTAssertEqual(cut.shown.count, 6)
        XCTAssertEqual(cut.more, 2)
        XCTAssertEqual(cut.shown.first?.id, "box-8", "a working agent is never the one hidden")
        XCTAssertEqual(AgentLab.shown(Array(agents.prefix(6))).more, 0, "six fit with no count")
    }

    /// Carter, #55533: "Astra is codex ... two of them and since they're in a box we can give them one more small
    /// badge". Running boxes post through the room and are not in presence.
    func test_running_boxes_show_with_their_lab_and_a_box_badge_even_when_not_present() {
        let agents = AgentLab.present([person("claude-warden"), person("astra-brand-s")], models: [:], signals: [:],
                                      boxes: ["astra-brand-s", "astra-api-presence"])
        XCTAssertEqual(agents.map(\.id), ["astra-api-presence", "astra-brand-s", "claude-warden"], "each once")
        XCTAssertEqual(agents.map(\.isBox), [true, true, false])
        XCTAssertEqual(agents.map(\.lab), [.openai, .openai, .anthropic])
    }

    /// API #1055: the server's lab and box flag for the agents present.
    func test_the_server_says_each_agents_lab_and_box() {
        let present = [
            RoomChatPresence.Person(id: "pocket-forge", name: "pocket-forge", isHuman: false, isIdle: false, lab: "anthropic"),
            RoomChatPresence.Person(id: "astra-brand-s", name: "astra-brand-s", isHuman: false, isIdle: false, lab: "openai",
                                    isBox: true)
        ]
        let agents = AgentLab.present(present, models: [:], signals: [:])
        XCTAssertEqual(agents.map(\.lab), [.openai, .anthropic])
        XCTAssertEqual(agents.map(\.isBox), [true, false])
    }

    /// Warden, #254 and API #1055: presence stayed "active" while an agent's listener was connected; working is now
    /// the server's word, renewed by each thing the agent does.
    func test_working_is_the_servers_word_or_a_reply_being_prepared() {
        let now = Date(timeIntervalSince1970: 1_793_400_000)
        func input(_ id: String, _ author: String, minutesAgo: Double) -> RoomChatMessageInput {
            RoomChatMessageInput(id: id, sequenceId: Int64(1000 - minutesAgo), kind: .message, authorId: author,
                                 authorName: author, isHuman: author.hasPrefix("human-"), text: "x", timestamp: "",
                                 date: now.addingTimeInterval(-minutesAgo * 60))
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let presence = RoomChatPresence.make(isAvailable: true, humansOnline: 1, people: [
            RoomChatPresence.Person(id: "claude-warden", name: "claude-warden", isHuman: false, isIdle: false,
                                    isWorking: true, workingUntilMs: nowMs + 30_000),
            RoomChatPresence.Person(id: "sol-max", name: "sol-max", isHuman: false, isIdle: false,
                                    isWorking: true, workingUntilMs: nowMs - 1_000),
            RoomChatPresence.Person(id: "pocket-forge", name: "pocket-forge", isHuman: false, isIdle: false)
        ])
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [
                input("a", "ds-box-1", minutesAgo: 1),
                input("b", "pocket-forge", minutesAgo: 1),
                input("c", "human-mrrcarter", minutesAgo: 0.5)
            ],
            composingAgents: ["astra-council"],
            presence: presence
        )
        let signals = state.agentSignals(now: now)
        XCTAssertEqual(Set(signals.keys), ["ds-box-1", "pocket-forge", "astra-council"])
        XCTAssertEqual(signals["pocket-forge"], "b", "warden, #263: a present agent not marked working still beats on a post")
        XCTAssertEqual(signals["ds-box-1"], "a", "a box not in presence counts by its newest post")
        XCTAssertEqual(signals["astra-council"], "typing:", "preparing a reply is a sign too")

        let working = state.agentsWorking(now: now)
        XCTAssertEqual(working, ["claude-warden"], "the server's word, while it holds; run out is not working")
        let renewed = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [],
            presence: RoomChatPresence.make(isAvailable: true, humansOnline: 0, people: [
                RoomChatPresence.Person(id: "claude-warden", name: "claude-warden", isHuman: false, isIdle: false,
                                        isWorking: true, workingUntilMs: nowMs + 40_000)
            ]))
        XCTAssertEqual(renewed.agentsWorking(now: now), working, "a renewal keeps it working; it is not a new beat")
        XCTAssertNil(renewed.agentSignals(now: now)["claude-warden"])

        let agents = AgentLab.present(presence.people, models: [:], signals: signals, working: working)
        XCTAssertEqual(agents.filter(\.isWorking).map(\.id).sorted(), ["claude-warden", "pocket-forge"])
    }
}
