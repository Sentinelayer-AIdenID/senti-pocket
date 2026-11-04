import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// Photos and files on replies (sentinelayer-api #1135): what Pocket sends, what it reads back, the reply bell, and what
// an API that takes no files on a reply gets.

/// The API, answered per request: each request is kept with its body, and answered by `respond`.
private final class ReplyAPIStub: URLProtocol {
    private static let lock = NSLock()
    private static var respond: (URLRequest, Data) -> (Int, String) = { _, _ in (200, #"{"ok":true}"#) }
    private static var kept: [(URLRequest, Data)] = []

    static func answer(_ respond: @escaping (URLRequest, Data) -> (Int, String)) {
        lock.lock()
        self.respond = respond
        lock.unlock()
    }

    static var requests: [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.kept.append((request, body))
        let respond = Self.respond
        Self.lock.unlock()
        let (status, answer) = respond(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A quiet room: its tail, and its replies as one read of `/actions` returns them (the room's, or a thread's).
private final class ThreadTransport: RoomTransport, @unchecked Sendable {
    let tail: RoomEventPage
    let actions: RoomActionsPage

    init(tail: RoomEventPage, actions: RoomActionsPage) {
        self.tail = tail
        self.actions = actions
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage { tail }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { actions }
}

/// Takes every action at once.
private struct AcceptingActions: RoomActionSending {
    func sendAction(_ action: RoomActionRequest) async throws {}
}

@MainActor
final class ReplyAttachmentsTests: XCTestCase {
    private let target = RoomMediaReplyTarget(sequenceId: 42, replyId: nil, name: "agent-a1")
    private let photo = RoomMediaAttachment(attachmentId: "pm_test_000001", filename: "IMG_0001.jpg", kind: "image",
                                            contentType: "image/jpeg", sizeBytes: 342_490,
                                            sha256: String(repeating: "a", count: 64), status: "uploaded")

    private func uploader() -> HTTPRoomMediaUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyAPIStub.self]
        let api = HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.test"),
                                        urlSession: URLSession(configuration: configuration),
                                        tokenProvider: { "user-token" })
        return HTTPRoomMediaUploader(api: api, storage: RoomMediaPutSession(backgroundIdentifier: nil))
    }

    private func refusal(_ error: Error) -> RoomMediaAPIRefusal? {
        guard case .refused(let refusal)? = error as? RoomMediaUploadError else { return nil }
        return refusal
    }

    /// The API's answer to a reply, as `create_session_message_action` returns it: the stored action, its files in the
    /// message's read shape (the request's references with pointer metadata added).
    private static func storedReply(from body: Data) -> String {
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let files = (request["attachments"] as? [[String: Any]] ?? []).map { reference -> [String: Any] in
            var read = reference
            read["previewAttachmentId"] = NSNull()
            read["uploadedBy"] = "human-pat"
            read["uploadedAt"] = "2026-11-04T09:59:00+00:00"
            read["disposition"] = "inline"
            read["pointer"] = "attachment://made-up"
            return read
        }
        let action: [String: Any] = [
            "id": "9b2f7a40-0000-4000-8000-000000000001", "sessionId": "room_1", "actionType": "reply",
            "targetSequenceId": request["targetSequenceId"] ?? 0, "targetActionId": request["targetActionId"] ?? NSNull(),
            "actorKind": "human", "actorId": "human-pat", "note": request["note"] ?? NSNull(), "metadata": [:],
            "attachments": files, "idempotencyKey": request["idempotencyKey"] ?? "",
            "createdAt": "2026-11-04T10:00:00+00:00", "messageRevision": 1
        ]
        let answer: [String: Any] = ["ok": true, "duplicate": false, "action": action]
        return String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    // MARK: - Sending

    /// A reply with a photo goes out in the message's reference shape, and the reply the API stores comes back into the
    /// thread with that photo: the same id, name and kind, shown as a message's photo is.
    func test_a_reply_with_an_image_round_trips() async throws {
        let media = uploader()
        ReplyAPIStub.answer { _, body in (200, Self.storedReply(from: body)) }
        let outcome = try await media.postReply(sessionId: "room_1", to: target, text: "  look at this ",
                                                attachments: [photo], idempotencyKey: "reply-media:hm_1")
        XCTAssertEqual(outcome, .posted)

        let (request, body) = try XCTUnwrap(ReplyAPIStub.requests.last)
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/room_1/actions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "reply-media:hm_1")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["actionType"] as? String, "reply")
        XCTAssertEqual(sent["targetSequenceId"] as? Int, 42)
        XCTAssertNil(sent["targetActionId"], "it answers the message")
        XCTAssertEqual(sent["note"] as? String, "look at this")
        XCTAssertEqual(sent["idempotencyKey"] as? String, "reply-media:hm_1")
        let reference = try XCTUnwrap((sent["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(reference["attachmentId"] as? String, "pm_test_000001")
        XCTAssertEqual(reference["filename"] as? String, "IMG_0001.jpg")
        XCTAssertEqual(reference["kind"] as? String, "image")
        XCTAssertEqual(reference["contentType"] as? String, "image/jpeg")
        XCTAssertEqual(reference["sizeBytes"] as? Int, 342_490)
        XCTAssertEqual(reference["sha256"] as? String, String(repeating: "a", count: 64))

        // Read back: the thread's read of `/actions` returns the stored reply.
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.storedReply(from: body).utf8)) as? [String: Any])
        let page = try JSONDecoder().decode(RoomActionsPage.self, from: JSONSerialization.data(withJSONObject: [
            "actions": [stored["action"]!], "projection": [:]
        ]))
        let reply = try XCTUnwrap(page.replies.first)
        XCTAssertEqual(reply.attachments.map(\.attachmentId), ["pm_test_000001"])
        XCTAssertEqual(reply.attachments.first?.filename, "IMG_0001.jpg")
        XCTAssertEqual(reply.attachments.first?.kind, .image)

        let room = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: ThreadTransport(
                tail: RoomEventPage(messages: [RoomMessage(id: "evt-42", sequenceId: 42, kind: .message,
                                                           authorId: "agent-a1", authorName: "agent-a1", isHuman: false,
                                                           text: "the parent", timestamp: "2026-11-04T09:58:00+00:00")]),
                actions: page
            ),
            actionSender: AcceptingActions(),
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        room.resume()
        room.send(.openThread(sequenceId: 42))
        await waitUntil("the thread shows the reply") { room.state.thread?.replies.first?.attachments.isEmpty == false }
        let row = try XCTUnwrap(room.state.thread?.replies.first)
        XCTAssertEqual(row.text, "look at this")
        XCTAssertEqual(row.attachments.map(\.attachmentId), ["pm_test_000001"])
        XCTAssertEqual(row.attachments.first?.kind, .image, "shown as a message's photo is")
        XCTAssertEqual(room.attachmentInfo("pm_test_000001")?.filename, "IMG_0001.jpg", "and it opens like one")
        room.pause()
    }

    /// The API refuses a reply with neither words nor files (422): the sender never sends one.
    func test_the_sender_refuses_an_empty_reply() async throws {
        let media = uploader()
        let before = ReplyAPIStub.requests.count
        do {
            _ = try await media.postReply(sessionId: "room_1", to: target, text: " \n ", attachments: [],
                                          idempotencyKey: "reply-media:hm_empty")
            XCTFail("an empty reply throws")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
        do {
            _ = try await media.postReply(sessionId: "room_1", to: target, text: nil, attachments: [],
                                          idempotencyKey: "reply-media:hm_nil")
            XCTFail("an empty reply throws")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
        XCTAssertEqual(ReplyAPIStub.requests.count, before, "nothing is sent")

        // A reply of a photo alone carries no note at all.
        ReplyAPIStub.answer { _, body in (200, Self.storedReply(from: body)) }
        _ = try await media.postReply(sessionId: "room_1", to: target, text: nil, attachments: [photo],
                                      idempotencyKey: "reply-media:hm_photo")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ReplyAPIStub.requests.last).1) as? [String: Any])
        XCTAssertNil(sent["note"], "no words are made up for a photo")

        // The words-only reply sender keeps its own guard.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplyAPIStub.self]
        let actions = HTTPRoomActionSender(apiBaseURL: URL(string: "https://api.example.test"),
                                           urlSession: URLSession(configuration: configuration),
                                           tokenProvider: { "user-token" })
        let count = ReplyAPIStub.requests.count
        do {
            try await actions.sendAction(.reply(sessionId: "room_1", sequenceId: 42, text: "   ", actor: "pat"))
            XCTFail("an empty reply throws")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
        XCTAssertEqual(ReplyAPIStub.requests.count, count)
    }

    /// An API from before reply attachments takes the reply's words and drops its files; one that forbids the field
    /// says so. Both are told apart from a refusal of the reply itself, which reads as a message's refusal does.
    func test_an_api_that_takes_no_files_on_a_reply_is_told_apart() async throws {
        let media = uploader()
        ReplyAPIStub.answer { _, _ in
            (200, #"{"ok":true,"duplicate":false,"action":{"id":"x","actionType":"reply","targetSequenceId":42,"note":"look"}}"#)
        }
        var outcome = try await media.postReply(sessionId: "room_1", to: target, text: "look", attachments: [photo],
                                                idempotencyKey: "reply-media:hm_old")
        XCTAssertEqual(outcome, .filesNotTaken(replyPosted: true), "its words went; its files did not")

        ReplyAPIStub.answer { _, _ in
            (422, #"{"detail":[{"type":"extra_forbidden","loc":["body","attachments"],"msg":"Extra inputs are not permitted"}]}"#)
        }
        outcome = try await media.postReply(sessionId: "room_1", to: target, text: "look", attachments: [photo],
                                            idempotencyKey: "reply-media:hm_forbid")
        XCTAssertEqual(outcome, .filesNotTaken(replyPosted: false), "nothing went")

        // Too many files, or a file already sent: the reply's own refusal, never "Photos can't go in a reply".
        ReplyAPIStub.answer { _, _ in
            (422, #"{"detail":[{"type":"too_long","loc":["body","attachments"],"msg":"List should have at most 5 items"}]}"#)
        }
        do {
            _ = try await media.postReply(sessionId: "room_1", to: target, text: nil, attachments: [photo],
                                          idempotencyKey: "reply-media:hm_cap")
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(refusal(error)?.status, 422)
        }
        ReplyAPIStub.answer { _, _ in (409, #"{"error":{"code":"ATTACHMENT_REFERENCE_REJECTED","message":"already sent"}}"#) }
        do {
            _ = try await media.postReply(sessionId: "room_1", to: target, text: nil, attachments: [photo],
                                          idempotencyKey: "reply-media:hm_sent")
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(refusal(error)?.code, "ATTACHMENT_REFERENCE_REJECTED")
            XCTAssertEqual(RoomMediaUploadCoordinator.reason(for: error),
                           "These files can't be sent any more: an upload not sent within a day expires. Discard this message and pick them again.",
                           "the message route's refusal, read as for a message")
        }
        ReplyAPIStub.answer { _, _ in (403, #"{"error":{"code":"SESSION_FORBIDDEN","message":"viewer"}}"#) }
        do {
            _ = try await media.postReply(sessionId: "room_1", to: target, text: nil, attachments: [photo],
                                          idempotencyKey: "reply-media:hm_viewer")
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .notAllowed)
        }
    }

    // MARK: - Reading

    func test_reply_photos_show_in_the_room_and_a_removed_one_loses_its_picture() async throws {
        let parent = RoomMessage(id: "evt-42", sequenceId: 42, kind: .message, authorId: "agent-a1",
                                 authorName: "agent-a1", isHuman: false, text: "the parent",
                                 timestamp: "2026-11-04T09:58:00+00:00")
        let page = try JSONDecoder().decode(RoomActionsPage.self, from: Data("""
        {"actions":[{"id":"r1","actionType":"reply","targetSequenceId":42,"actorId":"human-pat","note":"",
          "createdAt":"2026-11-04T10:00:00+00:00","attachments":[
            {"attachmentId":"pm_test_000001","filename":"IMG_0001.jpg","kind":"image","contentType":"image/jpeg"},
            {"attachmentId":"pm_test_000002","filename":"IMG_0002.jpg","kind":"image","removed":true}]}],
         "projection":{}}
        """.utf8))
        let room = RoomChatCoordinator(
            sessionId: "room_1", title: "Room",
            transport: ThreadTransport(tail: RoomEventPage(messages: [parent]), actions: page),
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        var support: [RoomReplyAttachmentSupport] = []
        room.onReplyAttachmentSupport = { support.append($0) }
        room.resume()
        func replyRow() -> RoomChatMessageRow? {
            room.state.rows.compactMap { row -> RoomChatMessageRow? in
                if case .message(let message) = row, message.inlineReplyId == "r1" { return message }
                return nil
            }.first
        }
        await waitUntil("the reply shows in the room") { replyRow() != nil }
        XCTAssertEqual(replyRow()?.attachments.map(\.attachmentId), ["pm_test_000001", "pm_test_000002"])
        XCTAssertEqual(replyRow()?.attachments.map(\.isRemoved), [false, true])
        XCTAssertEqual(room.attachmentInfo("pm_test_000001")?.kind, .image)
        XCTAssertTrue(support.contains(.supported), "the room's uploads learn the API takes files on a reply")
        room.pause()
    }

    // MARK: - The reply bell

    /// Someone answered your message: the bell's reply row has its own mark, and opening it opens the thread at that
    /// reply.
    func test_the_reply_bell_kind_opens_the_thread_at_the_reply() async throws {
        let bell = try JSONDecoder().decode(SentiNotificationsPage.self, from: Data("""
        {"notifications":[{"id":"n1","kind":"reply","subjectId":"room_1","title":"pat replied","body":"Photo",
          "actionUrl":"https://sentinelayer.com/dashboard/sessions/room_1?message=42&reply=9b2f7a40-0000-4000-8000-000000000001",
          "isRead":false,"createdAt":"2026-11-04T10:00:00Z"}]}
        """.utf8))
        final class Bell: NotificationsTransport, @unchecked Sendable {
            let page: SentiNotificationsPage
            init(_ page: SentiNotificationsPage) { self.page = page }
            func notifications() async throws -> SentiNotificationsPage { page }
        }
        let notifications = NotificationsCoordinator(transport: Bell(bell), marker: nil, onReauthenticationRequired: {})
        await notifications.refresh()
        let row = try XCTUnwrap(notifications.state.unread.first)
        XCTAssertEqual(row.kind, "reply")
        XCTAssertEqual(row.body, "Photo", "the server's words for a reply of a photo alone")
        XCTAssertTrue(row.canOpen)
        let link = try XCTUnwrap(notifications.open("n1"))
        XCTAssertEqual(link.messageSequence, 42)
        XCTAssertEqual(link.replyId, "9b2f7a40-0000-4000-8000-000000000001")

        let parent = RoomMessage(id: "evt-42", sequenceId: 42, kind: .message, authorId: "human-me",
                                 authorName: "me", isHuman: true, text: "the parent",
                                 timestamp: "2026-11-04T09:58:00+00:00")
        let replies = RoomActionsPage(replies: [
            RoomReply(id: "9b2f7a40-0000-4000-8000-000000000000", targetSequenceId: 42, authorId: "agent-a1",
                      text: "earlier", createdAt: "2026-11-04T09:59:00+00:00"),
            RoomReply(id: "9b2f7a40-0000-4000-8000-000000000001", targetSequenceId: 42, authorId: "human-pat",
                      text: "", createdAt: "2026-11-04T10:00:00+00:00",
                      attachments: [RoomAttachment(attachmentId: "pm_test_000001", filename: "IMG_0001.jpg", kind: .image)])
        ])
        let room = RoomChatCoordinator(
            sessionId: link.sessionId, title: "Room",
            transport: ThreadTransport(tail: RoomEventPage(messages: [parent]), actions: replies),
            focusSequenceId: link.messageSequence,
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        room.resume()
        // What the room screen does with the route a reply link opens (`applyRouteLinksOnce`).
        room.openThread(try XCTUnwrap(link.messageSequence), at: link.replyId)
        await waitUntil("the thread is open with its replies") { room.state.thread?.replies.count == 2 }
        XCTAssertEqual(room.state.thread?.parent.sequenceId, 42)
        XCTAssertEqual(room.state.thread?.focusReplyId, "9b2f7a40-0000-4000-8000-000000000001", "at that reply")
        room.send(.closeThread)
        room.send(.openThread(sequenceId: 42))
        XCTAssertNil(room.state.thread?.focusReplyId, "opened again by hand, it is not marked again")
        room.pause()
    }

    // MARK: - A thread's unsent reply, kept on the phone (#61872)

    /// Answers each reply action as scripted, and counts them.
    private final class ScriptedActions: RoomActionSending, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        let error: Error?
        init(error: Error? = nil) { self.error = error }
        var calls: Int { lock.withLock { _calls } }
        func sendAction(_ action: RoomActionRequest) async throws {
            lock.withLock { _calls += 1 }
            if let error { throw error }
        }
    }

    private func draftRoom(_ actions: ScriptedActions, account: String) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1", title: "Room",
            transport: ThreadTransport(
                tail: RoomEventPage(messages: [RoomMessage(id: "evt-42", sequenceId: 42, kind: .message, authorId: "agent-a1",
                                                           authorName: "agent-a1", isHuman: false, text: "the parent",
                                                           timestamp: "2026-11-04T09:58:00+00:00")]),
                actions: RoomActionsPage()
            ),
            actionSender: actions,
            ownAuthorIds: ["human-pat"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            // As the room screen opens it: the account's outbox, under which its text is kept.
            outbox: RoomSendOutbox(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("reply-drafts-outbox-\(UUID().uuidString).json")),
            outboxAccount: account,
            onReauthenticationRequired: {}
        )
    }

    /// What the thread's box saved as it was typed goes only once the server has the reply; a send that failed keeps it,
    /// answering the same reply, to be sent again.
    func test_a_reply_draft_is_cleared_after_a_successful_send_and_kept_after_a_failed_one() async {
        let account = "acct-\(UUID().uuidString)"
        let drafts = RoomReplyDrafts(base: RoomComposerDraft.savedKey(sessionId: "room_1", account: account))
        defer {
            for (thread, reply) in [(Int64(42), String?.none), (43, "reply-9"), (44, nil)] {
                drafts.save("", thread: thread, reply: reply)
            }
        }

        let accepting = ScriptedActions()
        let room = draftRoom(accepting, account: account)
        room.resume()
        drafts.save("on it", thread: 42, reply: nil)
        room.send(.sendReply(sequenceId: 42, text: "on it"))
        await waitUntil("accepted and let go") { accepting.calls == 1 && drafts.restore(thread: 42) == nil }
        XCTAssertNil(drafts.restore(thread: 42), "the server has it: nothing to bring back")

        // A reply with files: its words go once the server has it too.
        drafts.save("look", thread: 44, reply: nil)
        await room.replyPosted(to: 44, answering: nil, text: "look")
        XCTAssertNil(drafts.restore(thread: 44))
        room.pause()

        let refusing = ScriptedActions(error: RoomSendError.retryable(retryAfterSeconds: nil))
        let failing = draftRoom(refusing, account: account)
        failing.resume()
        drafts.save("@sam later", thread: 43, reply: "reply-9")
        failing.send(.sendReplyToReply(sequenceId: 43, replyId: "reply-9", text: "@sam later"))
        await waitUntil("refused") { refusing.calls == 1 && failing.state.notice != nil }
        XCTAssertEqual(drafts.restore(thread: 43)?.text, "@sam later", "a failed send keeps what was written")
        XCTAssertEqual(drafts.restore(thread: 43)?.reply, "reply-9", "answering the same reply")
        failing.pause()
    }

    /// The room lets a reply's saved words go when they reached the room another way (an older API took them in the
    /// reply, or "Send as a new message" posted them): reopening the thread never brings them back to be sent twice.
    func test_words_that_reached_the_room_another_way_leave_the_thread_draft() async {
        let account = "acct-\(UUID().uuidString)"
        let drafts = RoomReplyDrafts(base: RoomComposerDraft.savedKey(sessionId: "room_1", account: account))
        defer {
            drafts.save("", thread: 42, reply: nil)
            drafts.save("", thread: 43, reply: "reply-7")
        }
        let room = draftRoom(ScriptedActions(), account: account)
        drafts.save("look", thread: 42, reply: nil)
        drafts.save("see this", thread: 43, reply: "reply-7")

        // As the room screen wires "Send as a new message" posting.
        room.forgetReplyDraft(thread: 43, answering: "reply-7", text: "see this")
        XCTAssertNil(drafts.restore(thread: 43), "reopening the thread brings nothing back")
        XCTAssertEqual(drafts.restore(thread: 42)?.text, "look", "another thread's draft stays")

        // As it wires an older API taking the words.
        await room.replyPosted(to: 42, answering: nil, text: "look")
        XCTAssertNil(drafts.restore(thread: 42))
    }
}
