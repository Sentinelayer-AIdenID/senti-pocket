import CryptoKit
import Foundation
import MetricKit
import os
import PocketUI
import SwiftUI
import UIKit

/// Where the app stopped, as the phone recorded it, kept small enough to post in a room: the build, the reason, the
/// last steps taken in the app, and the code addresses of the thread that stopped. Never message text.
struct CrashReport: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// iOS recorded a crash, with the thread that stopped.
        case crash
        /// The app stopped answering for seconds.
        case hang
        /// The app was on screen and then gone with no crash of its own: the system ended it, most often for memory.
        case closed
    }

    var id: String
    var kind: Kind
    var at: Date
    var build: String
    var system: String
    var device: String
    var reason: String
    /// The thread that stopped, innermost first: "binary +0xoffset".
    var frames: [String] = []
    /// Each binary in `frames` with its UUID, to find its symbols.
    var binaries: [String] = []
    /// The last steps taken in the app, oldest first.
    var trail: [String] = []
}

extension CrashReport {
    /// The crashes and the long hangs in one of iOS's diagnostic payloads.
    static func reports(from payload: MXDiagnosticPayload, minimumHang: TimeInterval = 2) -> [CrashReport] {
        var reports: [CrashReport] = []
        for crash in payload.crashDiagnostics ?? [] {
            var exception: String?
            if #available(iOS 17.0, *), let thrown = crash.exceptionReason {
                exception = exceptionLine(name: thrown.exceptionName, className: thrown.className,
                                          format: thrown.formatString)
            }
            let reason = Self.reason(
                exceptionType: crash.exceptionType?.intValue,
                signal: crash.signal?.intValue,
                termination: crash.terminationReason,
                exception: exception,
                memoryRegion: crash.virtualMemoryRegionInfo
            )
            reports.append(make(.crash, at: payload.timeStampEnd, metaData: crash.metaData, reason: reason,
                                callStackTree: crash.callStackTree.jsonRepresentation()))
        }
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            guard seconds >= minimumHang else { continue }
            reports.append(make(.hang, at: payload.timeStampEnd, metaData: hang.metaData,
                                reason: String(format: "Not responding for %.1f s", seconds),
                                callStackTree: hang.callStackTree.jsonRepresentation()))
        }
        return reports
    }

    private static func make(_ kind: Kind, at: Date, metaData: MXMetaData, reason: String, callStackTree: Data) -> CrashReport {
        let thread = stoppedThread(callStackTree: callStackTree)
        return CrashReport(
            id: identity(kind, at: at, reason: reason, frames: thread.frames),
            kind: kind,
            at: at,
            build: metaData.applicationBuildVersion,
            system: metaData.osVersion,
            device: metaData.deviceType,
            reason: reason,
            frames: thread.frames,
            binaries: thread.binaries
        )
    }

    /// The thread that stopped, from iOS's call stack JSON: the thread it blames (else the first), innermost frame
    /// first. A hang's stacks are samples, so each step follows the most-sampled branch.
    static func stoppedThread(callStackTree json: Data, limit: Int = 30) -> (frames: [String], binaries: [String]) {
        guard let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return ([], []) }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks[0]
        var frames: [String] = []
        var binaries: [String] = []
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        while frames.count < limit, let frame = level.max(by: { samples($0) < samples($1) }) {
            let name = frame["binaryName"] as? String ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            frames.append("\(name) +0x\(String(offset, radix: 16))")
            if let uuid = frame["binaryUUID"] as? String, !binaries.contains("\(name) \(uuid)") {
                binaries.append("\(name) \(uuid)")
            }
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return (frames, binaries)
    }

    private static func samples(_ frame: [String: Any]) -> Int {
        (frame["sampleCount"] as? NSNumber)?.intValue ?? 0
    }

    /// The crash in words: the exception and signal by name and what they usually mean, then what the code or the
    /// system said.
    /// An Objective-C exception as a report shows it: its name, its class and its format string as written in the
    /// code. The values filled into that format can describe objects, paths or links, so they never leave the phone.
    static func exceptionLine(name: String, className: String, format: String) -> String {
        var line = name
        if !className.isEmpty, className != name { line += " (\(className))" }
        if !format.isEmpty { line += ": " + format }
        return line
    }

    static func reason(exceptionType: Int?, signal: Int?, termination: String?, exception: String?, memoryRegion: String?) -> String {
        var names: [String] = []
        if let exceptionType { names.append(machExceptions[exceptionType] ?? "exception \(exceptionType)") }
        if let signal { names.append(signals[signal] ?? "signal \(signal)") }
        var lines = [names.isEmpty ? "Crash" : names.joined(separator: " / ")]
        if let meaning = meaning(exceptionType: exceptionType, signal: signal) { lines[0] += ": " + meaning }
        if let exception, !exception.isEmpty { lines.append("Exception: " + clip(exception, 300)) }
        if let termination, !termination.isEmpty {
            var line = "Ended by the system: " + clip(termination, 200)
            if let code = terminationCodes.first(where: { termination.lowercased().contains($0.code) }) {
                line += " (\(code.meaning))"
            }
            lines.append(line)
        }
        if let memoryRegion, !memoryRegion.isEmpty { lines.append("Address: " + clip(memoryRegion, 200)) }
        return lines.joined(separator: "\n")
    }

    static let machExceptions = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT",
        10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"
    ]
    static let signals = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]
    static let terminationCodes = [
        (code: "0x8badf00d", meaning: "the watchdog: too slow to start or to respond"),
        (code: "0xbaadca11", meaning: "a call push arrived and no call was shown"),
        (code: "0xdead10cc", meaning: "held a locked file in the background"),
        (code: "0xc00010ff", meaning: "the phone was too hot")
    ]

    private static func meaning(exceptionType: Int?, signal: Int?) -> String? {
        switch (exceptionType, signal) {
        case (_, 9): return "the system ended it"
        case (6, _), (_, 5): return "a Swift check failed (a nil unwrapped, an index out of range, or a fatal error)"
        case (1, _), (_, 10), (_, 11): return "a bad memory access"
        case (10, _), (_, 6): return "the app aborted, most often on an uncaught exception"
        case (11, _): return "it used too much of a limited resource"
        case (12, _): return "a guarded system resource was misused"
        default: return nil
        }
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }

    /// The same report, delivered again, gets the same id.
    static func identity(_ kind: Kind, at: Date, reason: String, frames: [String]) -> String {
        let key = [kind.rawValue, String(Int(at.timeIntervalSince1970)), reason, frames.prefix(6).joined(separator: "|")]
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue)-\(digest)"
    }
}

/// The room message for crash reports: newest first, each with its reason, the last steps and the stopped thread.
enum CrashReportText {
    /// Well under a room message's limit.
    static let maximumLength = 12_000

    static func message(_ reports: [CrashReport]) -> String {
        let newestFirst = reports.sorted { $0.at > $1.at }
        var text = newestFirst.count == 1
            ? "Pocket closed unexpectedly. What the phone recorded:"
            : "Pocket closed unexpectedly \(newestFirst.count) times. What the phone recorded:"
        for (index, report) in newestFirst.enumerated() {
            let block = "\n\n" + section(report)
            guard text.count + block.count <= maximumLength else {
                text += "\n\n(\(newestFirst.count - index) older not shown)"
                break
            }
            text += block
        }
        return text
    }

    static func section(_ report: CrashReport) -> String {
        var lines = [
            "**\(title(report.kind))** \(stamp(report.at)) · build \(report.build) · \(report.system) · \(report.device)",
            report.reason
        ]
        if !report.trail.isEmpty { lines.append("Last steps: " + report.trail.joined(separator: " → ")) }
        if !report.frames.isEmpty {
            lines.append("```")
            lines += report.frames.enumerated().map { "\($0.offset) \($0.element)" }
            lines.append("```")
            lines.append("Binaries: " + report.binaries.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    static func title(_ kind: CrashReport.Kind) -> String {
        switch kind {
        case .crash: return "Crash"
        case .hang: return "Hang"
        case .closed: return "Closed while open"
        }
    }

    static func stamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm:ss 'UTC'").string(from: date) }

    static func clock(_ date: Date) -> String { formatter("HH:mm:ss").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

/// The reports kept on the phone (the newest few) and which were sent or declined, so each is offered once.
struct CrashReportStore {
    struct Contents: Codable, Equatable {
        var reports: [CrashReport] = []
        var handled: [String] = []
    }

    static let keptReports = 10
    static let keptHandled = 100

    let url: URL

    func load() -> Contents {
        guard let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else { return Contents() }
        return contents
    }

    /// Keeps the reports not seen before, and returns every report not yet sent or declined, newest first.
    @discardableResult
    func add(_ new: [CrashReport]) -> [CrashReport] {
        var contents = load()
        var known = Set(contents.reports.map(\.id)).union(contents.handled)
        let fresh = new.filter { known.insert($0.id).inserted }
        if !fresh.isEmpty {
            contents.reports = Array((contents.reports + fresh).sorted { $0.at > $1.at }.prefix(Self.keptReports))
            save(contents)
        }
        return Self.unhandled(in: contents)
    }

    func unhandled() -> [CrashReport] { Self.unhandled(in: load()) }

    func markHandled(_ ids: [String]) {
        var contents = load()
        for id in ids where !contents.handled.contains(id) { contents.handled.append(id) }
        contents.handled = Array(contents.handled.suffix(Self.keptHandled))
        save(contents)
    }

    private func save(_ contents: Contents) {
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func unhandled(in contents: Contents) -> [CrashReport] {
        let handled = Set(contents.handled)
        return contents.reports.filter { !handled.contains($0.id) }.sorted { $0.at > $1.at }
    }
}

/// What the app last knew about itself, rewritten as it runs, and read at the next launch. Leaving the app, the app
/// switcher (where a swipe closes it), a system screen and an update all make it inactive first, so a run that ended
/// while active was ended by a crash or by the system, most often for memory, which leaves no crash report of its own.
struct LastRun: Codable, Equatable {
    var build: String
    var launchedAt: Date
    var updatedAt: Date
    /// On screen and in use.
    var isActive: Bool
    var trail: [String] = []
    var footprintMB: Int?
    var peakFootprintMB: Int?
    var availableMB: Int?
    var memoryWarnings = 0

    static let keptSteps = 12

    mutating func note(_ step: String, at date: Date) {
        trail.append("\(CrashReportText.clock(date)) \(step)")
        if trail.count > Self.keptSteps { trail.removeFirst(trail.count - Self.keptSteps) }
        updatedAt = date
    }

    /// The report for a run that ended while active; nil for one that ended inactive or in the background.
    func closedReport(system: String, device: String) -> CrashReport? {
        guard isActive else { return nil }
        // With memory to spare, the likeliest end is a freeze the system ended (the watchdog), not a memory kill.
        let memoryWasShort = availableMB.map { $0 < 200 } ?? true
        var lines = [memoryWasShort
            ? "On screen, then gone, with no crash of its own: the system ended it, most often for memory."
            : "On screen, then gone, with no crash of its own and memory to spare: most likely the app stopped responding and the system ended it."]
        if let footprintMB {
            var memory = "Memory at \(CrashReportText.clock(updatedAt)): \(footprintMB) MB in use"
            if let peakFootprintMB, peakFootprintMB > footprintMB { memory += " (peak \(peakFootprintMB) MB)" }
            if let availableMB { memory += ", \(availableMB) MB left before the limit" }
            lines.append(memory + ".")
        }
        if memoryWarnings > 0 {
            lines.append("iOS warned about memory \(memoryWarnings) \(memoryWarnings == 1 ? "time" : "times") before it ended.")
        }
        return CrashReport(
            id: "closed-\(Int(launchedAt.timeIntervalSince1970))",
            kind: .closed,
            at: updatedAt,
            build: build,
            system: system,
            device: device,
            reason: lines.joined(separator: "\n"),
            trail: trail
        )
    }
}

/// Catches what ends the app: iOS's crash and hang records (MetricKit, handed over at the next launch) and a run that
/// ended on screen without one. Each new report is offered once, in the next room opened, to send there.
@MainActor
final class CrashReporter: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter(
        store: CrashReportStore(url: CrashReporter.file("pocket-crash-reports.json")),
        runURL: CrashReporter.file("pocket-last-run.json")
    )

    /// Not yet sent or declined, newest first.
    @Published private(set) var unhandled: [CrashReport] = []
    /// Every report kept on the phone, newest first.
    @Published private(set) var recorded: [CrashReport] = []

    private let store: CrashReportStore
    private let runURL: URL
    private var run: LastRun?
    private var sampler: Timer?
    private var observers: [NSObjectProtocol] = []

    init(store: CrashReportStore, runURL: URL) {
        self.store = store
        self.runURL = runURL
    }

    /// Previews and tests start the app with "-Pocket…" scenario flags or inside XCTest, and end it at will.
    static var isTestRun: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Pocket") } || NSClassFromString("XCTestCase") != nil
    }

    func start() {
        guard run == nil, !Self.isTestRun else { return }
        let now = Date()
        var found: [CrashReport] = []
        if let data = try? Data(contentsOf: runURL), let previous = try? JSONDecoder().decode(LastRun.self, from: data),
           let closed = previous.closedReport(system: Self.system, device: Self.device) {
            found.append(closed)
        }
        run = LastRun(build: Self.build, launchedAt: now, updatedAt: now,
                      isActive: UIApplication.shared.applicationState == .active)
        sample()
        MXMetricManager.shared.add(self)
        found += MXMetricManager.shared.pastDiagnosticPayloads.flatMap { CrashReport.reports(from: $0) }
        record(found)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activeChanged(true) }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.activeChanged(false) }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.memoryWarning() }
            }
        ]
        sampler = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Active or not. Leaving the app, the app switcher and system screens all make it inactive first, and the app
    /// delegate reports a quit (`applicationWillTerminate`) here before the app ends.
    func activeChanged(_ isActive: Bool) {
        guard var run, run.isActive != isActive else { return }
        run.isActive = isActive
        run.note(isActive ? "active" : "inactive", at: Date())
        self.run = run
        write()
    }

    /// A step taken in the app, by name only, for the next report.
    func note(_ step: String) {
        guard var run else { return }
        run.note(step, at: Date())
        self.run = run
        write()
    }

    /// A room intent as a step: its name, never what it carries. Scrolling and on-screen tracking are left out.
    func note(_ intent: RoomChatIntent) {
        guard let step = Self.step(for: intent) else { return }
        note(step)
    }

    nonisolated static func step(for intent: RoomChatIntent) -> String? {
        let name = Mirror(reflecting: intent).children.first?.label ?? String(describing: intent)
        let quiet: Set<String> = ["readerAtBottom", "messageOnScreen", "replyOnScreen", "attachmentAppeared", "focusHandled"]
        return quiet.contains(name) ? nil : name
    }

    func markHandled(_ reports: [CrashReport]) {
        store.markHandled(reports.map(\.id))
        unhandled = store.unhandled()
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { CrashReport.reports(from: $0) }
        Task { @MainActor in self.record(reports) }
    }

    private func record(_ reports: [CrashReport]) {
        unhandled = store.add(reports)
        recorded = store.load().reports
    }

    private func memoryWarning() {
        run?.memoryWarnings += 1
        note("memory warning")
    }

    private func sample() {
        guard var run else { return }
        let footprint = Self.footprintMB()
        run.footprintMB = footprint
        run.peakFootprintMB = max(run.peakFootprintMB ?? 0, footprint ?? 0)
        run.availableMB = Self.availableMB()
        run.updatedAt = Date()
        self.run = run
        write()
    }

    private func write() {
        guard let run, let data = try? JSONEncoder().encode(run) else { return }
        try? data.write(to: runURL, options: .atomic)
    }

    private static func file(_ name: String) -> URL {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent(name)
    }

    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    private static var system: String { "iOS " + UIDevice.current.systemVersion }

    private static var device: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    /// The memory iOS counts against the app's limit.
    private static func footprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    private static func availableMB() -> Int? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes / 1_048_576) : nil
    }
}
