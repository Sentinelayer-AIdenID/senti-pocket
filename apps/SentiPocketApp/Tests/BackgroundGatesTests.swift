import Combine
import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Nothing recurring runs while the app is not in front or the room cannot be seen: a covered room keeps what arrives
/// and shows it at once when uncovered (unless a call needs it), the room's boxes are read only in sight with the app
/// in front, the side panel's poll only with the app in front, and the freeze watch stops while the app is not active.
@MainActor
final class BackgroundGatesTests: XCTestCase {
    private var watching: AnyCancellable?

    func test_a_covered_room_keeps_what_arrives_and_shows_it_once_uncovered() async {
        let stream = ControlledRoomStream()
        let room = RootBackgroundWorkTests.makeRoom(stream)
        room.resume()
        await waitUntil("the room opened") { room.state.rows.count >= 3 }
        room.isCovered = true
        let writes = count(room)
        stream.yield(.frame(.message(RootBackgroundWorkTests.message(4))))
        stream.yield(.frame(.message(RootBackgroundWorkTests.message(5))))
        await settle()
        XCTAssertEqual(writes(), 0, "under the side panel or a sheet, arrivals draw nothing")
        XCTAssertFalse(RootBackgroundWorkTests.sequences(room).contains(5))
        room.isCovered = false
        XCTAssertEqual(writes(), 1, "uncovered, everything that arrived shows in one update")
        XCTAssertTrue(RootBackgroundWorkTests.sequences(room).contains(5))
        room.pause()
    }

    func test_a_room_in_a_call_keeps_showing_what_arrives_when_covered() async {
        let stream = ControlledRoomStream()
        let room = RootBackgroundWorkTests.makeRoom(stream)
        room.resume()
        await waitUntil("the room opened") { room.state.rows.count >= 3 }
        room.readsRepliesOften = true
        room.isCovered = true
        stream.yield(.frame(.message(RootBackgroundWorkTests.message(4))))
        await waitUntil("the call's room shows the arrival") { RootBackgroundWorkTests.sequences(room).contains(4) }
        room.pause()
    }

    func test_the_rooms_boxes_are_read_only_in_sight_with_the_app_in_front() {
        XCTAssertTrue(RoomBoxPoll(covered: false, active: true).runs)
        XCTAssertFalse(RoomBoxPoll(covered: true, active: true).runs, "not under the side panel or a sheet")
        XCTAssertFalse(RoomBoxPoll(covered: false, active: false).runs, "not with the app in the background")
        XCTAssertTrue(DrawerPoll(open: true, active: true).runs)
        XCTAssertFalse(DrawerPoll(open: true, active: false).runs, "the side panel's poll rests in the background")
        XCTAssertFalse(DrawerPoll(open: false, active: true).runs)
    }

    func test_the_freeze_watch_stops_while_the_app_is_not_active() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).json")
        let watch = MainThreadWatch(url: url)
        watch.start()
        XCTAssertTrue(watch.isTicking)
        watch.activeChanged(false)
        XCTAssertFalse(watch.isTicking, "in the background the watch neither wakes nor asks the main thread to answer")
        watch.activeChanged(false)
        watch.activeChanged(true)
        XCTAssertTrue(watch.isTicking, "back in front it watches again")
        watch.activeChanged(false)
    }

    /// Counts the changes `object` announces from now on.
    private func count<Object: ObservableObject>(_ object: Object) -> () -> Int {
        let box = Box()
        watching = object.objectWillChange.sink { _ in box.value += 1 }
        return { box.value }
    }

    private final class Box { var value = 0 }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }
}
