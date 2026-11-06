import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

/// The API, answered per request: each request is kept with its body and answered by `respond`.
private final class RoomMediaAPIStub: URLProtocol {
    private static let lock = NSLock()
    private static var respond: (URLRequest) -> (Int, String) = { _ in (200, #"{"ok":true}"#) }
    private static var kept: [(URLRequest, Data)] = []

    static func answer(_ respond: @escaping (URLRequest) -> (Int, String)) {
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
        let (status, answer) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The client's half of the HTTP boundary with the API's room media routes: where each call goes, what a message
/// carries, and what each answer means. The API's half, and storage, are not exercised here.
final class RoomMediaHTTPUploaderTests: XCTestCase {
    private func uploader() -> HTTPRoomMediaUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomMediaAPIStub.self]
        let api = HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.test"),
                                        urlSession: URLSession(configuration: configuration),
                                        tokenProvider: { "user-token" })
        return HTTPRoomMediaUploader(api: api, storage: RoomMediaPutSession(backgroundIdentifier: nil))
    }

    private func refusal(_ error: Error) -> RoomMediaAPIRefusal? {
        guard case .refused(let refusal)? = error as? RoomMediaUploadError else { return nil }
        return refusal
    }

    func test_each_answer_means_what_the_api_says() async throws {
        let media = uploader()
        let request = RoomMediaInitRequest(filename: "IMG_0001.jpg", contentType: "image/jpeg", sizeBytes: 1_000,
                                           sha256: String(repeating: "a", count: 64), clientAttachmentId: "pm_test_000001")

        // Complete answered 404: the server released the upload (its reservation ran out), and init makes it anew.
        RoomMediaAPIStub.answer { _ in (404, #"{"error":{"code":"SESSION_NOT_FOUND","message":"not found"}}"#) }
        do {
            _ = try await media.completeUpload(sessionId: "room_1", attachmentId: "pm_test_000001")
            XCTFail("a 404 throws")
        } catch {
            XCTAssertEqual(refusal(error)?.code, "ATTACHMENT_RELEASED", "\(error)")
            XCTAssertEqual(refusal(error)?.isRetryable, true)
        }
        XCTAssertEqual(RoomMediaAPIStub.requests.last?.0.url?.path,
                       "/api/v1/sessions/room_1/attachments/pm_test_000001/complete")

        // A 404 anywhere else is no released upload: the room is not there for this account.
        do {
            _ = try await media.initUpload(sessionId: "room_1", request: request)
            XCTFail("a 404 throws")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .notAllowed)
        }

        // The API's own code is kept: an upload still landing is completed again, a reference the room refused is final.
        RoomMediaAPIStub.answer { _ in (409, #"{"error":{"code":"ATTACHMENT_UPLOAD_PENDING","message":"not yet"}}"#) }
        do {
            _ = try await media.completeUpload(sessionId: "room_1", attachmentId: "pm_test_000001")
            XCTFail("a 409 throws")
        } catch {
            XCTAssertEqual(refusal(error)?.code, "ATTACHMENT_UPLOAD_PENDING")
            XCTAssertEqual(refusal(error)?.isRetryable, true)
        }
        let photo = RoomMediaAttachment(attachmentId: "pm_test_000001", filename: "IMG_0001.jpg")
        RoomMediaAPIStub.answer { _ in (409, #"{"error":{"code":"ATTACHMENT_REFERENCE_REJECTED","message":"expired"}}"#) }
        do {
            try await media.postMessage(sessionId: "room_1", text: "Shared a photo.", attachments: [photo],
                                        clientId: "hm_test_1")
            XCTFail("a 409 throws")
        } catch {
            XCTAssertEqual(refusal(error)?.code, "ATTACHMENT_REFERENCE_REJECTED")
            XCTAssertEqual(refusal(error)?.isRetryable, false)
        }

        // The message names its files by id and name, under its client id.
        RoomMediaAPIStub.answer { _ in (200, #"{"ok":true}"#) }
        try await media.postMessage(sessionId: "room_1", text: "Shared a photo.", attachments: [photo], clientId: "hm_test_1")
        let (post, body) = try XCTUnwrap(RoomMediaAPIStub.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/api/v1/sessions/room_1/human-message")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Idempotency-Key"), "hm_test_1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Shared a photo.")
        XCTAssertEqual(json["clientId"] as? String, "hm_test_1")
        XCTAssertEqual(json["attachments"] as? [[String: String]],
                       [["attachmentId": "pm_test_000001", "filename": "IMG_0001.jpg"]])

        // Taking one back is a DELETE of it, by its id.
        await media.deleteUpload(sessionId: "room_1", attachmentId: "pm_test_000001")
        let (delete, _) = try XCTUnwrap(RoomMediaAPIStub.requests.last)
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertEqual(delete.url?.path, "/api/v1/sessions/room_1/attachments/pm_test_000001")
        XCTAssertEqual(delete.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
    }

    /// The PUT goes straight to storage with exactly the headers init returned: never the user's token, a cookie or a
    /// host of its own. Storage's refusal is told apart from the network.
    func test_the_put_carries_only_the_signed_headers_and_says_what_storage_answered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("put-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("original.jpg")
        try Data(repeating: 7, count: 2_048).write(to: file)
        let storage = RoomMediaPutSession(backgroundIdentifier: nil, protocolClasses: [RoomMediaAPIStub.self])
        let target = RoomMediaUploadTarget(
            url: URL(string: "https://storage.example.test/rooms/r1/pm_put_000001?sig=abc")!,
            headers: ["Content-Type": "image/jpeg", "x-ms-blob-type": "BlockBlob", "Authorization": "Bearer leaked",
                      "Cookie": "session=1", "Host": "elsewhere.example"]
        )
        RoomMediaAPIStub.answer { _ in (201, "") }
        let before = RoomMediaAPIStub.requests.count
        try await storage.put(file: file, to: target) { _, _ in }
        let put = try XCTUnwrap(RoomMediaAPIStub.requests.dropFirst(before).first?.0)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url, target.url)
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(put.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"), "the user's token never reaches storage")
        XCTAssertNil(put.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotEqual(put.value(forHTTPHeaderField: "Host"), "elsewhere.example")

        RoomMediaAPIStub.answer { _ in (403, "") }
        do {
            try await storage.put(file: file, to: target) { _, _ in }
            XCTFail("storage refused it")
        } catch let error as RoomMediaUploadError {
            XCTAssertEqual(error, .storageRefused(status: 403))
        }
    }
}
