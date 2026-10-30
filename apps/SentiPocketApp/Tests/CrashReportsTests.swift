import Foundation
import PocketUI
import XCTest
@testable import SentiPocketApp

final class CrashReportsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func frame(_ name: String, _ offset: Int, _ uuid: String, samples: Int = 1, _ subFrames: [[String: Any]] = []) -> [String: Any] {
        ["binaryName": name, "offsetIntoBinaryTextSegment": offset, "binaryUUID": uuid, "sampleCount": samples,
         "address": 4_295_000_000 + offset, "subFrames": subFrames]
    }

    func test_the_stopped_thread_is_the_one_blamed_innermost_first() {
        let tree = json([
            "callStackPerThread": true,
            "callStacks": [
                ["threadAttributed": false, "callStackRootFrames": [frame("libsystem_kernel.dylib", 0x99, "K")]],
                ["threadAttributed": true, "callStackRootFrames": [
                    frame("SentiPocketApp", 0x1a2b, "APP", [frame("SwiftUI", 0x55, "UI", [frame("SentiPocketApp", 0x10, "APP")])])
                ]]
            ]
        ])
        let thread = CrashReport.stoppedThread(callStackTree: tree)
        XCTAssertEqual(thread.frames, ["SentiPocketApp +0x1a2b", "SwiftUI +0x55", "SentiPocketApp +0x10"])
        XCTAssertEqual(thread.binaries, ["SentiPocketApp APP", "SwiftUI UI"], "each binary once, to find its symbols")
        XCTAssertTrue(CrashReport.stoppedThread(callStackTree: Data("not json".utf8)).frames.isEmpty)
    }

    func test_a_hang_follows_its_most_sampled_branch_up_to_the_limit() {
        let tree = json(["callStacks": [["callStackRootFrames": [
            frame("A", 1, "a", samples: 3),
            frame("B", 2, "b", samples: 9, [frame("C", 3, "c", samples: 1), frame("D", 4, "d", samples: 8, [frame("E", 5, "e")])])
        ]]]])
        XCTAssertEqual(CrashReport.stoppedThread(callStackTree: tree).frames, ["B +0x2", "D +0x4", "E +0x5"])
        XCTAssertEqual(CrashReport.stoppedThread(callStackTree: tree, limit: 2).frames, ["B +0x2", "D +0x4"])
    }

    func test_the_reason_names_the_stop_and_what_it_usually_means() {
        XCTAssertEqual(
            CrashReport.reason(exceptionType: 6, signal: 5, termination: nil, exception: nil, memoryRegion: nil),
            "EXC_BREAKPOINT / SIGTRAP: a Swift check failed (a nil unwrapped, an index out of range, or a fatal error)"
        )
        XCTAssertEqual(
            CrashReport.reason(exceptionType: 10, signal: 6, termination: nil,
                               exception: "NSInternalInconsistencyException: required condition is false: format", memoryRegion: nil),
            "EXC_CRASH / SIGABRT: the app aborted, most often on an uncaught exception\n"
                + "Exception: NSInternalInconsistencyException: required condition is false: format"
        )
        XCTAssertEqual(
            CrashReport.reason(exceptionType: 10, signal: 9, termination: "Namespace FRONTBOARD, Code 0x8badf00d",
                               exception: nil, memoryRegion: nil),
            "EXC_CRASH / SIGKILL: the system ended it\n"
                + "Ended by the system: Namespace FRONTBOARD, Code 0x8badf00d (the watchdog: too slow to start or to respond)"
        )
        XCTAssertEqual(
            CrashReport.reason(exceptionType: 1, signal: 11, termination: nil, exception: nil, memoryRegion: "0 is not in any region."),
            "EXC_BAD_ACCESS / SIGSEGV: a bad memory access\nAddress: 0 is not in any region."
        )
        XCTAssertTrue(CrashReport.reason(exceptionType: nil, signal: nil, termination: "Namespace PUSHKIT, Code 0xbaadca11",
                                         exception: nil, memoryRegion: nil)
            .hasSuffix("(a call push arrived and no call was shown)"))
    }

    /// An exception is sent as written in the code, never with the values filled in at run time.
    func test_an_exception_is_its_name_class_and_unfilled_format() {
        XCTAssertEqual(
            CrashReport.exceptionLine(name: "NSRangeException", className: "NSException",
                                      format: "*** -[NSBigMutableString substringWithRange:]: Range %@ out of bounds; string length %lu"),
            "NSRangeException (NSException): *** -[NSBigMutableString substringWithRange:]: Range %@ out of bounds; string length %lu"
        )
        XCTAssertEqual(CrashReport.exceptionLine(name: "NSGenericException", className: "NSGenericException", format: ""),
                       "NSGenericException", "a class named like the exception is not repeated")
    }

    func test_a_report_delivered_again_keeps_its_id() {
        let one = CrashReport.identity(.crash, at: start, reason: "r", frames: ["A +0x1", "B +0x2"])
        XCTAssertEqual(one, CrashReport.identity(.crash, at: start, reason: "r", frames: ["A +0x1", "B +0x2"]))
        XCTAssertNotEqual(one, CrashReport.identity(.crash, at: start, reason: "r", frames: ["A +0x1", "C +0x2"]))
        XCTAssertTrue(one.hasPrefix("crash-"))
    }

    private func report(_ id: String, minutes: Double, kind: CrashReport.Kind = .crash) -> CrashReport {
        CrashReport(id: id, kind: kind, at: start.addingTimeInterval(minutes * 60), build: "2026102915",
                    system: "iOS 26.0", device: "iPhone17,2", reason: "EXC_BREAKPOINT / SIGTRAP")
    }

    func test_the_store_offers_each_report_once_and_keeps_the_newest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CrashReportStore(url: folder.appendingPathComponent("reports.json"))

        XCTAssertEqual(store.add([report("a", minutes: 1)]).map(\.id), ["a"])
        XCTAssertEqual(store.add([report("a", minutes: 1), report("b", minutes: 2)]).map(\.id), ["b", "a"],
                       "newest first, and one delivered again is not added twice")
        store.markHandled(["a", "b"])
        XCTAssertEqual(store.add([report("a", minutes: 1)]).map(\.id), [], "a sent or declined report is never offered again")

        store.add((0..<12).map { report("n\($0)", minutes: Double(10 + $0)) })
        let kept = store.load().reports
        XCTAssertEqual(kept.count, CrashReportStore.keptReports)
        XCTAssertEqual(kept.first?.id, "n11", "the newest are kept")
    }

    func test_a_run_that_ended_while_active_is_reported_with_its_last_steps_and_memory() {
        var run = LastRun(build: "2026102915", launchedAt: start, updatedAt: start, isActive: true)
        for step in 0..<14 { run.note("step \(step)", at: start.addingTimeInterval(Double(step))) }
        run.footprintMB = 812
        run.peakFootprintMB = 1_240
        run.availableMB = 95
        run.memoryWarnings = 2

        let report = run.closedReport(system: "iOS 26.0", device: "iPhone17,2")
        XCTAssertEqual(report?.kind, .closed)
        XCTAssertEqual(report?.id, "closed-1800000000")
        XCTAssertEqual(report?.at, start.addingTimeInterval(13), "when it was last seen alive")
        XCTAssertEqual(report?.trail.count, LastRun.keptSteps)
        XCTAssertEqual(report?.trail.last, "08:00:13 step 13")
        XCTAssertEqual(report?.trail.first, "08:00:02 step 2")
        XCTAssertTrue(report?.reason.contains("Memory at 08:00:13: 812 MB in use (peak 1240 MB), 95 MB left before the limit.") == true)
        XCTAssertTrue(report?.reason.contains("iOS warned about memory 2 times before it ended.") == true)

        run.isActive = false
        XCTAssertNil(run.closedReport(system: "iOS 26.0", device: "iPhone17,2"),
                     "leaving the app, the app switcher (a swipe-away) or an update makes it inactive first")
    }

    func test_the_room_message_puts_the_newest_first_with_its_thread_in_a_code_block() {
        var crash = report("c", minutes: 5)
        crash.frames = ["SentiPocketApp +0x1a2b", "SwiftUI +0x55"]
        crash.binaries = ["SentiPocketApp APP", "SwiftUI UI"]
        var closed = report("d", minutes: 1, kind: .closed)
        closed.trail = ["08:00:01 room opened", "08:00:04 openThread"]

        let message = CrashReportText.message([closed, crash])
        XCTAssertTrue(message.hasPrefix("Pocket closed unexpectedly 2 times. What the phone recorded:"))
        XCTAssertTrue(message.contains("**Crash** 2027-01-15 08:05:00 UTC · build 2026102915 · iOS 26.0 · iPhone17,2"))
        XCTAssertTrue(message.contains("```\n0 SentiPocketApp +0x1a2b\n1 SwiftUI +0x55\n```\nBinaries: SentiPocketApp APP; SwiftUI UI"))
        XCTAssertTrue(message.contains("Last steps: 08:00:01 room opened → 08:00:04 openThread"))
        let crashAt = message.range(of: "**Crash**")!.lowerBound
        let closedAt = message.range(of: "**Closed while open**")!.lowerBound
        XCTAssertLessThan(crashAt, closedAt, "newest first")
        XCTAssertTrue(CrashReportText.message([crash]).hasPrefix("Pocket closed unexpectedly. What the phone recorded:"))
    }

    func test_many_reports_stay_short_enough_to_post() {
        let many = (0..<20).map { index -> CrashReport in
            var item = report("r\(index)", minutes: Double(index))
            item.frames = (0..<30).map { "SomeVeryLongBinaryNameForTesting +0x\(String($0 * 4096, radix: 16))" }
            item.binaries = ["SomeVeryLongBinaryNameForTesting 2FA3E76D-EFFD-3DE8-A9B6-6F86510DEC18"]
            return item
        }
        let message = CrashReportText.message(many)
        XCTAssertLessThanOrEqual(message.count, CrashReportText.maximumLength + 40)
        XCTAssertTrue(message.hasSuffix("older not shown)"))
    }

    func test_a_room_step_is_the_intent_name_never_what_it_carries() {
        XCTAssertEqual(CrashReporter.step(for: .sendMessage(text: "the secret plan")), "sendMessage")
        XCTAssertEqual(CrashReporter.step(for: .readAloud(id: "msg:1", text: "the secret plan")), "readAloud")
        XCTAssertEqual(CrashReporter.step(for: .openSearch), "openSearch")
        XCTAssertEqual(CrashReporter.step(for: .openThread(sequenceId: 7)), "openThread")
        XCTAssertNil(CrashReporter.step(for: .messageOnScreen(id: "m", isOnScreen: true)), "scrolling is not a step")
        XCTAssertNil(CrashReporter.step(for: .readerAtBottom(true)))
    }
}
