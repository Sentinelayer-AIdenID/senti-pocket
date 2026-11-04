import Foundation
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The thinking phrases and new-room lines: the app's own copy (the file the web publishes), and the web's newer copy,
/// read at most once a day, never with the person's token, and used only when every line is fit to show.
@MainActor
final class SentiPhrasesStoreTests: XCTestCase {
    /// The published copy as a fake server answers it, and every request it saw.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [(status: Int, body: Data)]
        private var seen: [URLRequest] = []

        init(_ answers: [(status: Int, body: Data)]) { self.answers = answers }

        var requests: [URLRequest] { lock.withLock { seen } }

        func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let answer = lock.withLock { () -> (status: Int, body: Data)? in
                seen.append(request)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
            guard let answer, let url = request.url else { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (answer.body, response)
        }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private let suite = "pocket.tests.sentiPhrases.\(UUID().uuidString)"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phrases-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private var cacheURL: URL { directory.appendingPathComponent("Application Support/senti-thinking-phrases.json") }

    private func file(version: Int, phrase: String = "Checking the newest notes") -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: [
            "version": version, "phrases": [phrase, "Reading the room"], "roomIntros": ["A brand new room. Say hi."]
        ])
    }

    private func makeStore(_ server: Server, now: @escaping () -> Date) -> SentiPhrasesStore {
        SentiPhrasesStore(cacheURL: cacheURL, defaults: defaults, fetch: { try await server.fetch($0) }, now: now)
    }

    /// The copy the app ships is the web's file: version 2, 40 phrases, 25 opening lines, each fit to show.
    func test_the_app_ships_the_published_file() throws {
        let store = makeStore(Server([]), now: Date.init)
        XCTAssertEqual(store.bundled.version, 2)
        XCTAssertEqual(store.bundled.phrases.count, 40)
        XCTAssertEqual(store.bundled.roomIntros.count, 25)
        XCTAssertEqual(store.current, store.bundled, "nothing newer kept yet")
        XCTAssertTrue(store.bundled.phrases.contains("Untangling the thread"))
        let url = try XCTUnwrap(Bundle.main.url(forResource: SentiPhrasesStore.fileName, withExtension: "json"))
        XCTAssertNotNil(SentiPhrases.checked(try Data(contentsOf: url), minimumVersion: 2))
    }

    func test_a_newer_copy_is_read_once_a_day_without_a_token_and_kept_for_next_time() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let server = Server([(200, file(version: 3)), (200, file(version: 4, phrase: "Tidying the board"))])
        let store = makeStore(server, now: { clock })

        store.refreshIfDue()
        await store.settle()
        XCTAssertEqual(store.current.version, 3, "a newer, valid copy is used")
        XCTAssertEqual(store.current.phrases.first, "Checking the newest notes")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://sentinelayer.com/senti-thinking-phrases.json"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "never the person's token")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "kept in Application Support")

        clock = clock.addingTimeInterval(23 * 3_600)
        store.refreshIfDue()
        await store.settle()
        XCTAssertEqual(server.requests.count, 1, "not again within a day")

        clock = clock.addingTimeInterval(2 * 3_600)
        store.refreshIfDue()
        await store.settle()
        XCTAssertEqual(server.requests.count, 2, "again a day later")
        XCTAssertEqual(store.current.version, 4)

        // The next launch starts from the kept copy, without asking.
        let relaunched = makeStore(Server([]), now: { clock })
        XCTAssertEqual(relaunched.current.version, 4)
        XCTAssertEqual(relaunched.current.phrases.first, "Tidying the board")
    }

    func test_a_copy_that_is_not_fit_to_show_is_never_used_or_kept() async throws {
        let bad: [(String, Data)] = [
            ("older than the app's own", file(version: 1)),
            ("a line over 80 characters", file(version: 5, phrase: String(repeating: "x", count: 81))),
            ("a control character", file(version: 5, phrase: "Ringing the bell\u{7}")),
            ("not the file", Data("<html>maintenance</html>".utf8))
        ]
        for (reason, body) in bad {
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            try? FileManager.default.removeItem(at: directory)
            defaults.removeObject(forKey: SentiPhrasesStore.lastTryKey)
            let store = makeStore(Server([(200, body)]), now: { clock })
            store.refreshIfDue()
            await store.settle()
            XCTAssertEqual(store.current, store.bundled, reason)
            XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), reason)
            clock = clock.addingTimeInterval(60)
        }

        // A failed answer: nothing changes, and it is not asked again the same day.
        var clock = Date(timeIntervalSince1970: 1_900_000_000)
        defaults.removeObject(forKey: SentiPhrasesStore.lastTryKey)
        let server = Server([(503, file(version: 9))])
        let failing = makeStore(server, now: { clock })
        failing.refreshIfDue()
        await failing.settle()
        XCTAssertEqual(failing.current, failing.bundled)
        clock = clock.addingTimeInterval(600)
        failing.refreshIfDue()
        await failing.settle()
        XCTAssertEqual(server.requests.count, 1, "at most once a day, whatever came of it")
    }

    /// A kept copy older than the app's own (an update shipped a newer file) is not used.
    func test_a_kept_copy_older_than_the_apps_own_is_set_aside() throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file(version: 1).write(to: cacheURL)
        let store = makeStore(Server([]), now: Date.init)
        XCTAssertEqual(store.current, store.bundled)
    }

    /// Its own session keeps nothing: no cache, no cookies, no credentials.
    func test_the_read_uses_its_own_session_that_keeps_nothing() {
        let configuration = SentiPhrasesStore.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpAdditionalHeaders?["Authorization"])
    }
}
