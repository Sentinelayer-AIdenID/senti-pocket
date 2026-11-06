import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PocketSyncClient

private final class SharedRoomsURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answer: (Int, String) = (200, "{}")
    private static var requests: [URLRequest] = []

    static func reset(status: Int = 200, body: String) {
        lock.lock()
        answer = (status, body)
        requests = []
        lock.unlock()
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, body) = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Ticket ab3c079b: the rooms you share with someone (`GET /api/v1/me/shared-rooms`), a page at a time, newest first,
/// with how many in all.
final class SharedRoomsTests: XCTestCase {
    private func transport() -> HTTPSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedRoomsURLProtocol.self]
        return HTTPSessionTransport(apiBaseURL: URL(string: "https://api.example.test")!,
                                    urlSession: URLSession(configuration: configuration),
                                    tokenProvider: { "session-token" })
    }

    private static let agentPage = """
    {"with":"review-agent","kind":"agent","rooms":[
      {"sessionId":"room-12","title":"Design review","lastActiveAt":"2026-11-06T06:04:00Z"},
      {"sessionId":"room-11","title":"Pocket","lastActiveAt":"2026-11-06T05:30:00Z"}
     ],"total":12,"nextCursor":"c-2"}
    """

    func test_a_page_is_its_rooms_newest_first_with_the_total_and_the_cursor() throws {
        let page = try JSONDecoder().decode(SharedRoomsPage.self, from: Data(Self.agentPage.utf8))
        XCTAssertEqual(page.rooms.map(\.sessionId), ["room-12", "room-11"], "newest first, as the API answers")
        XCTAssertEqual(page.rooms.first?.title, "Design review")
        XCTAssertEqual(page.rooms.first?.lastActiveAt, "2026-11-06T06:04:00Z")
        XCTAssertEqual(page.total, 12, "all of them, not just this page")
        XCTAssertEqual(page.nextCursor, "c-2")

        let last = try JSONDecoder().decode(SharedRoomsPage.self, from: Data("""
        {"rooms":[{"sessionId":"room-1","title":null}],"total":1,"nextCursor":null}
        """.utf8))
        XCTAssertEqual(last.rooms, [SharedRoom(sessionId: "room-1", title: "")], "an untitled room reads as no title")
        XCTAssertNil(last.nextCursor, "the last page")
        let none = try JSONDecoder().decode(SharedRoomsPage.self, from: Data(#"{"rooms":[],"total":0,"nextCursor":null}"#.utf8))
        XCTAssertEqual(none, SharedRoomsPage(rooms: [], total: 0))
        let short = try JSONDecoder().decode(SharedRoomsPage.self, from: Data(#"{"rooms":[{"sessionId":"r"}]}"#.utf8))
        XCTAssertEqual(short.total, 1, "never fewer in all than on the page")
    }

    func test_the_read_names_whom_and_pages_on_with_the_apis_cursor() async throws {
        SharedRoomsURLProtocol.reset(body: Self.agentPage)
        let api = transport()
        _ = try await api.sharedRooms(with: "review-agent", cursor: nil, limit: 4)
        _ = try await api.sharedRooms(with: "human-alex", cursor: "c-2", limit: 20)
        let requests = SharedRoomsURLProtocol.captured()
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/me/shared-rooms")
        let items = requests.map { request in
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(items[0], ["with": "review-agent", "limit": "4"], "the first page names no cursor")
        XCTAssertEqual(items[1], ["with": "human-alex", "limit": "20", "cursor": "c-2"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer session-token")

        for bad in [("", 4, nil), ("human pat", 4, nil), ("review-agent", 0, nil), ("review-agent", 51, nil),
                    ("review-agent", 4, "")] as [(String, Int, String?)] {
            do {
                _ = try await api.sharedRooms(with: bad.0, cursor: bad.2, limit: bad.1)
                XCTFail("refused before the network: \(bad)")
            } catch {
                XCTAssertEqual(error as? SessionTransportError, .invalidRequest)
            }
        }
        XCTAssertEqual(SharedRoomsURLProtocol.captured().count, 2)
    }

    /// An API without the read answers 404, and a 503 while the server does not answer it yet: errors, never an empty list.
    func test_an_api_without_the_read_or_a_503_is_an_error_never_an_empty_list() async {
        for status in [404, 503] {
            SharedRoomsURLProtocol.reset(status: status, body: "")
            do {
                let page = try await transport().sharedRooms(with: "review-agent", cursor: nil, limit: 4)
                XCTFail("\(status) read as \(page.rooms.count) rooms")
            } catch {
                XCTAssertNotNil(error as? SessionTransportError, "\(status)")
            }
        }
    }
}
