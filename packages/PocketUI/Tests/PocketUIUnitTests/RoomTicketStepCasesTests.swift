import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import PocketUI

/// The phone and the web say why a ticket stalled from one shared table (warden, 11-05; web #753): every case in
/// `packages/PocketUI/Tests/Fixtures/ticket-step-cases.json`, a byte-for-byte copy of the shared file, drives the small
/// print. Actor ids are as API #1167 sends them: `human-g.<32 hex>` for an account, `human-<login>`, an agent's id. A
/// person is never shown by id; the viewer is "you"; someone the room does not name is left out.
final class RoomTicketStepCasesTests: XCTestCase {
    /// The shared table's sha256, as published with it (H:/sl-temp/shared/ticket-step-cases/SHA256SUMS).
    static let sharedTableSHA256 = "3f5614e833fe9c24dd103bffdab1417bad4a93c3a1444ba89598e6daea47a538"

    private struct Table: Decodable {
        struct Viewer: Decodable {
            let accountId: String
            let githubLogin: String
        }

        struct Case: Decodable {
            let reason: String?
            let about: String
            let waitingOn: String?
            let lastHolder: String?
            let expected: String?
        }

        let viewer: Viewer
        let names: [String: String]
        let cases: [Case]
    }

    private let eastern = TimeZone(identifier: "America/New_York")!
    private let english = Locale(identifier: "en_US")
    /// 6:00 PM in New York on 11-05, and 2:10 PM the same day.
    private let now = Date(timeIntervalSince1970: 1_793_919_600)
    private let since = Date(timeIntervalSince1970: 1_793_905_800)

    private var tableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PocketUIUnitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/ticket-step-cases.json")
    }

    private func loadTable() throws -> (data: Data, table: Table) {
        let data = try Data(contentsOf: tableURL)
        return (data, try JSONDecoder().decode(Table.self, from: data))
    }

    /// Times read with an ordinary space before AM or PM (the system writes a narrow no-break one).
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func test_the_table_is_the_shared_one() throws {
        let (data, table) = try loadTable()
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.sharedTableSHA256, "a byte-for-byte copy of the shared table, never edited here")
        #endif
        XCTAssertEqual(table.cases.count, 50, "7 reasons by 7 ways of naming people, and the review sent with no one")
    }

    /// Every case, as the phone writes it: "Stalled since 2:10 PM · <expected>", or the time alone when the table
    /// expects no sentence.
    func test_every_shared_case_reads_as_the_table_says() throws {
        let (_, table) = try loadTable()
        for item in table.cases {
            let step = RoomTicketInput.Step(index: 2, count: 5, name: "in_review", stalledSince: since,
                                            stalledReason: item.reason, lastHolder: item.lastHolder,
                                            waitingOn: item.waitingOn)
            let note = plain(RoomTicketRow(id: "t", title: "T", status: "in_review", step: step)
                .stallNote(now: now, timeZone: eastern, locale: english, viewerId: table.viewer.accountId,
                           viewerLogin: table.viewer.githubLogin, names: table.names))
            let expected = item.expected.map { "Stalled since 2:10 PM · \($0)" } ?? "Stalled since 2:10 PM"
            XCTAssertEqual(note, expected, "\(item.reason ?? "no reason"): \(item.about)")
            XCTAssertFalse(note?.contains("human-") == true || note?.contains("g.0000") == true,
                           "never an id: \(note ?? "nil")")
        }
    }

    /// A lapsed lease names its last holder only when the room names them, as the web's chip does (warden, #753).
    func test_a_lapsed_lease_names_its_holder_only_when_the_room_does() throws {
        let (_, table) = try loadTable()
        func line(_ holder: String, live: Bool = false, until: Date? = nil) -> String? {
            RoomTicketRow(id: "t", title: "T", status: "working",
                          lease: RoomTicketInput.Lease(holder: holder, isLive: live, expiresAt: until))
                .leaseLine(viewerId: table.viewer.accountId, viewerLogin: table.viewer.githubLogin, names: table.names,
                           time: { _ in "9:41 PM" })
        }
        XCTAssertEqual(line("human-g.000000000000400080000000000000bb"), "Lease expired", "someone the room does not name")
        XCTAssertEqual(line("human-g.0000000000004000800000000000aaaa"), "Lease expired · was Priya")
        XCTAssertEqual(line("human-alex"), "Lease expired · was alex")
        XCTAssertEqual(line("human-g.000000000000400080000000000000cc"), "Lease expired · was you", "the viewer, by account")
        XCTAssertEqual(line("human-sam"), "Lease expired · was you", "the viewer, by login")
        XCTAssertEqual(line("build-agent"), "Lease expired · was build-agent")
        XCTAssertEqual(line("human-g.000000000000400080000000000000bb", live: true), "Held by a person")
        XCTAssertEqual(line("human-g.0000000000004000800000000000aaaa", live: true, until: Date(timeIntervalSince1970: 0)),
                       "Held by Priya until 9:41 PM")
        XCTAssertNil(RoomTicketRow(id: "t", title: "T", status: "open").leaseLine(viewerId: nil), "no lease, no line")
    }

    /// The same reading names people everywhere on a ticket ("Held by", "Assigned to"): never an account's hex.
    func test_a_person_on_a_ticket_is_never_shown_by_id() throws {
        let (_, table) = try loadTable()
        func label(_ id: String) -> String {
            RoomTicketRow.actorLabel(id, viewerId: table.viewer.accountId, viewerLogin: table.viewer.githubLogin,
                                     names: table.names)
        }
        XCTAssertEqual(label("human-g.0000000000004000800000000000aaaa"), "Priya", "an account, by the room's name")
        XCTAssertEqual(label("human-g.000000000000400080000000000000bb"), "a person", "an account the room does not name")
        XCTAssertEqual(label("human-g.000000000000400080000000000000cc"), "you", "the viewer, by account")
        XCTAssertEqual(label("human-sam"), "you", "the viewer, by login")
        XCTAssertEqual(label("human-alex"), "alex", "a login the room has no other name for")
        XCTAssertEqual(label("build-agent"), "build-agent", "an agent, by its id")
        XCTAssertEqual(label("00000000-0000-4000-8000-00000000aaaa"), "Priya", "a bare user id, by the room's name")
        XCTAssertEqual(label("human-g.0123abcd"), "a person", "a short account id is still never shown")
        XCTAssertEqual(RoomTicketRow.actorLabel("human-alex", viewerId: nil, names: ["human-alex": "Alex Rivera"]),
                       "Alex Rivera", "a login the room names")
    }
}
