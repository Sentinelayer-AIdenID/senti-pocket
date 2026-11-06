import XCTest
@testable import SentiPocketApp

/// Carter, #55513: long enough to read the motto. Warden, #256: never in the way of a call or a tapped notification.
@MainActor
final class LaunchSplashTests: XCTestCase {
    func test_it_stays_until_the_motto_has_been_up_long_enough() {
        XCTAssertEqual(LaunchSplash.leaveDelay(urgent: false, shownFor: 0), LaunchSplash.shortest)
        XCTAssertEqual(LaunchSplash.leaveDelay(urgent: false, shownFor: 1), LaunchSplash.shortest - 1, accuracy: 0.001)
        XCTAssertEqual(LaunchSplash.leaveDelay(urgent: false, shownFor: 10), 0)
    }

    func test_opened_by_a_call_a_notification_or_a_link_it_leaves_at_once() {
        XCTAssertEqual(LaunchSplash.leaveDelay(urgent: true, shownFor: 0), 0)
        let urgency = LaunchUrgency.shared
        urgency.raise()
        XCTAssertTrue(urgency.isUrgent)
    }
}
