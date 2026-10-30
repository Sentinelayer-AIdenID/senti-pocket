import Foundation
import PocketSyncClient
import UIKit
import UserNotifications
import XCTest
@testable import SentiPocketApp

/// Carter, #55508: while Pocket is open a notification "comes anyways inside the app like WhatsApp ... a more smooth
/// nice sound and I can click on it to go there from the chat that I'm on."
@MainActor
final class InAppBannerTests: XCTestCase {
    func test_another_room_comes_in_the_app_not_as_the_ios_alert() {
        let shown = ForegroundPush.presentation(sessionId: "room-b", roomOnScreen: "room-a", bannerHosted: true)
        XCTAssertEqual(shown, .inApp)
        XCTAssertFalse(shown.options.contains(.banner))
        XCTAssertFalse(shown.options.contains(.sound))
        XCTAssertTrue(shown.options.contains(.list), "it still lands in Notification Center")
    }

    func test_the_room_on_screen_stays_quiet() {
        let shown = ForegroundPush.presentation(sessionId: "room-a", roomOnScreen: "room-a", bannerHosted: true)
        XCTAssertEqual(shown, .quiet)
        XCTAssertEqual(shown.options, [.list])
    }

    func test_without_a_room_either_side_it_is_not_taken_for_the_room_on_screen() {
        XCTAssertEqual(ForegroundPush.presentation(sessionId: nil, roomOnScreen: nil, bannerHosted: true), .inApp)
        XCTAssertEqual(ForegroundPush.presentation(sessionId: "room-a", roomOnScreen: nil, bannerHosted: true), .inApp)
    }

    func test_with_no_screen_to_show_it_ios_shows_its_own() {
        let shown = ForegroundPush.presentation(sessionId: "room-b", roomOnScreen: nil, bannerHosted: false)
        XCTAssertEqual(shown, .system)
        XCTAssertTrue(shown.options.isSuperset(of: [.banner, .sound, .list]))
    }

    func test_a_newer_notice_replaces_the_one_up_and_keeps_its_full_time() throws {
        let banner = InAppBanner(lifetime: 60)
        banner.show(title: "warden", body: "first", link: SentiLink(sessionId: "room-b"))
        let first = try XCTUnwrap(banner.current)
        banner.show(title: "", body: "second", link: nil)
        let second = try XCTUnwrap(banner.current)
        XCTAssertEqual(second.body, "second")
        XCTAssertEqual(second.title, "Senti", "an untitled notification still says who it is from")

        banner.dismiss(first.id)
        XCTAssertEqual(banner.current?.id, second.id, "the first one's timer does not put the second away")
        banner.dismiss()
        XCTAssertNil(banner.current)
    }

    func test_a_tap_puts_it_away_and_opens_what_it_is_about() throws {
        let banner = InAppBanner(lifetime: 60)
        var opened: [SentiLink] = []
        banner.onOpen = { opened.append($0) }
        banner.show(title: "claude-warden", body: "merged", link: SentiLink(sessionId: "room-b", messageSequence: 7))
        banner.cardFrame = CGRect(x: 10, y: 60, width: 370, height: 64)
        banner.open(try XCTUnwrap(banner.current))
        XCTAssertNil(banner.current)
        XCTAssertEqual(opened, [SentiLink(sessionId: "room-b", messageSequence: 7)])
        XCTAssertEqual(banner.cardFrame, .zero, "once it is away, its window takes no touches")
    }

    /// The banner's window sits above every sheet, so it must not swallow touches meant for the app under it.
    func test_its_window_takes_touches_only_on_the_card() {
        let window = InAppBannerCardWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let banner = InAppBanner(lifetime: 60)
        window.banner = banner
        window.isHidden = false
        defer { window.isHidden = true }

        banner.cardFrame = CGRect(x: 10, y: 60, width: 370, height: 64)
        XCTAssertNotNil(window.hitTest(CGPoint(x: 100, y: 80), with: nil))
        XCTAssertNil(window.hitTest(CGPoint(x: 100, y: 400), with: nil), "the app under it takes that touch")
        banner.cardFrame = .zero
        XCTAssertNil(window.hitTest(CGPoint(x: 100, y: 80), with: nil), "with no card up, nothing is taken")
    }

    func test_it_goes_away_on_its_own() {
        let banner = InAppBanner(lifetime: 0.05)
        banner.show(title: "warden", body: "done", link: SentiLink(sessionId: "room-b"))
        XCTAssertNotNil(banner.current)
        let gone = expectation(description: "dismissed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            XCTAssertNil(banner.current)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
    }
}
