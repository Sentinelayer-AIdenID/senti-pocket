import Foundation
import XCTest
@testable import SentiPocketApp

/// The freeze watch reads where the main thread is stuck (build 2026110308's freeze after a room closed left no stack
/// to read). Here the main thread is held busy in a function of this test while another thread reads its stack.
final class MainThreadStackTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var frames: [String] = []
        var binaries: [String] = []
    }

    /// The stall the checking thread read from disk.
    private final class Found: @unchecked Sendable {
        var stall: MainThreadWatch.Stall?
    }

    func test_the_main_threads_stack_is_read_while_it_is_stuck_and_names_the_function_holding_it() throws {
        #if !arch(arm64)
        throw XCTSkip("The stack is read on arm64 only.")
        #else
        MainThreadStack.rememberMainThread()
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.3)
            let stack = MainThreadStack.capture()
            box.frames = stack.frames
            box.binaries = stack.binaries
            read.signal()
        }
        holdTheMainThread(until: read)
        let ownImage = Bundle(for: Self.self).executablePath.map { ($0 as NSString).lastPathComponent } ?? "SentiPocketAppTests"
        XCTAssertFalse(box.frames.isEmpty, "the stack was read")
        XCTAssertTrue(box.frames.contains { $0.hasPrefix(ownImage + " +0x") },
                      "this test's own frame is on it: \(box.frames.prefix(12))")
        XCTAssertTrue(box.binaries.contains { $0.hasPrefix(ownImage + " ") && !$0.hasSuffix(" ?") },
                      "with its UUID: \(box.binaries)")
        #endif
    }

    /// The freeze watch writes the stack into the stall it records: a main thread held past the threshold leaves a
    /// stall on disk naming the function that held it.
    ///
    /// The test makes the watch's look itself (`tick(now:)`), from a thread of its own, once the main thread is held,
    /// at a time past the threshold (ticket 2c55d2f3). It never waits on the watch's own timer: on loaded CI runners
    /// that utility queue went tens of seconds without running (this test took 1.5 to 37 s, then ran out its 60 s
    /// with no stall on disk, or with the stall written and its frames never), while a thread like the one used here
    /// read the main thread's stack in a third of a second every time.
    func test_the_freeze_watch_records_where_the_main_thread_was_stuck() throws {
        #if !arch(arm64)
        throw XCTSkip("The stack is read on arm64 only.")
        #else
        MainThreadStack.rememberMainThread()
        // The test's own folder: nothing else in the test process writes or removes files there.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainThreadStackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stall.json")
        // Not started: its timer never runs here, so nothing but the look below writes the file.
        let watch = MainThreadWatch(url: url)
        let found = Found()
        let holding = DispatchSemaphore(value: 0)
        let looked = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            // Once the main thread is held, the watch looks, past the threshold since it last heard the main thread.
            holding.wait()
            watch.tick(now: Date().addingTimeInterval(MainThreadWatch.threshold + 1))
            // What the look left on disk, read here, before the main thread goes on.
            if let data = try? Data(contentsOf: url) {
                found.stall = try? JSONDecoder().decode(MainThreadWatch.Stall.self, from: data)
            }
            looked.signal()
        }
        holdTheMainThread(until: looked, saying: holding)
        let stall = try XCTUnwrap(found.stall, "the watch's look left no stall; on disk: \(Self.describe(url))")
        XCTAssertFalse(stall.recovered, "the main thread had not answered")
        XCTAssertGreaterThan(stall.seconds, MainThreadWatch.threshold)
        let ownImage = Bundle(for: Self.self).executablePath.map { ($0 as NSString).lastPathComponent } ?? "SentiPocketAppTests"
        XCTAssertTrue(stall.frames?.contains { $0.hasPrefix(ownImage + " +0x") } == true,
                      "the stall names this test's frame: \(stall.frames ?? [])")
        #endif
    }

    func test_on_the_main_thread_itself_it_reads_nothing() {
        XCTAssertTrue(MainThreadStack.capture().frames.isEmpty)
    }

    /// Busy on the main thread until `read` is signalled (`seconds` at most), as a stuck main thread is. `holding` is
    /// signalled once the main thread is in here.
    @inline(never)
    private func holdTheMainThread(until read: DispatchSemaphore, saying holding: DispatchSemaphore? = nil,
                                   seconds: TimeInterval = 5) {
        let end = Date().addingTimeInterval(seconds)
        holding?.signal()
        while read.wait(timeout: .now()) == .timedOut, Date() < end {}
    }

    /// What the watch left at `url`, for a failure message.
    private static func describe(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "no file" }
        guard let stall = try? JSONDecoder().decode(MainThreadWatch.Stall.self, from: data) else {
            return "\(data.count) bytes, not a stall"
        }
        return "a stall of \(String(format: "%.1f", stall.seconds)) s with \(stall.frames?.count ?? 0) frames, "
            + "recovered: \(stall.recovered)"
    }
}
