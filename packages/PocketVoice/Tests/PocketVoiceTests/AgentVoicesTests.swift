import XCTest
@testable import PocketVoice

final class AgentVoicesTests: XCTestCase {
    private let voices = [
        VoiceOption(identifier: "en.premium.a", language: "en-US", quality: .premium),
        VoiceOption(identifier: "en.premium.b", language: "en-GB", quality: .premium),
        VoiceOption(identifier: "en.enhanced.c", language: "en-US", quality: .enhanced),
        VoiceOption(identifier: "en.enhanced.d", language: "en-AU", quality: .enhanced),
        VoiceOption(identifier: "en.standard.e", language: "en-US", quality: .standard, isLanguageDefault: true),
        VoiceOption(identifier: "en.standard.f", language: "en-IE", quality: .standard),
        VoiceOption(identifier: "en.standard.g", language: "en-ZA", quality: .standard),
        VoiceOption(identifier: "fr.standard", language: "fr-FR", quality: .standard)
    ]

    func test_each_agent_keeps_one_voice_and_agents_spread_over_the_best_voices() {
        let first = AgentVoices.identifier(for: "pocket-forge", language: "en", phoneLanguageTag: "en-US", from: voices)
        XCTAssertEqual(AgentVoices.identifier(for: "Pocket-Forge", language: "en", phoneLanguageTag: "en-US", from: voices), first,
                       "the same agent (any case) always gets the same voice")
        let agents = ["pocket-forge", "claude-warden", "ticket-keeper", "astra-billing-core", "ds-web-mentions",
                      "respawn-orchestrator", "sol-max", "chatgpt"]
        let picked = agents.compactMap { AgentVoices.identifier(for: $0, language: "en", phoneLanguageTag: "en-US", from: voices) }
        XCTAssertEqual(picked.count, agents.count)
        XCTAssertGreaterThanOrEqual(Set(picked).count, 3, "agents do not all share one voice")
        XCTAssertFalse(picked.contains("en.standard.g"), "only the best six voices are shared out")
        XCTAssertFalse(picked.contains("fr.standard"), "only voices of the language spoken")
    }

    /// Carter (#55063): a better voice, once downloaded, is what agents speak with.
    func test_with_two_better_voices_no_agent_speaks_with_a_basic_one() {
        let agents = (1...24).map { "agent-\($0)" }
        let picked = Set(agents.compactMap { AgentVoices.identifier(for: $0, language: "en", phoneLanguageTag: "en-US", from: voices) })
        XCTAssertTrue(picked.allSatisfy { !$0.contains("standard") }, "picked \(picked)")
        XCTAssertGreaterThanOrEqual(picked.count, 3, "agents still sound apart")

        let oneBetter = [
            VoiceOption(identifier: "en.premium.a", language: "en-US", quality: .premium),
            VoiceOption(identifier: "en.standard.e", language: "en-US", quality: .standard, isLanguageDefault: true),
            VoiceOption(identifier: "en.standard.f", language: "en-IE", quality: .standard)
        ]
        let spread = Set(agents.compactMap { AgentVoices.identifier(for: $0, language: "en", phoneLanguageTag: "en-US", from: oneBetter) })
        XCTAssertGreaterThan(spread.count, 1, "one better voice alone is not everyone's voice")
    }

    func test_no_voice_for_the_language_leaves_it_to_the_system() {
        XCTAssertNil(AgentVoices.identifier(for: "pocket-forge", language: "ja", phoneLanguageTag: "en-US", from: voices))
    }

    func test_the_hash_is_stable_across_launches() {
        XCTAssertEqual(AgentVoices.stableHash("pocket-forge"), AgentVoices.stableHash("pocket-forge"))
        XCTAssertEqual(AgentVoices.stableHash(""), 0xcbf2_9ce4_8422_2325, "FNV-1a offset basis")
    }
}
