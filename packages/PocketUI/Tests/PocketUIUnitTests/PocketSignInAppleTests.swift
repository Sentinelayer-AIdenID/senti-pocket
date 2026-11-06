import XCTest
@testable import PocketUI

final class PocketSignInAppleTests: XCTestCase {
    func test_apple_is_shown_beside_every_sign_in_button_and_only_when_offered() {
        let starts: [PocketSignInPhase] = [.signedOut, .reauthenticationRequired, .unavailable(.network)]
        for phase in starts {
            XCTAssertTrue(PocketSignInView.showsApple(in: phase, offersApple: true), "\(phase)")
            XCTAssertFalse(PocketSignInView.showsApple(in: phase, offersApple: false), "\(phase)")
        }
        for phase: PocketSignInPhase in [.authorizing, .signedIn, .signingOut] {
            XCTAssertFalse(PocketSignInView.showsApple(in: phase, offersApple: true), "\(phase)")
        }
    }
}
