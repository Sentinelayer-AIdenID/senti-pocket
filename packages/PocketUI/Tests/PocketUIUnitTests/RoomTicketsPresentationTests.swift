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
/// facts, never a percentage, and never a step worked out on the phone. The step comes in the server's own words
/// (warden, 11-05): names `not_started` to `done`, reasons such as `waiting_on_review`, people as actor ids.
final class RoomTicketStepsTests: XCTestCase {
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let english = Locale(identifier: "en_US")
    /// 6:00 PM in New York on 11-05.
    private let now = Date(timeIntervalSince1970: 1_793_919_600)
    /// 2:10 PM in New York on 11-05.
    private let since = Date(timeIntervalSince1970: 1_793_905_800)

    private func row(_ step: RoomTicketInput.Step?, status: String = "in_review") -> RoomTicketRow {
        RoomTicketRow(id: "t", title: "T", status: status, step: step)
    }

    /// Times read with an ordinary space before AM or PM (the system writes a narrow no-break one).
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func note(_ step: RoomTicketInput.Step, viewerId: String? = nil, viewerLogin: String? = nil,
                      names: [String: String] = [:]) -> String? {
        plain(row(step).stallNote(now: now, timeZone: eastern, locale: english, viewerId: viewerId,
                                  viewerLogin: viewerLogin, names: names))
    }

    func test_the_servers_step_is_a_strip_of_steps_the_current_one_named() {
        let strip = row(RoomTicketInput.Step(index: 3, count: 5, name: "merged")).stepStrip
        XCTAssertEqual(strip, RoomTicketStepStrip(index: 3, count: 5, name: "merged"))
        XCTAssertEqual(strip?.label, "Merged")
        XCTAssertEqual(strip?.segments, [.done, .done, .current, .ahead, .ahead],
                       "the steps before it done, those after ahead")
        let names = ["taken": "Taken", "in_review": "In review", "merged": "Merged", "shipped": "Shipped", "done": "Done"]
        for (index, wire) in ["taken", "in_review", "merged", "shipped", "done"].enumerated() {
            XCTAssertEqual(row(RoomTicketInput.Step(index: index + 1, count: 5, name: wire)).stepStrip?.label, names[wire])
        }
    }

    /// The index counts from 1 ("Step 2 of 5"); 0 is a ticket not started: the strip with no step filled, "Not
    /// started", and VoiceOver "Not started, 5 steps". Neither the first step nor no step.
    func test_index_zero_is_not_started_one_is_the_first_step_and_count_the_last() {
        let zero = row(RoomTicketInput.Step(index: 0, count: 5, name: "not_started"), status: "assigned")
        XCTAssertEqual(zero.stepStrip?.segments, [.ahead, .ahead, .ahead, .ahead, .ahead], "a strip, with no step filled")
        XCTAssertEqual(zero.stepStrip?.label, "Not started")
        XCTAssertEqual(zero.stepStrip?.isStarted, false)
        XCTAssertEqual(zero.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Not started, 5 steps")
        XCTAssertEqual(row(RoomTicketInput.Step(index: 0, count: 1, name: "not_started")).stepAccessibilityLabel(),
                       "Not started, 1 step")

        let first = row(RoomTicketInput.Step(index: 1, count: 5, name: "taken"), status: "working")
        XCTAssertEqual(first.stepStrip?.segments, [.current, .ahead, .ahead, .ahead, .ahead])
        XCTAssertEqual(first.stepStrip?.label, "Taken")
        XCTAssertEqual(first.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Step 1 of 5, taken")

        let last = row(RoomTicketInput.Step(index: 5, count: 5, name: "done"), status: "done")
        XCTAssertEqual(last.stepStrip?.segments, [.done, .done, .done, .done, .current])
        XCTAssertEqual(last.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english), "Step 5 of 5, done")

        let absent = row(nil, status: "assigned")
        XCTAssertNil(absent.stepStrip, "absent: the status alone")
        XCTAssertNil(absent.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english))
    }

    /// "Stalled since {date} · {why}", why as a sentence with the person in it (warden, 11-05, as on the web, #753).
    func test_the_small_print_says_since_when_and_why_with_the_person_in_it() {
        func stalled(_ reason: String?, lastHolder: String? = nil, waitingOn: String? = nil) -> String? {
            note(RoomTicketInput.Step(index: 2, count: 5, name: "in_review", stalledSince: since, stalledReason: reason,
                                      lastHolder: lastHolder, waitingOn: waitingOn))
        }
        XCTAssertNil(note(RoomTicketInput.Step(index: 2, count: 5, name: "in_review", stalledReason: "waiting_on_review",
                                               waitingOn: "human-alex")),
                     "a ticket that has not stopped has no small print")
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: "human-alex"),
                       "Stalled since 2:10 PM · waiting on review by alex")
        XCTAssertEqual(stalled("holder_lease_expired", lastHolder: "human-alex"),
                       "Stalled since 2:10 PM · alex, who was working on it, went quiet")
        XCTAssertEqual(stalled("holder_lease_expired", lastHolder: "human-alex", waitingOn: "human-dana"),
                       "Stalled since 2:10 PM · alex, who was working on it, went quiet",
                       "the one who went quiet is the last holder")
        XCTAssertEqual(stalled("waiting_on_owner", waitingOn: "human-alex"),
                       "Stalled since 2:10 PM · waiting on the owner, alex")
        XCTAssertEqual(stalled("waiting_on_assignee", lastHolder: "human-dana", waitingOn: "human-alex"),
                       "Stalled since 2:10 PM · waiting on alex, who it's assigned to",
                       "the waiting reasons name the one it waits on")
        XCTAssertEqual(stalled("blocked", lastHolder: "human-dana", waitingOn: "human-alex"),
                       "Stalled since 2:10 PM · blocked", "no one is named where no one applies")
        XCTAssertEqual(stalled("no_activity", lastHolder: "human-dana"), "Stalled since 2:10 PM · no activity")

        // No one to name: the web's plain words.
        let words = [
            "holder_lease_expired": "the person working on it went quiet",
            "waiting_on_assignee": "waiting on whoever it's assigned to",
            "waiting_on_review": "waiting on review",
            "waiting_on_owner": "waiting on the owner",
            "blocked": "blocked",
            "no_activity": "no activity"
        ]
        XCTAssertEqual(RoomTicketRow.stallReasons, words)
        for (reason, plainWords) in words {
            XCTAssertEqual(stalled(reason), "Stalled since 2:10 PM · \(plainWords)", reason)
        }
        // No reason: whom it waits on, else who last held it, else the time alone.
        XCTAssertEqual(stalled(nil, lastHolder: "human-dana", waitingOn: "human-alex"),
                       "Stalled since 2:10 PM · waiting on alex")
        XCTAssertEqual(stalled(nil, lastHolder: "human-dana"), "Stalled since 2:10 PM · last held by dana")
        XCTAssertEqual(stalled(nil), "Stalled since 2:10 PM")

        let earlier = Date(timeIntervalSince1970: 1_793_733_000)   // 2:10 PM in New York on 11-03
        let older = note(RoomTicketInput.Step(index: 1, count: 5, name: "taken", stalledSince: earlier))
        XCTAssertTrue(older?.hasPrefix("Stalled since Nov 3") == true, "an earlier day says its date: \(older ?? "nil")")
        XCTAssertTrue(older?.contains("2:10 PM") == true)
    }

    /// The person is named the way the room names them, never by an id, and the viewer is "you", said naturally, whether
    /// the ticket names them by account (`human-g.<32 hex>`) or by login (API #1167). The shared table
    /// (RoomTicketStepCasesTests) pins every reason with each; these are the shapes around it.
    func test_the_person_is_named_never_a_raw_id_and_the_viewer_is_you() {
        let viewerAccount = "00000000-0000-4000-8000-0000000000cc"
        func stalled(_ reason: String, lastHolder: String? = nil, waitingOn: String? = nil,
                     names: [String: String] = [:]) -> String? {
            note(RoomTicketInput.Step(index: 3, count: 5, name: "merged", stalledSince: since, stalledReason: reason,
                                      lastHolder: lastHolder, waitingOn: waitingOn),
                 viewerId: viewerAccount, viewerLogin: "sam", names: names)
        }
        let account = "00000000-0000-4000-8000-0000000000dd"
        let accountActor = "human-g.000000000000400080000000000000dd"
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: accountActor), "Stalled since 2:10 PM · waiting on review",
                       "an account the room does not name is left out, never shown by its hex")
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: accountActor, names: [account: "Dana"]),
                       "Stalled since 2:10 PM · waiting on review by Dana")
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: "HUMAN-G.000000000000400080000000000000DD",
                               names: [account: "Dana"]),
                       "Stalled since 2:10 PM · waiting on review by Dana", "whatever the case of its hex")
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: account), "Stalled since 2:10 PM · waiting on review",
                       "a bare user id is an account too")
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: "human-g.0123abcd"),
                       "Stalled since 2:10 PM · waiting on review", "a short account id is never shown either")
        XCTAssertEqual(stalled("waiting_on_assignee", waitingOn: accountActor),
                       "Stalled since 2:10 PM · waiting on the person it's assigned to")
        XCTAssertEqual(stalled("holder_lease_expired", lastHolder: "forge-box-7"),
                       "Stalled since 2:10 PM · forge-box-7, who was working on it, went quiet")
        XCTAssertEqual(stalled("waiting_on_owner", waitingOn: "human-alex", names: ["human-alex": "Alex Rivera"]),
                       "Stalled since 2:10 PM · waiting on the owner, Alex Rivera", "a login the room names")

        let byAccount = "human-g.000000000000400080000000000000cc"
        XCTAssertEqual(stalled("waiting_on_review", waitingOn: byAccount), "Stalled since 2:10 PM · waiting on review by you")
        XCTAssertEqual(stalled("waiting_on_assignee", waitingOn: "human-sam"), "Stalled since 2:10 PM · waiting on you")
        XCTAssertEqual(stalled("waiting_on_owner", waitingOn: "HUMAN-SAM"), "Stalled since 2:10 PM · waiting on you, the owner")
        XCTAssertEqual(stalled("holder_lease_expired", lastHolder: byAccount),
                       "Stalled since 2:10 PM · you went quiet while working on it")
        for reason in RoomTicketRow.stallReasons.keys {
            for viewer in [byAccount, "human-sam"] {
                let text = stalled(reason, lastHolder: viewer, waitingOn: viewer) ?? ""
                XCTAssertFalse(text.contains("check") || text.contains("human-") || text.contains("g.0"),
                               "\(reason): \(text)")
            }
        }
    }

    func test_voiceover_reads_the_step_then_the_small_print() {
        XCTAssertEqual(row(RoomTicketInput.Step(index: 2, count: 5, name: "in_review"))
                        .stepAccessibilityLabel(now: now, timeZone: eastern, locale: english),
                       "Step 2 of 5, in review")
        let stalled = RoomTicketInput.Step(index: 2, count: 5, name: "in_review", stalledSince: since,
                                           stalledReason: "waiting_on_review", waitingOn: "human-alex")
        XCTAssertEqual(plain(row(stalled).stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)),
                       "Step 2 of 5, in review. Stalled since 2:10 PM, waiting on review by alex")
        let notStarted = RoomTicketInput.Step(index: 0, count: 5, name: "not_started", stalledSince: since,
                                              stalledReason: "waiting_on_assignee", waitingOn: "build-agent")
        XCTAssertEqual(plain(row(notStarted, status: "assigned")
                                .stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)),
                       "Not started, 5 steps. Stalled since 2:10 PM, waiting on build-agent, who it's assigned to")
    }

    func test_without_the_servers_step_a_ticket_shows_its_status_alone_and_no_percentage() {
        for status in ["open", "working", "in_review", "done"] {
            let plainRow = row(nil, status: status)
            XCTAssertNil(plainRow.stepStrip, "\(status): no strip")
            XCTAssertNil(plainRow.stallNote(now: now, timeZone: eastern, locale: english))
            XCTAssertNil(plainRow.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english))
        }
        let shown = row(RoomTicketInput.Step(index: 2, count: 5, name: "in_review", stalledSince: since,
                                             stalledReason: "no_activity", lastHolder: "forge-box-7"))
        for text in [shown.statusLabel, shown.stallNote(now: now, timeZone: eastern, locale: english),
                     shown.stepAccessibilityLabel(now: now, timeZone: eastern, locale: english)].compactMap({ $0 }) {
            XCTAssertFalse(text.contains("%") || text.lowercased().contains("percent"), "no percentage: \(text)")
        }
    }
}
