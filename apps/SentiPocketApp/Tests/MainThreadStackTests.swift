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
    func test_the_freeze_watch_records_where_the_main_thread_was_stuck() throws {
        #if !arch(arm64)
        throw XCTSkip("The stack is read on arm64 only.")
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let watch = MainThreadWatch(url: url)
        watch.start()
        let never = DispatchSemaphore(value: 0)
        holdTheMainThread(until: never, seconds: MainThreadWatch.threshold + 1.5)
        let data = try Data(contentsOf: url)
        let stall = try JSONDecoder().decode(MainThreadWatch.Stall.self, from: data)
        let ownImage = Bundle(for: Self.self).executablePath.map { ($0 as NSString).lastPathComponent } ?? "SentiPocketAppTests"
        XCTAssertTrue(stall.frames?.contains { $0.hasPrefix(ownImage + " +0x") } == true,
                      "the stall names this test's frame: \(stall.frames ?? [])")
        #endif
    }

    func test_on_the_main_thread_itself_it_reads_nothing() {
        XCTAssertTrue(MainThreadStack.capture().frames.isEmpty)
    }

    /// Busy on the main thread until `read` is signalled (`seconds` at most), as a stuck main thread is.
    @inline(never)
    private func holdTheMainThread(until read: DispatchSemaphore, seconds: TimeInterval = 5) {
        let end = Date().addingTimeInterval(seconds)
        while read.wait(timeout: .now()) == .timedOut, Date() < end {}
    }
}
