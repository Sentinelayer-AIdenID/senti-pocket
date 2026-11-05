import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The call's own window over the room (11-05: during a call a keyboard came up with no box to type in, and could not
/// be put away). The room's box was being written in when the call came, and the call covered the box but not its
/// keyboard.
@MainActor
final class VoiceCallWindowTests: XCTestCase {
    private var roomWindow: UIWindow?
    private var otherWindow: UIWindow?

    override func tearDown() {
        VoiceCallWindow.shared.hide()
        roomWindow?.isHidden = true
        roomWindow = nil
        otherWindow?.isHidden = true
        otherWindow = nil
        pump(0.4)
        super.tearDown()
    }

    func test_a_call_over_a_room_being_written_in_puts_the_keyboard_away_and_keeps_it_away() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let room = UIViewController()
        let box = UITextView(frame: CGRect(x: 20, y: 200, width: 300, height: 44))
        room.view.addSubview(box)
        window.rootViewController = room
        window.makeKeyAndVisible()
        roomWindow = window
        pump(0.3)
        XCTAssertTrue(box.becomeFirstResponder(), "the room's box is being written in")
        pump(0.3)

        XCTAssertTrue(VoiceCallWindow.shared.show(Color.black.ignoresSafeArea()))
        pump(0.5)
        XCTAssertFalse(box.isFirstResponder, "the call has no box to type in: the room's lets its keyboard go")
        XCTAssertEqual(scene.keyWindow?.windowLevel, UIWindow.Level.normal + 1, "the call's window has the keys")

        // The box under the call starts editing again (focus given back to it, or iOS restoring it as Pocket comes back
        // to the front): it lets its keyboard go at once.
        box.becomeFirstResponder()
        pump(0.3)
        XCTAssertFalse(box.isFirstResponder, "nothing under the call brings a keyboard back over it")

        VoiceCallWindow.shared.hide()
        pump(0.5)
        XCTAssertTrue(window.isKeyWindow, "after the call, the room has the keys again")
        XCTAssertTrue(box.becomeFirstResponder(), "and its box writes as before")
        box.resignFirstResponder()
    }

    /// The window that had the keys went while the call was up (another room replaced it): when the call closes, the
    /// front window it covered takes the keys, so the call's window does not keep them once it is gone.
    func test_the_call_gives_the_keys_back_even_when_the_window_that_had_them_is_gone() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        roomWindow = window
        pump(0.3)
        XCTAssertTrue(VoiceCallWindow.shared.show(Color.black.ignoresSafeArea()))
        pump(0.5)
        let call = try XCTUnwrap(scene.keyWindow, "a window has the keys while the call is up")
        XCTAssertEqual(call.windowLevel, UIWindow.Level.normal + 1, "the call's window has them")

        window.isHidden = true
        let other = UIWindow(windowScene: scene)
        other.rootViewController = UIViewController()
        other.isHidden = false
        otherWindow = other
        VoiceCallWindow.shared.hide()
        pump(0.5)
        XCTAssertTrue(call.isHidden, "the call's window is gone")
        XCTAssertFalse(call.isKeyWindow, "and does not keep the keys")
        let key = try XCTUnwrap(scene.keyWindow, "a window has the keys after the call")
        XCTAssertFalse(key.isHidden, "one on screen")
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
