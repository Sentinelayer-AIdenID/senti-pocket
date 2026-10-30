import Foundation
import XCTest
@testable import PocketUI

final class PocketSidePanelTests: XCTestCase {
    private let rooms = [
        PocketSidePanel.Room(id: "a", title: "Senti-expansion-proj", subtitle: "Pocket and AIdenID", lastActivity: nil),
        PocketSidePanel.Room(id: "b", title: "VAYLT-BUILD-ROOM", subtitle: nil, lastActivity: nil),
        PocketSidePanel.Room(id: "c", title: "Hack Nation Crew", subtitle: "pocket demo", lastActivity: nil)
    ]

    func test_search_matches_titles_and_summaries_without_case_and_keeps_the_order() {
        XCTAssertEqual(PocketSidePanel.filter(rooms, by: "").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(PocketSidePanel.filter(rooms, by: "  ").map(\.id), ["a", "b", "c"], "blank is no filter")
        XCTAssertEqual(PocketSidePanel.filter(rooms, by: "POCKET").map(\.id), ["a", "c"], "summaries count")
        XCTAssertEqual(PocketSidePanel.filter(rooms, by: "vaylt").map(\.id), ["b"])
        XCTAssertTrue(PocketSidePanel.filter(rooms, by: "nothing like it").isEmpty)
    }

    func test_ages_are_short() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(-30 * 60 - 49), now: now), "30m")
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(-7 * 3_600 - 54 * 60), now: now), "7h")
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(-3 * 86_400 - 12 * 3_600), now: now), "3d")
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(-15 * 86_400), now: now), "2w")
        XCTAssertEqual(PocketSidePanel.compactAge(of: now.addingTimeInterval(60), now: now), "now", "a clock ahead is not negative")
    }

    func test_the_palette_converts_the_web_tokens() {
        let primary = PocketPalette.rgb(hue: 18, saturation: 90, lightness: 55)
        XCTAssertEqual(primary.red, 0.955, accuracy: 0.005)
        XCTAssertEqual(primary.green, 0.388, accuracy: 0.005)
        XCTAssertEqual(primary.blue, 0.145, accuracy: 0.005)
        let canvas = PocketPalette.rgb(hue: 32, saturation: 40, lightness: 97)
        XCTAssertEqual(canvas.red, 0.982, accuracy: 0.005)
        XCTAssertEqual(canvas.blue, 0.958, accuracy: 0.005)
        let gray = PocketPalette.rgb(hue: 0, saturation: 0, lightness: 100)
        XCTAssertEqual(gray.red, 1, accuracy: 0.0001)
        XCTAssertEqual(gray.green, 1, accuracy: 0.0001)
    }
}
