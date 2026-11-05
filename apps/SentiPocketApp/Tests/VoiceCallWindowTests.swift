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

    override func tearDown() {
        VoiceCallWindow.shared.hide()
        roomWindow?.isHidden = true
        roomWindow = nil
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
        let call = try XCTUnwrap(scene.windows.first { $0.windowLevel == .normal + 1 && !$0.isHidden })
        XCTAssertTrue(call.isKeyWindow, "the call's window takes the keys, so nothing under it brings a keyboard back")

        VoiceCallWindow.shared.hide()
        pump(0.5)
        XCTAssertTrue(window.isKeyWindow, "after the call, the room has the keys again")
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
