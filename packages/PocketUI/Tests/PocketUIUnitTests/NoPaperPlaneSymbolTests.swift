import Foundation
import XCTest

/// Carter: "I see an airplane still". No button in the phone's sources is a paper plane any more (the web's ticket
/// 5575aaf6 asks the same): any SF Symbol name of that family in apps/ or packages/ fails this test.
final class NoPaperPlaneSymbolTests: XCTestCase {
    /// The symbol family's name, put together here so this file does not hold it.
    static let needle = "paper" + "plane"

    /// Every line of a Swift source under `folders` of `root` that names the symbol family, as "path:line" from `root`.
    /// Hidden folders (a package's .build) are not read.
    static func hits(in root: URL, folders: [String]) -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        var found: [String] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let path = url.resolvingSymlinksInPath().path
                let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
                for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.contains(needle) {
                    found.append("\(relative):\(index + 1)")
                }
            }
        }
        return found.sorted()
    }

    /// The repository this file sits in: the folder above it holding both apps/ and packages/.
    private var repositoryRoot: URL? {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let manager = FileManager.default
            if manager.fileExists(atPath: url.appendingPathComponent("apps/SentiPocketApp").path),
               manager.fileExists(atPath: url.appendingPathComponent("packages/PocketUI").path) {
                return url
            }
        }
        return nil
    }

    func test_no_paper_plane_symbol_in_the_phones_sources() throws {
        let root = try XCTUnwrap(repositoryRoot, "the repository this test sits in")
        XCTAssertEqual(Self.hits(in: root, folders: ["apps", "packages"]), [],
                       "a send button is the composer's arrow (arrow.up.circle.fill), never a paper plane")
    }

    /// The scan finds one where there is one, and nothing in a source that has none.
    func test_the_scan_finds_a_paper_plane_where_there_is_one() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plane-scan-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("apps/Example")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let send = 1\nImage(systemName: \"\(Self.needle).fill\")\n"
            .write(to: folder.appendingPathComponent("Send.swift"), atomically: true, encoding: .utf8)
        try "Image(systemName: \"arrow.up.circle.fill\")\n"
            .write(to: folder.appendingPathComponent("Fine.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Self.hits(in: root, folders: ["apps"]), ["apps/Example/Send.swift:2"])
    }
}
