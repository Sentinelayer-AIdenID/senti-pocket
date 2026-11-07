#if DEBUG
import XCTest
@testable import SentiPocketApp

/// `-PocketRootAIConsentGiven` starts the root preview as a phone that already said OK to sharing with AI, so a test of
/// what follows a send (the side panel's freeze path) is not stopped by the question. It is honored only with
/// `-PocketRootPreview`: on its own it does nothing. In Release it does not exist: `RootPreview` is DEBUG only, and the
/// root reads the flag inside `#if DEBUG` (the unsigned Release build in CI would not compile otherwise).
///
/// Mutant it must catch: the flag honored without `-PocketRootPreview`.
final class RootPreviewAIConsentFlagTests: XCTestCase {
    func test_the_flag_is_honored_only_in_the_root_preview() {
        XCTAssertFalse(RootPreview.startsWithAIConsentGiven(["SentiPocketApp", "-PocketRootAIConsentGiven"]),
                       "without -PocketRootPreview the flag does nothing")
        XCTAssertFalse(RootPreview.startsWithAIConsentGiven(["SentiPocketApp", "-PocketRootPreview"]),
                       "the preview without the flag asks, as the app does")
        XCTAssertTrue(RootPreview.startsWithAIConsentGiven(["SentiPocketApp", "-PocketRootPreview",
                                                            "-PocketRootAIConsentGiven"]),
                      "the preview with the flag starts with the OK given")
    }
}
#endif
