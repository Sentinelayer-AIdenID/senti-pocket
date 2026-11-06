import Foundation
import XCTest
@testable import PocketUI

final class RoomTicketsPresentationTests: XCTestCase {
    private func input(
        _ id: String,
        status: String = "open",
        priority: Int? = nil,
        updated: String = "2026-10-28T10:00:00Z",
        title: String? = nil,
        body: String = ""
    ) -> RoomTicketInput {
        RoomTicketInput(id: id, title: title ?? "Ticket \(id)", body: body, status: status, updatedAt: updated, priority: priority)
    }

    func test_active_and_archived_split_with_counts() {
        let tickets = [input("a"), input("b", status: "done"), input("c", status: "blocked"), input("d", status: "done")]
        let active = RoomTicketsPresentationState(tickets: tickets)
        XCTAssertEqual(active.activeCount, 2)
        XCTAssertEqual(active.archivedCount, 2)
        XCTAssertEqual(Set(active.rows.map(\.id)), ["a", "c"])
        let archived = RoomTicketsPresentationState(tickets: tickets, showsArchived: true)
        XCTAssertEqual(Set(archived.rows.map(\.id)), ["b", "d"])
    }

    func test_rows_rank_by_priority_then_most_recent_change() {
        let state = RoomTicketsPresentationState(tickets: [
            input("none", updated: "2026-10-28T12:00:00Z"),
            input("p2-old", priority: 2, updated: "2026-10-28T08:00:00Z"),
            input("p0", priority: 0, updated: "2026-10-27T08:00:00Z"),
            input("p2-new", priority: 2, updated: "2026-10-28T09:00:00Z")
        ])
        XCTAssertEqual(state.rows.map(\.id), ["p0", "p2-new", "p2-old", "none"])
    }

    func test_search_spans_archived_tickets_and_matches_title_body_id_or_assignee() {
        let state = RoomTicketsPresentationState(tickets: [
            input("c0ffee08-aaa", title: "Parity checklist"),
            input("decade00-bbb", status: "done", title: "Sample agent", body: "Get the sample agent working"),
            input("zzz", title: "Unrelated")
        ], query: "sample")
        XCTAssertEqual(state.rows.map(\.id), ["decade00-bbb"], "a done ticket is found by search")
        XCTAssertEqual(RoomTicketsPresentationState(tickets: [input("c0ffee08-aaa")], query: "c0ff").rows.count, 1)
    }

    func test_labels_and_protected_failures() {
        let done = RoomTicketsPresentationState(tickets: [input("a", status: "done")], showsArchived: true)
        XCTAssertEqual(done.rows.first?.statusLabel, "Done · unverified")
        XCTAssertEqual(RoomTicketsPresentationState(tickets: [input("b", status: "in_review")]).rows.first?.statusLabel, "In review")
        XCTAssertEqual(RoomTicketRow.displayName("human-mrrcarter"), "mrrcarter")

        let denied = RoomTicketsPresentationState(tickets: [input("a")], failure: .accessDenied)
        XCTAssertTrue(denied.rows.isEmpty)
        XCTAssertEqual(denied.activeCount, 0)
    }

    func test_an_open_ticket_with_a_decision_section_is_marked_until_done() {
        let ask = "## Decision\nQuestion: Ship it?\nOptions: Yes · No"
        let state = RoomTicketsPresentationState(tickets: [
            input("asks", body: ask),
            input("plain", body: "## Intent\nNothing to decide")
        ])
        XCTAssertEqual(state.rows.first { $0.id == "asks" }?.decision?.question, "Ship it?")
        XCTAssertNil(state.rows.first { $0.id == "plain" }?.decision)
        let done = RoomTicketsPresentationState(tickets: [input("asks", status: "done", body: ask)], showsArchived: true)
        XCTAssertNil(done.rows.first?.decision, "a done ticket no longer asks")
    }

    func test_killed_is_archived_and_never_asks() {
        let ask = "## Decision\nQuestion: Ship it?\nOptions: Yes · No"
        let state = RoomTicketsPresentationState(tickets: [input("k", status: "killed", body: ask), input("a")])
        XCTAssertEqual(state.archivedCount, 1)
        XCTAssertEqual(state.rows.map(\.id), ["a"])
        let archived = RoomTicketsPresentationState(tickets: [input("k", status: "killed", body: ask)], showsArchived: true)
        XCTAssertEqual(archived.rows.map(\.id), ["k"])
        XCTAssertNil(archived.rows.first?.decision)
        XCTAssertEqual(archived.rows.first?.statusLabel, "Killed")
    }

    private let viewer = "6f1c2b9e-0000-4000-8000-00000000000a"

    private func actions(
        _ status: String,
        assignee: String? = nil,
        lease: RoomTicketInput.Lease? = nil,
        holdsLease: Bool = false,
        canWrite: Bool = true,
        viewerId: String? = "6f1c2b9e-0000-4000-8000-00000000000a"
    ) -> RoomTicketActions {
        let row = RoomTicketRow(id: "t", title: "T", status: status, assignee: assignee, lease: lease)
        return RoomTicketActions(row: row, viewerId: viewerId, canWrite: canWrite, holdsLease: holdsLease)
    }

    func test_actions_follow_the_web_rules_and_the_api_lease_rules() {
        let other = "review-agent"
        let live = { (holder: String) in RoomTicketInput.Lease(holder: holder, isLive: true) }
        let expired = { (holder: String) in RoomTicketInput.Lease(holder: holder, isLive: false) }

        // Claiming: open; assigned/accepted to you; working without a lease when unassigned or yours; an expired
        // lease is a takeover; never while a lease is live.
        XCTAssertEqual(actions("open").claim, .claim)
        XCTAssertEqual(actions("assigned", assignee: viewer.uppercased()).claim, .claim, "ids compare case-insensitively")
        XCTAssertEqual(actions("accepted", assignee: viewer).claim, .claim)
        XCTAssertNil(actions("assigned", assignee: other).claim)
        XCTAssertEqual(actions("working").claim, .claim)
        XCTAssertNil(actions("working", assignee: other).claim)
        XCTAssertEqual(actions("working", assignee: other, lease: expired(other)).claim, .takeOver)
        XCTAssertNil(actions("working", assignee: other, lease: live(other)).claim)
        XCTAssertNil(actions("in_review").claim)
        XCTAssertNil(actions("blocked").claim)
        XCTAssertNil(actions("done").claim)

        // Assigning needs an unleased ticket, live or expired lease alike.
        XCTAssertTrue(actions("open").canAssign)
        XCTAssertTrue(actions("done").canAssign, "as on the web")
        XCTAssertFalse(actions("working", lease: expired(other)).canAssign)

        // Editing: unleased, or the live holder (the API allows it; the web does not offer it yet).
        XCTAssertTrue(actions("open").canEdit)
        XCTAssertTrue(actions("working", assignee: viewer, lease: live(viewer)).canEdit)
        XCTAssertFalse(actions("working", assignee: viewer, lease: expired(viewer)).canEdit)
        XCTAssertFalse(actions("working", assignee: other, lease: live(other)).canEdit)

        // Releasing needs the credential this phone kept from its claim, on a lease that is still yours.
        XCTAssertTrue(actions("working", assignee: viewer, lease: live(viewer), holdsLease: true).canRelease)
        XCTAssertFalse(actions("working", assignee: viewer, lease: live(viewer)).canRelease, "no credential, no release")
        XCTAssertFalse(actions("working", assignee: viewer, lease: expired(viewer), holdsLease: true).canRelease,
                       "a lapsed lease is never released: there is no renew, as on the web")
        XCTAssertFalse(actions("working", assignee: other, lease: live(other), holdsLease: true).canRelease,
                       "taken over since: the kept credential is stale")

        // Nothing for a viewer, without a known account, or on a killed ticket.
        XCTAssertEqual(actions("open", canWrite: false), .none)
        XCTAssertEqual(actions("open", viewerId: nil), .none)
        XCTAssertEqual(actions("killed"), .none)
    }

    func test_the_state_offers_actions_only_to_writers_and_never_behind_a_protected_failure() {
        let tickets = [input("a"), input("b", status: "in_review")]
        let writer = RoomTicketsPresentationState(tickets: tickets, viewerId: viewer, canWriteTickets: true)
        XCTAssertTrue(writer.canFileTickets)
        XCTAssertEqual(writer.actions["a"]?.claim, .claim)
        XCTAssertEqual(writer.actions["b"]?.canAssign, true)

        let reader = RoomTicketsPresentationState(tickets: tickets, viewerId: viewer)
        XCTAssertFalse(reader.canFileTickets)
        XCTAssertTrue(reader.actions.isEmpty)

        let denied = RoomTicketsPresentationState(
            tickets: tickets, failure: .accessDenied, viewerId: viewer, canWriteTickets: true, ticketWriteStatus: ["a": "x"]
        )
        XCTAssertFalse(denied.canFileTickets)
        XCTAssertTrue(denied.actions.isEmpty)
        XCTAssertTrue(denied.ticketWriteStatus.isEmpty)
    }

    func test_people_are_named_from_the_directory_never_by_user_id() {
        let priya = "1d2e3f40-0000-4000-8000-00000000000b"
        let names = [priya: "Priya"]
        XCTAssertEqual(RoomTicketRow.actorLabel(priya.uppercased(), viewerId: viewer, names: names), "Priya")
        XCTAssertEqual(RoomTicketRow.actorLabel(viewer, viewerId: viewer, names: [viewer: "Carter"]), "you")
        XCTAssertEqual(RoomTicketRow.actorLabel("5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f", viewerId: viewer, names: names), "a person")
        XCTAssertEqual(RoomTicketRow.actorLabel("build-agent", viewerId: viewer, names: names), "build-agent")

        let choices = RoomTicketAssignChoice.choices(
            viewerId: viewer,
            viewerLogin: "mrrcarter",
            people: [RoomTicketAssignChoice(id: viewer, label: "Carter (@mrrcarter)"),
                     RoomTicketAssignChoice(id: priya, label: "Priya (@priya-dev)")],
            roster: ["build-agent"],
            tickets: []
        )
        XCTAssertEqual(choices.map(\.label), ["Me (mrrcarter)", "Priya (@priya-dev)", "@build-agent"],
                       "you once, then people, then agents")
    }

    func test_a_linked_ticket_is_found_whatever_the_list_shows() {
        let tickets = [input("a"), input("old", status: "done")]
        let state = RoomTicketsPresentationState(tickets: tickets, query: "zzz", focusTicketId: "old")
        XCTAssertTrue(state.rows.isEmpty, "the search hides everything")
        XCTAssertEqual(state.focusedTicket?.id, "old")
        XCTAssertNil(RoomTicketsPresentationState(tickets: tickets, focusTicketId: "missing").focusedTicket)
        XCTAssertNil(RoomTicketsPresentationState(tickets: tickets, failure: .accessDenied, focusTicketId: "a").focusedTicket,
                     "a protected failure shows no ticket")
    }
}

/// Carter, #55238: "When I click on tickets to view the list, the ones that are currently being worked on should be
/// atop with a progress bar."
final class RoomTicketsWorkedOnTests: XCTestCase {
    func test_tickets_being_worked_on_come_first_whatever_their_priority() {
        let live = RoomTicketInput.Lease(holder: "ds-box", isLive: true)
        let tickets = [
            RoomTicketInput(id: "p0-open", title: "A", body: "", status: "open", updatedAt: "2026-10-30T08:00:00Z", priority: 0),
            RoomTicketInput(id: "p3-working", title: "B", body: "", status: "working", updatedAt: "2026-10-30T07:00:00Z", priority: 3),
            RoomTicketInput(id: "p2-review", title: "C", body: "", status: "in_review", updatedAt: "2026-10-30T06:00:00Z", priority: 2),
            RoomTicketInput(id: "p1-leased", title: "D", body: "", status: "assigned", updatedAt: "2026-10-30T05:00:00Z", priority: 1,
                            lease: live)
        ]
        let state = RoomTicketsPresentationState(tickets: tickets)
        XCTAssertEqual(state.rows.map(\.id), ["p1-leased", "p2-review", "p3-working", "p0-open"])
        XCTAssertEqual(state.rows.map(\.stepStrip), [nil, nil, nil, nil],
                       "no step from the server: no strip, and no stand-in bar either")
    }
}

/// Carter, 11-05: "So fix the progress thing. I hate it." A ticket shows the real step the server read from typed
/// facts (taken, in review, merged, shipped), never a percentage, and never a step worked out on the phone.
final class RoomTicketStepsTests: XCTestCase {
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let english = Locale(identifier: "en_US")
    /// 6:00 PM in New York on 11-05.
    private let now = Date(timeIntervalSince1970: 1_793_919_600)

    private func row(_ step: RoomTicketInput.Step?, status: String = "in_review") -> RoomTicketRow {
        RoomTicketRow(id: "t", title: "T", status: status, step: step)
    }

    /// Times read with an ordinary space before AM or PM (the system writes a narrow no-break one).
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func test_the_servers_step_is_a_strip_of_steps_the_current_one_named() {
        let strip = row(RoomTicketInput.Step(index: 3, count: 4, name: "In review")).stepStrip
        XCTAssertEqual(strip, RoomTicketStepStrip(index: 3, count: 4, name: "In review"))
        XCTAssertEqual(strip?.label, "In review")
        XCTAssertEqual(strip?.segments, [.done, .done, .current, .ahead], "the steps before it done, those after ahead")
        XCTAssertEqual(row(RoomTicketInput.Step(index: 1, count: 4, name: "Taken")).stepStrip?.segments,
                       [.current, .ahead, .ahead, .ahead])
        XCTAssertEqual(row(RoomTicketInput.Step(index: 4, count: 4, name: "Shipped"), status: "done").stepStrip?.segments,
                       [.done, .done, .done, .current], "a finished ticket shows its last step")
    }

    /// The index counts from 1 ("Step 3 of 4"); 0 is a ticket not started: the strip with no step filled, "Not
    /// started", and VoiceOver "Not started, 4 steps". Neither the first step nor no step.
    func test_index_zero_is_not_started_one_is_the_first_step_and_count_the_last() {
        let zero = row(RoomTicketInput.Step(index: 0, count: 4, name: nil), status: "assigned")
        XCTAssertEqual(zero.stepStrip?.segments, [.ahead, .ahead, .ahead, .ahead], "a strip, with no step filled")
        XCTAssertEqual(zero.stepStrip?.label, "Not started")
        XCTAssertEqual(zero.stepStrip?.isStarted, false)
        XCTAssertEqual(zero.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Not started, 4 steps")
        XCTAssertEqual(row(RoomTicketInput.Step(index: 0, count: 1, name: "Taken")).stepAccessibilityLabel(),
                       "Not started, 1 step", "a name sent with index 0 does not make it a step")
        XCTAssertEqual(plain(row(RoomTicketInput.Step(index: 0, count: 4, name: nil, waitingOn: "your OK of the plan"))
                        .stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)),
                       "Not started, 4 steps. Waiting on: your OK of the plan")

        let first = row(RoomTicketInput.Step(index: 1, count: 4, name: "Taken"), status: "working")
        XCTAssertEqual(first.stepStrip?.segments, [.current, .ahead, .ahead, .ahead])
        XCTAssertEqual(first.stepStrip?.label, "Taken")
        XCTAssertEqual(first.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Step 1 of 4, taken")

        let last = row(RoomTicketInput.Step(index: 4, count: 4, name: "Shipped"), status: "done")
        XCTAssertEqual(last.stepStrip?.segments, [.done, .done, .done, .current])
        XCTAssertEqual(last.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Step 4 of 4, shipped")

        let absent = row(nil, status: "assigned")
        XCTAssertNil(absent.stepStrip, "absent: the status alone")
        XCTAssertNil(absent.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english))
    }

    func test_voiceover_reads_the_step_then_the_small_print() {
        XCTAssertEqual(row(RoomTicketInput.Step(index: 3, count: 4, name: "In review"))
                        .stepAccessibilityLabel(now: now, timeZone: eastern, locale: english),
                       "Step 3 of 4, in review")
        let stalled = RoomTicketInput.Step(index: 3, count: 4, name: "In review",
                                           stalledSince: Date(timeIntervalSince1970: 1_793_905_800),
                                           stalledReason: "Box X was stopped")
        XCTAssertEqual(plain(row(stalled).stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)),
                       "Step 3 of 4, in review. No progress since 2:10 PM. Box X was stopped.")
    }

    func test_the_small_print_says_since_when_why_and_whom_it_waits_on() {
        let since = Date(timeIntervalSince1970: 1_793_905_800)    // 2:10 PM in New York on 11-05
        func note(_ step: RoomTicketInput.Step) -> String? {
            plain(row(step).stallNote(now: now, timeZone: eastern, locale: english))
        }
        XCTAssertNil(note(RoomTicketInput.Step(index: 2, count: 4, name: "In review")), "a moving ticket has none")
        XCTAssertEqual(note(RoomTicketInput.Step(index: 2, count: 4, name: "In review", stalledSince: since,
                                                 stalledReason: "Box X was stopped")),
                       "No progress since 2:10 PM. Box X was stopped.")
        XCTAssertEqual(note(RoomTicketInput.Step(index: 2, count: 4, name: "In review",
                                                 waitingOn: "your OK of the shots")),
                       "Waiting on: your OK of the shots")
        XCTAssertEqual(note(RoomTicketInput.Step(index: 2, count: 4, name: "In review", stalledSince: since,
                                                 waitingOn: "your OK of the shots")),
                       "No progress since 2:10 PM. Waiting on: your OK of the shots")
        XCTAssertEqual(note(RoomTicketInput.Step(index: 1, count: 4, name: "Taken", stalledSince: since,
                                                 lastHolder: "human-alex")),
                       "No progress since 2:10 PM. Last held by alex.")
        XCTAssertEqual(note(RoomTicketInput.Step(index: 1, count: 4, name: "Taken", stalledSince: since)),
                       "No progress since 2:10 PM.")
        let earlier = Date(timeIntervalSince1970: 1_793_733_000)   // 2:10 PM in New York on 11-03
        let older = note(RoomTicketInput.Step(index: 1, count: 4, name: "Taken", stalledSince: earlier))
        XCTAssertTrue(older?.hasPrefix("No progress since Nov 3") == true, "an earlier day says its date: \(older ?? "nil")")
        XCTAssertTrue(older?.contains("2:10 PM") == true)
    }

    func test_without_the_servers_step_a_ticket_shows_its_status_alone_and_no_percentage() {
        for status in ["open", "working", "in_review", "done"] {
            let plainRow = row(nil, status: status)
            XCTAssertNil(plainRow.stepStrip, "\(status): no strip")
            XCTAssertNil(plainRow.stallNote(now: now, timeZone: eastern, locale: english))
            XCTAssertNil(plainRow.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english))
        }
        let shown = [row(RoomTicketInput.Step(index: 2, count: 4, name: "In review", stalledSince: now,
                                              stalledReason: "Box X was stopped"))]
        for text in shown.flatMap({ [$0.statusLabel, $0.stallNote(now: now, timeZone: eastern, locale: english),
                                     $0.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)] })
            .compactMap({ $0 }) {
            XCTAssertFalse(text.contains("%") || text.lowercased().contains("percent"), "no percentage: \(text)")
        }
    }
}
