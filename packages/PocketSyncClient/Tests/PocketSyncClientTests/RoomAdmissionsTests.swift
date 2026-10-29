import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomAdmissionsTests: XCTestCase {
    func test_the_admissions_page_decodes_the_api_shape_and_skips_rows_without_identity() throws {
        let page = try JSONDecoder().decode(RoomAdmissionsPage.self, from: Data("""
        {"sessionId":"room_1","agentAdmissionMode":"required","admissions":[
          {"admissionId":"6A0B1F7E-1111-4C4C-8888-0123456789AB","status":"pending","agentId":"slate-forge","displayName":null,
           "model":"model-a","provider":"provider-a","clientKind":"cli",
           "goal":{"summary":"Review every PR","deliverables":["KEY or HOLD per PR"],"stopConditions":["All tickets closed"],"untrusted":true},
           "requestedScope":{"actions":["session.read","session.post"],"ttlSeconds":28800},"grantedScope":null,
           "createdAt":"2026-10-28T10:00:00+00:00","pendingExpiresAt":"2026-10-28T10:15:00+00:00"},
          {"admissionId":"not-a-uuid","status":"pending","agentId":"x"},
          {"admissionId":"0b1c2d3e-2222-4c4c-8888-0123456789ab","status":"active","agentId":"cobalt-web",
           "grantedScope":{"actions":["session.read"],"expiresAt":"2026-10-28T18:00:00+00:00"}}
        ]}
        """.utf8))
        XCTAssertEqual(page.mode, "required")
        XCTAssertEqual(page.admissions.map(\.agentId), ["slate-forge", "cobalt-web"])
        let first = page.admissions[0]
        XCTAssertEqual(first.admissionId, "6a0b1f7e-1111-4c4c-8888-0123456789ab", "ids are kept lowercase")
        XCTAssertTrue(first.isPending)
        XCTAssertEqual(first.requestedActions, ["session.read", "session.post"])
        XCTAssertEqual(first.requestedTTLSeconds, 28800)
        XCTAssertEqual(first.deliverables, ["KEY or HOLD per PR"])
        XCTAssertTrue(page.admissions[1].isLive)
        XCTAssertEqual(page.admissions[1].grantedActions, ["session.read"])
    }
}
