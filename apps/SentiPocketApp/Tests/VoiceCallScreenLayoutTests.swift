import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The call screen at the largest text size (AX5) on a 390-pt-wide phone: every round button's glyph stays inside its
/// circle, "<name> is answering" is not cut short, the caption has room for two lines, and the whole screen fits.
@MainActor
final class VoiceCallScreenLayoutTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.3)
        super.tearDown()
    }

    func test_at_ax5_every_round_glyph_stays_in_its_circle_and_who_is_answering_is_not_cut_short() throws {
        let frames = try layOut(at: .accessibility5)
        print("CALLLAYOUT \(frames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        for button in ["speaker", "add", "skip", "mute", "end"] {
            let glyph = try XCTUnwrap(frames["\(button).glyph"], "\(button)'s glyph was laid out")
            let circle = try XCTUnwrap(frames["\(button).circle"], "\(button)'s circle was laid out")
            XCTAssertTrue(circle.insetBy(dx: -0.5, dy: -0.5).contains(glyph),
                          "\(button): its glyph \(glyph) stays inside its circle \(circle)")
        }

        // "Reviewer is answering" at AX5 takes two lines at this width; it gets the height of both.
        let answering = try XCTUnwrap(frames["answering"])
        let footnote = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: Self.ax5)
        let semibold = UIFont.systemFont(ofSize: footnote.pointSize, weight: .semibold)
        let needed = ("Reviewer is answering" as NSString).boundingRect(
            with: CGSize(width: answering.width + 1, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: semibold], context: nil
        ).height
        XCTAssertGreaterThan(needed, semibold.lineHeight * 1.5, "at AX5 the line wraps, so this check means something")
        XCTAssertGreaterThanOrEqual(answering.height + 1, needed, "who is answering is not cut short: \(answering)")

        // The caption has room for two lines, at the smallest it may shrink to.
        let caption = try XCTUnwrap(frames["caption"])
        let title3 = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: Self.ax5)
        XCTAssertGreaterThanOrEqual(caption.height + 1, 2 * title3.lineHeight * 0.6, "the caption shows two lines: \(caption)")

        // The whole call screen fits on the phone, between its top and bottom edges, and its controls stay one row:
        // Hands-free is one line under Skip, not a tall block that takes the caption's room.
        let header = try XCTUnwrap(frames["header"])
        let controls = try XCTUnwrap(frames["controls"])
        XCTAssertLessThanOrEqual(controls.height, 120, "the controls stay one row: \(controls)")
        // Hands-free's text stops growing at the largest standard size, so it reads in full on its one line: its line is
        // no taller at AX5 than at that size.
        let handsFree = try XCTUnwrap(frames["handsFree.label"])
        let largestStandard = UIFont.preferredFont(
            forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        )
        XCTAssertLessThanOrEqual(handsFree.height, largestStandard.lineHeight + 1,
                                 "Hands-free stays at the largest standard size: \(handsFree)")
        let window = try XCTUnwrap(self.window)
        XCTAssertGreaterThanOrEqual(header.minY, window.safeAreaInsets.top - 1, "the header is on screen: \(header)")
        XCTAssertLessThanOrEqual(controls.maxY, window.bounds.height - window.safeAreaInsets.bottom + 1,
                                 "the controls are on screen: \(controls)")
    }

    func test_at_the_default_size_the_screen_lays_out_as_before() throws {
        let frames = try layOut(at: .large)
        for button in ["speaker", "add", "skip", "mute", "end"] {
            let glyph = try XCTUnwrap(frames["\(button).glyph"])
            let circle = try XCTUnwrap(frames["\(button).circle"])
            XCTAssertTrue(circle.contains(glyph), "\(button): its glyph stays inside its circle")
        }
        let answering = try XCTUnwrap(frames["answering"])
        let footnote = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        XCTAssertLessThan(answering.height, footnote.lineHeight * 1.6, "one line at the default size")
    }

    private static let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

    /// The call screen of a reviewer answering, on a 390 x 844 window, at this text size; its parts' frames.
    private func layOut(at size: DynamicTypeSize) throws -> [String: CGRect] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal + 5
        var state = VoiceRoomState(
            phase: .speaking(speaker: "review-agent (voice)"),
            with: ["review-agent", "build-agent"],
            turns: [VoiceRoomTurn(id: "line-1", speaker: "review-agent (voice)", isYou: false,
                                  text: "Build 320 is up, and the retry fix is in it.", at: Date())]
        )
        state.joined = ["review-agent", "build-agent"]
        state.ringStopped = true
        state.answering = VoiceRoomAnswering(turnId: "t1", agentId: "review-agent", name: "Reviewer", isSpeaking: true)
        VoiceRoomPanelLayout.reset()
        window.rootViewController = UIHostingController(rootView: VoiceRoomPanel(
            state: state, meter: VoiceLevelMeter(), partnerLab: nil, send: { _ in }
        ).environment(\.dynamicTypeSize, size))
        window.makeKeyAndVisible()
        self.window = window
        pump(1)
        return VoiceRoomPanelLayout.frames
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
