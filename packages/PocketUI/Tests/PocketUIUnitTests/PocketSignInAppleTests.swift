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

    /// Review of #305: after a failed Sign in with Apple, "Try again" opened the browser sign-in. With Apple's button
    /// on screen, the card's button names the providers it opens.
    func test_the_card_button_names_github_or_google_when_apple_is_offered() {
        XCTAssertEqual(PocketSignInView.browserButtonTitle("Try again", offersApple: true), "Try again with GitHub or Google")
        XCTAssertEqual(PocketSignInView.browserButtonTitle("Sign in again", offersApple: true),
                       "Sign in again with GitHub or Google")
        XCTAssertEqual(PocketSignInView.browserButtonTitle("Try again", offersApple: false), "Try again")
    }

    /// Review of #308: Apple's button is a capsule as tall as the card's, and an inactive account has its own words.
    func test_sign_in_buttons_share_one_size_and_an_inactive_account_is_said_plainly() {
        XCTAssertEqual(PocketSignInView.buttonHeight, 54)
        XCTAssertEqual(PocketSignInView.cardButtonLabelHeight, 40)
        XCTAssertTrue(PocketSignInUnavailableReason.accountInactive.userMessage.hasPrefix("This account is not active"))
        XCTAssertEqual(PocketSignInView.supportURL.absoluteString, "https://sentinelayer.com/support")
        XCTAssertNotEqual(PocketSignInUnavailableReason.accountInactive.userMessage,
                          PocketSignInUnavailableReason.service.userMessage)
    }
}
