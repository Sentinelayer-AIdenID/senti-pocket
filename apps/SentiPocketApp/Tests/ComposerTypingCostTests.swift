import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Typing into a long draft lagged (Carter, #61421). The room's writing box laid its whole text out again
/// each time SwiftUI measured it, and the room measures its bottom bar several times per keystroke, so a keystroke cost
/// more the longer the draft. This types into the real room, hosted in a window, once with a short draft and once with
/// a long one. Each draft is typed into three times, alternating, and the fastest of each is compared, so a slow machine
/// slows both alike. Measured on the Mac's simulator, 40 keystrokes into 1,450 characters took 3.2 s with SwiftUI's
/// box (12x the 100-character draft) and 0.27 s with this one (2x: UIKit still lays out the paragraph it changes).
@MainActor
final class ComposerTypingCostTests: XCTestCase {
    private static let keystrokes = 40
    private static let words = "Okay so the next thing is the build, it goes out tonight with sign in and the agent button. "

    func test_a_keystroke_into_a_long_draft_costs_little_more_than_one_into_a_short_draft() throws {
        var short: [TimeInterval] = []
        var long: [TimeInterval] = []
        for _ in 0..<3 {
            short.append(try typingTime(draftLength: 100))
            long.append(try typingTime(draftLength: 1_450))
        }
        let fastestShort = try XCTUnwrap(short.min())
        let fastestLong = try XCTUnwrap(long.min())
        print("COMPOSERCOST short=\(short.map { Int($0 * 1_000) }) long=\(long.map { Int($0 * 1_000) }) ms for "
              + "\(Self.keystrokes) keystrokes, ratio \(String(format: "%.2f", fastestLong / fastestShort))")
        XCTAssertLessThan(fastestLong, fastestShort * 4,
                          "a keystroke into 1,450 characters must not cost many times one into 100")
    }

    /// Long drafts must type smoothly even at 10,000 characters (Carter, 11-04). Measured on the Mac's simulator in one
    /// run, alternating builds: a keystroke into 10,000 characters (one paragraph) cost about 9x one into 100 before
    /// (22–23 ms), and 3.7–4.9x after (7–9 ms): no character walk for an edit at the end, and TextKit 1 laying out only
    /// what shows. Putting TextKit 2 back measured 9.9x.
    func test_a_keystroke_into_ten_thousand_characters_stays_under_seven_times_one_into_a_hundred() throws {
        var short: [TimeInterval] = []
        var long: [TimeInterval] = []
        for _ in 0..<3 {
            short.append(try typingTime(draftLength: 100))
            long.append(try typingTime(draftLength: 10_000))
        }
        let fastestShort = try XCTUnwrap(short.min())
        let fastestLong = try XCTUnwrap(long.min())
        print("COMPOSERCOST10K short=\(short.map { Int($0 * 1_000) }) long=\(long.map { Int($0 * 1_000) }) ms for "
              + "\(Self.keystrokes) keystrokes, ratio \(String(format: "%.2f", fastestLong / fastestShort))")
        XCTAssertLessThan(fastestLong, fastestShort * 7,
                          "a keystroke into 10,000 characters must not cost many times one into 100")
    }

    /// The time to type `keystrokes` characters into the room's box holding a draft of `draftLength` characters, each
    /// one carried through to the room's layout before the next.
    private func typingTime(draftLength: Int) throws -> TimeInterval {
        let key = "composer-typing-cost-\(UUID().uuidString)"
        let draft = String(String(repeating: Self.words, count: draftLength / Self.words.count + 1).prefix(draftLength))
        UserDefaults.standard.set(draft, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let rows = (1...30).map { Self.input(Int64($0)) }
        let state = RoomChatPresentationState(sessionId: "composer-cost", title: "Room", messages: rows, composer: .enabled,
                                              draftKey: key)
        let window = try HostedSummary.host(RoomChatView(state: state) { _ in })
        defer { HostedSummary.close(window) }
        let box = try XCTUnwrap(textView(holding: draft, in: window), "the room's box shows the saved draft")
        let root = try XCTUnwrap(window.rootViewController?.view)
        box.becomeFirstResponder()
        HostedSummary.pump(0.6)
        let started = Date()
        for _ in 0..<Self.keystrokes {
            box.insertText("a")
            RunLoop.main.run(until: Date())
            root.setNeedsLayout()
            root.layoutIfNeeded()
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(box.text.count, draftLength + Self.keystrokes, "every keystroke reached the box")
        box.resignFirstResponder()
        return elapsed
    }

    private func textView(holding text: String, in window: UIWindow) -> UITextView? {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if let found = Self.textViews(in: window).first(where: { $0.text == text }) { return found }
            HostedSummary.pump(0.05)
        }
        return nil
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private static func input(_ seq: Int64) -> RoomChatMessageInput {
        let date = Date(timeIntervalSince1970: 1_793_000_000 + Double(seq) * 30)
        let author = seq % 3 == 0 ? "human-alex" : "review-agent"
        return RoomChatMessageInput(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
            isHuman: author.hasPrefix("human-"), text: "Note \(seq): " + String(repeating: "a short line ", count: Int(seq % 5) + 1),
            timestamp: ISO8601DateFormatter().string(from: date), date: date
        )
    }
}
