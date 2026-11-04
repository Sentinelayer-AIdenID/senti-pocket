import Foundation
import XCTest
@testable import PocketUI

/// A thread's unsent reply is kept on the phone, as the room's own box keeps its text (#61872: a half-written reply was
/// lost when new replies folded in).
final class RoomReplyDraftsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "reply-drafts-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var base: String { RoomComposerDraft.savedKey(sessionId: "room_1", account: "acct-1") }

    func test_a_draft_survives_the_thread_closing_and_reopening() {
        let drafts = RoomReplyDrafts(base: base, defaults: defaults)
        drafts.save("half a thought", thread: 42, reply: nil)
        // The sheet closes and opens again: what it reads back.
        XCTAssertEqual(drafts.restore(thread: 42)?.text, "half a thought")
        XCTAssertNil(drafts.restore(thread: 42)?.reply)
    }

    /// A new room screen (after a relaunch, or the room left and opened again) has no memory of the thread's box: the
    /// text comes back from the phone.
    func test_a_draft_survives_a_new_room_screen() {
        RoomReplyDrafts(base: base, defaults: defaults).save("still writing", thread: 42, reply: "reply-7")
        let relaunched = RoomReplyDrafts(base: RoomComposerDraft.savedKey(sessionId: "room_1", account: "acct-1"),
                                         defaults: defaults)
        XCTAssertEqual(relaunched.restore(thread: 42)?.text, "still writing")
        XCTAssertEqual(relaunched.restore(thread: 42)?.reply, "reply-7", "answering the same reply")
        XCTAssertNil(RoomReplyDrafts(base: RoomComposerDraft.savedKey(sessionId: "room_1", account: "acct-2"), defaults: defaults)
            .restore(thread: 42), "another account never sees it")
        XCTAssertTrue(relaunched.key(thread: 42, reply: nil).hasPrefix("pocket.draft."), "sign-out forgets it with the rest")
    }

    func test_two_threads_keep_separate_drafts() {
        let drafts = RoomReplyDrafts(base: base, defaults: defaults)
        drafts.save("for the first", thread: 42, reply: nil)
        drafts.save("for the second", thread: 77, reply: nil)
        XCTAssertEqual(drafts.restore(thread: 42)?.text, "for the first")
        XCTAssertEqual(drafts.restore(thread: 77)?.text, "for the second")
        XCTAssertNotEqual(drafts.key(thread: 42, reply: nil), drafts.key(thread: 77, reply: nil))
        drafts.save("", thread: 42, reply: nil)
        XCTAssertNil(drafts.restore(thread: 42), "an emptied box keeps nothing")
        XCTAssertEqual(drafts.restore(thread: 77)?.text, "for the second", "the other thread's is untouched")
    }

    /// The box answers one thing at a time: the text moves with what it answers.
    func test_answering_a_reply_moves_the_text_with_it() {
        let drafts = RoomReplyDrafts(base: base, defaults: defaults)
        drafts.save("thinking", thread: 42, reply: nil)
        drafts.save("@pat thinking", thread: 42, reply: "reply-7")
        XCTAssertNil(defaults.string(forKey: drafts.key(thread: 42, reply: nil)), "nothing left where it was")
        XCTAssertEqual(drafts.restore(thread: 42)?.text, "@pat thinking")
        drafts.save("@pat thinking", thread: 42, reply: nil)
        XCTAssertNil(defaults.string(forKey: drafts.key(thread: 42, reply: "reply-7")))
        XCTAssertNil(drafts.restore(thread: 42)?.reply, "answering the message again")
    }

    /// Only the server having the reply lets its saved text go, and text written since is kept.
    func test_the_sent_text_goes_and_newer_text_stays() {
        let drafts = RoomReplyDrafts(base: base, defaults: defaults)
        drafts.save("on it", thread: 42, reply: "reply-7")
        drafts.forgetSent("on it", thread: 42, reply: "reply-7")
        XCTAssertNil(drafts.restore(thread: 42))

        drafts.save("a second thought", thread: 42, reply: nil)
        drafts.forgetSent("on it", thread: 42, reply: nil)
        XCTAssertEqual(drafts.restore(thread: 42)?.text, "a second thought", "newer text is never taken for the sent one")
        drafts.forgetSent("🎫 Ticket: a second thought", thread: 42, reply: nil)
        XCTAssertNil(drafts.restore(thread: 42), "a ticket request carries the typed words")
    }
}
