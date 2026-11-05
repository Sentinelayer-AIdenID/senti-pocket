import Darwin
import Foundation
import PocketUI
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The side panel at scale (folders inside folders, Carter 11-04): a tree of 6 groups three levels deep with 3 rooms
/// each, 150 other rooms, 30 direct messages and 100 folders in all. The rooms are placed once, off the main thread;
/// opening the panel after that places nothing and costs the main thread less than one frame (16.7 ms at 60 Hz).
/// Folder and room names are made up.
@MainActor
final class SidePanelScaleTests: XCTestCase {
    private var window: UIWindow?

    /// The calling thread's CPU time in milliseconds: work done on it, not time spent waiting for a core.
    private static func threadMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }

    static func fixture() -> (rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]) {
        let now = Date()
        func room(_ id: String, folder: String?, unread: Int, minutesAgo: Double) -> PocketSidePanel.Room {
            PocketSidePanel.Room(id: id, title: "Room \(id)", subtitle: "What room \(id) is working on this week.",
                                 lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                                 activity: RoomListActivity(humansOnline: 1, agentsOnline: 2, unread: unread),
                                 folderId: folder)
        }
        var folders: [RoomFolderItem] = []
        var rooms: [PocketSidePanel.Room] = []
        // The tree: 6 groups, each holding a folder that holds another, with a room at each level.
        for group in 0..<6 {
            let top = "dev-\(group)", middle = "dev-\(group)-a", low = "dev-\(group)-a-1"
            folders += [
                RoomFolderItem(id: top, name: "Group \(group + 1)", position: group, roomCount: 1, totalRoomCount: 3),
                RoomFolderItem(id: middle, name: "Team \(group + 1)", parentId: top, position: 0, roomCount: 1,
                               totalRoomCount: 2),
                RoomFolderItem(id: low, name: "Desk \(group + 1)", parentId: middle, position: 0, roomCount: 1)
            ]
            for (level, folder) in [top, middle, low].enumerated() {
                rooms.append(room("dev-\(group)-\(level)", folder: folder, unread: level, minutesAgo: Double(group * 3 + level)))
            }
        }
        // 82 more folders: 28 at the top level, 27 inside them and 27 inside those.
        for index in 0..<28 { folders.append(RoomFolderItem(id: "f-\(index)", name: "Shelf \(index)", position: 6 + index)) }
        for index in 0..<27 {
            folders.append(RoomFolderItem(id: "f-\(index)-a", name: "Box \(index)", parentId: "f-\(index)", position: 0))
        }
        for index in 0..<27 {
            folders.append(RoomFolderItem(id: "f-\(index)-a-1", name: "Tray \(index)", parentId: "f-\(index)-a", position: 0))
        }
        // 150 other rooms: 100 filed across those folders, 50 in none.
        let others = folders.dropFirst(18).map(\.id)
        for index in 0..<150 {
            rooms.append(room("room-\(index)", folder: index < 100 ? others[index % others.count] : nil,
                              unread: index % 4, minutesAgo: Double(20 + index)))
        }
        // 30 direct messages: 20 under their rooms, 10 whose room is gone.
        for index in 0..<30 {
            rooms.append(PocketSidePanel.Room(
                id: "dm-\(index)", title: "Person \(index)", subtitle: nil,
                lastActivity: now.addingTimeInterval(-Double(index) * 90),
                activity: RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: index % 3),
                direct: PocketSidePanel.Direct(name: "Person \(index)", isAgent: index % 2 == 0,
                                               originRoomId: index < 20 ? "room-\(index * 5)" : "gone-\(index)")))
        }
        return (rooms, folders)
    }

    /// The root's drawer switch, as `AuthenticatedRootView.drawerOpen`.
    private final class Drawer: ObservableObject {
        @Published var open = false
    }

    private final class Counter {
        var bodies = 0
    }

    /// The side panel as the root holds it: always there, drawn only while open, made again whenever the root draws.
    private struct PanelHost: View {
        @ObservedObject var drawer: Drawer
        let placement: SidePanelPlacement
        let counter: Counter

        var body: some View {
            let _ = counter.bodies += 1
            PocketSidePanel(
                placement: placement,
                currentRoomId: "room-3",
                unreadNotifications: 2,
                accountName: "Alex",
                theme: .constant(.system),
                onSelectRoom: { _ in },
                onAllRooms: {},
                onNotifications: {},
                onCalls: {},
                onActivity: {},
                onSettings: {},
                folderNotice: nil,
                onFolder: { _ in }
            )
            .frame(width: 286)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(drawer.open ? 1 : 0)
        }
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
    }

    func test_the_fixture_is_the_size_asked_for() {
        let (rooms, folders) = Self.fixture()
        XCTAssertEqual(folders.count, 100)
        XCTAssertEqual(rooms.filter { $0.direct == nil }.count, 168, "18 in the tree and 150 others")
        let tree = RoomFolderTree.build(folders)
        XCTAssertEqual(tree.nodes.map(\.depth).max(), 3)
        XCTAssertEqual(tree.nodes.filter { $0.depth == 1 }.count, 34)
    }

    func test_opening_the_side_panel_at_scale_places_nothing_and_takes_under_one_frame_of_main_thread_work() throws {
        let (rooms, folders) = Self.fixture()
        let frame = 1_000.0 / 60

        // The first build, as the app makes it off the main thread: timed here on its own.
        var builds: [Double] = []
        for _ in 0..<5 {
            let start = Self.threadMilliseconds()
            let layout = SidePanelLayout.make(rooms, folders: folders)
            _ = layout.rows(folded: FoldedFolders())
            builds.append(Self.threadMilliseconds() - start)
        }
        let placement = SidePanelPlacement(rooms: rooms, folders: folders)
        XCTAssertEqual(placement.builds, 1)
        XCTAssertGreaterThan(placement.shown.rows.count, 250)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        self.window = window
        // Warmed up first, unmeasured: a test process's first SwiftUI window costs a hosted runner a lot on its own.
        let warmCounter = Counter()
        window.rootViewController = UIHostingController(rootView: PanelHost(
            drawer: Drawer(), placement: SidePanelPlacement(rooms: Array(rooms.prefix(10)), folders: Array(folders.prefix(6))),
            counter: warmCounter))
        window.makeKeyAndVisible()
        pump(0.5)

        let drawer = Drawer()
        let counter = Counter()
        let host = UIHostingController(rootView: PanelHost(drawer: drawer, placement: placement, counter: counter))
        let firstStart = Self.threadMilliseconds()
        window.rootViewController = host
        host.view.layoutIfNeeded()
        let firstDraw = Self.threadMilliseconds() - firstStart
        pump(0.3)

        var opens: [Double] = []
        var openWalls: [Double] = []
        var closes: [Double] = []
        for _ in 0..<22 {
            let drawn = counter.bodies
            let wallStart = CACurrentMediaTime()
            let start = Self.threadMilliseconds()
            drawer.open.toggle()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // SwiftUI applies the change on the main run loop: run it until the panel has been made again and laid out.
            let deadline = Date().addingTimeInterval(2)
            while counter.bodies == drawn, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
            host.view.layoutIfNeeded()
            let spent = Self.threadMilliseconds() - start
            let wall = (CACurrentMediaTime() - wallStart) * 1_000
            XCTAssertGreaterThan(counter.bodies, drawn, "the panel was made again")
            if drawer.open {
                opens.append(spent)
                openWalls.append(wall)
            } else {
                closes.append(spent)
            }
            pump(0.05)
        }
        XCTAssertEqual(placement.builds, 1, "opening and closing placed nothing again")

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func text(_ value: Double) -> String { String(format: "%.2f", value) }
        let line = [
            "SCALE folders=\(folders.count) rooms=\(rooms.count) rows=\(placement.shown.rows.count)",
            "build_median_ms=\(text(median(builds))) build_max_ms=\(text(builds.max() ?? 0))",
            "first_draw_main_ms=\(text(firstDraw))",
            "open_main_median_ms=\(text(median(opens))) open_main_max_ms=\(text(opens.max() ?? 0)) opens=\(opens.count)",
            "open_wall_median_ms=\(text(median(openWalls))) open_wall_max_ms=\(text(openWalls.max() ?? 0))",
            "close_main_median_ms=\(text(median(closes)))"
        ].joined(separator: " ")
        print(line)
        XCTContext.runActivity(named: line) { _ in }
        XCTAssertLessThan(median(opens), frame, "opening costs the main thread less than one frame: \(line)")
    }
}
