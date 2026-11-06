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

    /// The stall the reading thread found on disk with its frames.
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
    func test_the_freeze_watch_records_where_the_main_thread_was_stuck() throws {
        #if !arch(arm64)
        throw XCTSkip("The stack is read on arm64 only.")
        #else
        // The test's own folder: nothing else in the test process writes or removes files there.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainThreadStackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stall.json")
        let watch = MainThreadWatch(url: url)
        watch.start()
        // Held until the stall on disk has its frames (the watch writes the stall first, then reads the stack), not
        // for a fixed time: a slow machine only takes longer (CI once let go at 3 s, before the frames were written).
        // Another thread reads the file and says when; the main thread only waits on that, so the stack the watch
        // reads is this test's hold, not the middle of a file read or a decode (CI once ran out its 30 s there).
        // The stall checked is the one that thread read from disk: while the main thread is held, and after, until
        // it beats again, the watch rewrites the file every half second, so the file is not read a second time.
        let found = holdTheMainThread(untilFramesIn: url, seconds: 60)
        // The watch stops before the test goes on.
        watch.activeChanged(false)
        let stall = try XCTUnwrap(found, "no stall with frames on disk within 60 s; on disk: \(Self.describe(url))")
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

    /// Busy on the main thread until the stall written at `url` names frames (`seconds` at most): another thread reads
    /// the file, and the main thread does nothing but wait for its word. The stall it read, or nil if none had frames.
    @inline(never)
    private func holdTheMainThread(untilFramesIn url: URL, seconds: TimeInterval) -> MainThreadWatch.Stall? {
        let named = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let found = Found()
        DispatchQueue.global(qos: .userInitiated).async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let data = try? Data(contentsOf: url),
                   let stall = try? JSONDecoder().decode(MainThreadWatch.Stall.self, from: data),
                   stall.frames?.isEmpty == false {
                    found.stall = stall
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            done.signal()
            named.signal()
        }
        holdTheMainThread(until: named, seconds: seconds)
        // The reading thread is done before its result is read (it stops on its own at the same deadline).
        _ = done.wait(timeout: .now() + 5)
        return found.stall
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
