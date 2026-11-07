import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Production side-panel visibility and scroll geometry. RoomFolderPinsUITests drives the presented system menu
/// with real taps to prove Pin/Unpin dispatch and capability gating.
@MainActor
final class RoomFolderPinsHostedTests: XCTestCase {
    private func host(_ folders: [RoomFolderItem], scheme: ColorScheme = .light,
                      pinActionsAvailable: Bool = true,
                      send: @escaping (RoomFolderIntent) -> Void = { _ in }) throws -> UIWindow {
        let placement = SidePanelPlacement(rooms: [], folders: folders)
        let panel = PocketSidePanel(
            placement: placement, currentRoomId: nil, unreadNotifications: 0, accountName: "Member",
            theme: .constant(.system), onSelectRoom: { _ in }, onAllRooms: {}, onNotifications: {}, onCalls: {},
            onActivity: {}, onSettings: {}, pinActionsAvailable: pinActionsAvailable, onFolder: send
        ).preferredColorScheme(scheme)
        let window = try HostedSummary.host(panel, height: 844)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        return window
    }

    /// Find the real visible button, including any extra window used by the hosting scene.
    private func action(named name: String, around window: UIWindow) -> NSObject? {
        let windows = window.windowScene?.windows.filter { !$0.isHidden } ?? [window]
        return windows.flatMap { HostedSummary.elements(in: $0) }.first {
            $0.accessibilityLabel == name && $0.accessibilityTraits.contains(.button)
        }
    }

    func test_the_actual_panel_gates_pins_and_does_not_dispatch_on_render() throws {
        let cases: [(supported: Bool, position: Int?, accountReady: Bool)] = [
            (false, nil, true), (true, nil, true), (true, 0, true), (true, 0, false)
        ]
        for item in cases {
            var intents: [RoomFolderIntent] = []
            let folder = RoomFolderItem(id: "pin-fixture", name: "Planning", position: 0,
                                        pinnedPosition: item.position, supportsPinning: item.supported)
            let window = try host([folder], pinActionsAvailable: item.accountReady) { intents.append($0) }
            defer { HostedSummary.close(window) }
            let menu = try XCTUnwrap(HostedSummary.wait(for: "pocket.drawer.folder.pin-fixture.menu", in: window))
            let group = HostedSummary.element("pocket.drawer.pinnedFolders", in: window)
            if item.position == nil || !item.accountReady {
                XCTAssertNil(group, "no Pinned group appears without a pin and a resolved account")
            } else {
                let visible = try XCTUnwrap(group, "the production panel includes the Pinned view")
                XCTAssertGreaterThan(visible.accessibilityFrame.height, 0)
            }
            XCTAssertGreaterThan(menu.accessibilityFrame.height, 0, "the production folder menu remains visible")
            XCTAssertTrue(intents.isEmpty, "rendering the real panel makes no folder change")
        }
    }

    /// Mutant: stop observing the isolated controls in the panel wrapper. The real group and progress never update.
    func test_pin_controls_update_the_existing_panel_without_replacing_its_placement() async throws {
        let controls = RoomFolderPinControls()
        let folder = RoomFolderItem(id: "pin-fixture", name: "Planning", position: 0,
                                    pinnedPosition: 0, supportsPinning: true)
        let placement = SidePanelPlacement(rooms: [], folders: [folder])
        var deliveredStates: [String] = []
        let window = try HostedSummary.host(RoomFolderPinControlsView(controls: controls) { saving, available in
            let _ = deliveredStates.append("saving=\(saving), available=\(available)")
            PocketSidePanel(
                placement: placement, currentRoomId: nil, unreadNotifications: 0, accountName: "Member",
                theme: .constant(.system), onSelectRoom: { _ in }, onAllRooms: {}, onNotifications: {}, onCalls: {},
                onActivity: {}, onSettings: {}, pinSaving: saving, pinActionsAvailable: available, onFolder: { _ in }
            )
        })
        defer { HostedSummary.close(window) }
        let menu = try await waitForElement(in: window) {
            HostedSummary.identifier(of: $0) == "pocket.drawer.folder.pin-fixture.menu"
        }
        XCTAssertNotNil(menu)
        XCTAssertNil(HostedSummary.element("pocket.drawer.pinnedFolders", in: window))

        controls.setAvailable(true)
        let group = try await waitForElement(in: window) {
            HostedSummary.identifier(of: $0) == "pocket.drawer.pinnedFolders"
        }
        XCTAssertNotNil(group, "delivered states: \(deliveredStates); identifiers: \(HostedSummary.identifiers(in: window))")
        controls.setSaving(true)
        let progress = try await waitForElement(in: window, timeout: 0.3) {
            $0.accessibilityLabel == "Saving pinned folders"
        }
        XCTAssertNotNil(progress, "delivered states: \(deliveredStates); identifiers: \(HostedSummary.identifiers(in: window))")
        controls.setSaving(false)
        controls.setAvailable(false)
        let end = Date().addingTimeInterval(0.3)
        while HostedSummary.element("pocket.drawer.pinnedFolders", in: window) != nil, Date() < end {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(HostedSummary.element("pocket.drawer.pinnedFolders", in: window))
        XCTAssertEqual(placement.builds, 1, "control state never runs folder placement again")
    }

    /// Yield the test's main-actor task while SwiftUI delivers an observed value and updates accessibility.
    /// Keep the same deadline as the synchronous hosted wait; the controls must still appear in the real panel.
    private func waitForElement(in window: UIWindow, timeout: TimeInterval = 15,
                                matching: (NSObject) -> Bool) async throws -> NSObject? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let element = HostedSummary.elements(in: window).first(where: matching) { return element }
            if Date() >= end { return nil }
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_the_actual_pinned_group_scrolls_at_phone_width_in_light_and_dark() throws {
        let folders = (0..<10).map {
            RoomFolderItem(id: "f-\($0)", name: "Planning \($0 + 1)", position: $0,
                           pinnedPosition: $0, supportsPinning: true)
        }
        for scheme in [ColorScheme.light, .dark] {
            let window = try host(folders, scheme: scheme)
            defer { HostedSummary.close(window) }
            let group = try XCTUnwrap(HostedSummary.wait(for: "pocket.drawer.pinnedFolders", in: window))
            XCTAssertGreaterThan(group.accessibilityFrame.height, 0)
            let scroll = try XCTUnwrap(HostedSummary.wait(for: "pocket.drawer.pinnedFolders.scroll", in: window))
            XCTAssertLessThanOrEqual(scroll.accessibilityFrame.height, 241, "the ten shortcuts do not consume the full panel")
            HostedSummary.pump(0.3)
            let nativeScroll = try XCTUnwrap(HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
                .first { $0.bounds.height > 0 && $0.bounds.height <= 241 && $0.contentSize.height > $0.bounds.height + 1 })
            nativeScroll.setContentOffset(CGPoint(x: 0, y: nativeScroll.contentSize.height - nativeScroll.bounds.height
                                                 + nativeScroll.adjustedContentInset.bottom), animated: false)
            HostedSummary.pump(0.3)
            let last = try XCTUnwrap(action(named: "Open pinned folder Planning 10", around: window))
            XCTAssertGreaterThan(last.accessibilityFrame.height, 0)
            XCTAssertGreaterThanOrEqual(last.accessibilityFrame.minY, scroll.accessibilityFrame.minY - 1)
            XCTAssertLessThanOrEqual(last.accessibilityFrame.maxY, scroll.accessibilityFrame.maxY + 1,
                                     "the tenth shortcut is reachable inside the real scroll view")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let screenshot = XCTAttachment(image: image)
            screenshot.name = "folder-pins-390-\(scheme == .dark ? "dark" : "light")"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
