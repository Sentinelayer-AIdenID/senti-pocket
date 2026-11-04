#if os(iOS) && canImport(XCTest)
import XCTest

/// Sign in with Apple's button is as tall as the other way in, at the default and at a large text size (review of
/// the sign-in screen: Apple asks that its button be no smaller than the others).
final class PocketSignInButtonsUITests: XCTestCase {
    func test_apple_and_the_card_button_are_the_same_height() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityL"] {
            let app = XCUIApplication()
            app.launchArguments = ["-PocketSignInPreview", "signedOut", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            let apple = app.descendants(matching: .any)["pocket.signin.apple"]
            let card = app.descendants(matching: .any)["pocket.signin.primary"]
            XCTAssertTrue(apple.waitForExistence(timeout: 15), size)
            XCTAssertTrue(card.waitForExistence(timeout: 15), size)
            print("SIGNINSIZE \(size): apple=\(apple.frame.height) card=\(card.frame.height)")
            XCTAssertEqual(apple.frame.height, card.frame.height, accuracy: 1, size)
            app.terminate()
        }
    }
}
#endif
