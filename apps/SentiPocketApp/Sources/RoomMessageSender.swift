import Foundation

/// Why a room message did not post. Response bodies are never surfaced, only their class.
enum RoomSendError: Error, Equatable {
    case notConfigured
    case reauthenticationRequired
    /// 403: this account may read the room but not post in it (a viewer), or no longer belongs to it.
    case notAllowed
    /// The request may not have landed (network, 409, 429, 5xx). Retrying with the SAME client id is safe: the API
    /// de-duplicates on (user, client id).
    case retryable(retryAfterSeconds: Int?)
    /// The API refused the message itself (400/413/422). Retrying the same text will not help.
    case rejected

    var userMessage: String {
        switch self {
        case .notConfigured: return "This build cannot reach Senti."
        case .reauthenticationRequired: return "Sign in again to send."
        case .notAllowed: return "You can read this room but not post in it."
        case .retryable: return "Not sent. Check your connection and retry."
        case .rejected: return "Senti did not accept this message."
        }
    }
}

/// Posting a typed message as yourself. A protocol so the room coordinator is testable without a network.
protocol RoomMessageSending: Sendable {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws
}

/// Web parity (sentinelayer-web `useSessionLiveController.ts`): `POST /api/v1/sessions/{id}/human-message` with
/// the user's own bearer, `{text, clientId}` and an `Idempotency-Key`. The API authors the message on the server as
/// `human-<your GitHub username>`, so a phone can never post as anyone else; the stream then echoes it back with
/// `payload.clientMessageId == clientId`, which is how the pending row is matched.
final class HTTPRoomMessageSender: RoomMessageSending, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    /// The API's limit (`HUMAN_MESSAGE_MAX_LENGTH`), in Unicode code points: the API counts with Python's len, so an
    /// emoji made of several code points counts as several.
    static let maximumLength = 64_000

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              !text.isEmpty, text.unicodeScalars.count <= Self.maximumLength,
              clientId.utf8.count <= 120 else {
            throw RoomSendError.rejected
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/human-message"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientId, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "clientId": clientId])

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw RoomSendError.reauthenticationRequired
        case 403, 404:
            throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw RoomSendError.retryable(retryAfterSeconds: retryAfter)
        default:
            throw RoomSendError.rejected
        }
    }
}

/// Who is signed in, from `GET /api/v1/auth/me`: the GitHub username the API authors your messages under
/// (`human-<username>`), for "is this my message" and "am I mentioned", and who you are in action keys.
struct SignedInAccount: Equatable, Sendable {
    /// The author id the API writes your messages under: `human-<GitHub username, else account id>`, normalized
    /// as the API does (`_normalize_human_sender`).
    let authorId: String
    /// You in action idempotency keys, written as the web writes it (`createMessageActionIdempotencyKey`): the
    /// GitHub username, else the account id. Never a shared placeholder, so the API never takes one person's ack
    /// for another person's duplicate.
    let actorRef: String
    /// The account id, lowercased: what your read receipts carry.
    let accountId: String?
    /// The GitHub username as written, when the account has one.
    let login: String?

    init?(githubUsername: String?, accountId: String?) {
        let username = (githubUsername ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (accountId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = username.isEmpty ? id : username
        let ref = String(source
            .replacingOccurrences(of: #"[^A-Za-z0-9._:-]+"#, with: "-", options: .regularExpression)
            .prefix(48))
        let sender = source
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
        guard !ref.isEmpty, !sender.isEmpty else { return nil }
        authorId = "human-" + sender
        actorRef = ref
        self.accountId = id.isEmpty ? nil : id.lowercased()
        login = username.isEmpty ? nil : username
    }
}

protocol AccountIdentityProviding: Sendable {
    func currentAccount() async -> SignedInAccount?
}

final class HTTPAccountIdentity: AccountIdentityProviding, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func currentAccount() async -> SignedInAccount? {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let token = tokenProvider(), !token.isEmpty else { return nil }
        components.percentEncodedPath = "/api/v1/auth/me"
        components.query = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              tokenProvider() == token,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SignedInAccount(githubUsername: object["github_username"] as? String, accountId: object["id"] as? String)
    }
}

/// Message actions you take as yourself: replies and reactions, via `POST /api/v1/sessions/{id}/actions` with the
/// user's bearer, like the web. The API records the actor from the token (a human), checks the room role (a viewer
/// may ack, like and dislike; replying needs contributor) and de-duplicates on the idempotency key.
protocol RoomActionSending: Sendable {
    func sendAction(_ action: RoomActionRequest) async throws
}

struct RoomActionRequest: Equatable, Sendable {
    let sessionId: String
    let actionType: String
    let targetSequenceId: Int64
    let targetActionId: String?
    let note: String?
    let idempotencyKey: String

    static let replyLimit = 4_000
    static let reactionTypes: Set<String> = ["ack", "like", "dislike", "unlike", "undislike"]
    static let pinTypes: Set<String> = ["pin", "unpin"]

    /// A reply to a message (or, with `targetActionId`, to a reply). `nonce` is minted once per reply, so a retry
    /// sends the same key and the API de-duplicates it.
    static func reply(
        sessionId: String,
        sequenceId: Int64,
        toReply: String? = nil,
        text: String,
        actor: String,
        nonce: String = UUID().uuidString.lowercased()
    ) -> RoomActionRequest {
        RoomActionRequest(
            sessionId: sessionId,
            actionType: "reply",
            targetSequenceId: sequenceId,
            targetActionId: toReply,
            note: text,
            idempotencyKey: boundedKey("reply:\(sessionId):\(sequenceId):\(actor):\(nonce)")
        )
    }

    /// A reaction. `ack` is not retractable, so its key is stable per person and message (a second tap is a
    /// duplicate, as on the web). Like and dislike can be undone and redone, so each tap gets its own key.
    static func reaction(
        _ type: String,
        sessionId: String,
        sequenceId: Int64,
        actor: String,
        toReply: String? = nil
    ) -> RoomActionRequest {
        // A reaction on a reply targets the reply (`targetActionId`) inside its message's thread.
        let base = "\(type):\(sessionId):\(sequenceId):\(toReply.map { "\($0):" } ?? "")\(actor)"
        return RoomActionRequest(
            sessionId: sessionId,
            actionType: type,
            targetSequenceId: sequenceId,
            targetActionId: toReply,
            note: nil,
            idempotencyKey: boundedKey(type == "ack" ? base : "\(base):\(UUID().uuidString.lowercased())")
        )
    }

    /// Pin a message for the room, or unpin it. Each tap gets its own key, as on the web, so pin, unpin, pin again do
    /// not collapse.
    static func pin(_ isPinned: Bool, sessionId: String, sequenceId: Int64, actor: String) -> RoomActionRequest {
        let type = isPinned ? "pin" : "unpin"
        return RoomActionRequest(
            sessionId: sessionId,
            actionType: type,
            targetSequenceId: sequenceId,
            targetActionId: nil,
            note: nil,
            idempotencyKey: boundedKey("\(type):\(sessionId):\(sequenceId):\(actor):\(UUID().uuidString.lowercased())")
        )
    }

    private static func boundedKey(_ key: String) -> String {
        String(key.prefix(180))
    }
}

final class HTTPRoomActionSender: RoomActionSending, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !action.sessionId.isEmpty, action.sessionId.utf8.count <= 256,
              let encodedSession = action.sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              action.targetSequenceId > 0,
              action.actionType == "reply" || RoomActionRequest.reactionTypes.contains(action.actionType)
                || RoomActionRequest.pinTypes.contains(action.actionType),
              (action.note?.unicodeScalars.count ?? 0) <= RoomActionRequest.replyLimit,
              action.actionType != "reply" || !(action.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomSendError.rejected
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/actions"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }

        var body: [String: Any] = [
            "actionType": action.actionType,
            "targetSequenceId": action.targetSequenceId,
            "idempotencyKey": action.idempotencyKey
        ]
        if let target = action.targetActionId { body["targetActionId"] = target }
        if let note = action.note { body["note"] = note }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(action.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw RoomSendError.rejected
        }
    }
}

/// A saved transcript, as a message references it.
struct VoiceTranscriptAttachment: Equatable, Sendable {
    let attachmentId: String
    let filename: String
    let kind: String?
    let contentType: String?
    let sizeBytes: Int?
    let status: String?

    /// The attachment as the API's message payload takes it.
    var reference: [String: Any] {
        var json: [String: Any] = ["attachmentId": attachmentId, "filename": filename]
        if let kind { json["kind"] = kind }
        if let contentType { json["contentType"] = contentType }
        if let sizeBytes { json["sizeBytes"] = sizeBytes }
        if let status { json["status"] = status }
        return json
    }
}

/// What a voice room writes to the room, as you: your spoken turns (`channel: "voice"`, so the room shows them as
/// transcript), the transcript as a Markdown file, and the message that closes the call with it attached.
protocol VoiceRoomPosting: Sendable {
    /// The message that rings the agents: it mentions them, and opens the call's card in the room.
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws
}

extension HTTPRoomMessageSender: VoiceRoomPosting {
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        _ = try await post(sessionId: sessionId, path: "human-message", idempotencyKey: clientId, body: [
            "text": text, "clientId": clientId
        ])
    }

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {
        _ = try await post(sessionId: sessionId, path: "human-message", idempotencyKey: clientId, body: [
            "text": text, "clientId": clientId, "channel": "voice"
        ])
    }

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        let data = try await post(sessionId: sessionId, path: "attachments", idempotencyKey: clientId, body: [
            "filename": filename, "content": markdown, "contentType": "text/markdown", "clientAttachmentId": clientId
        ])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attachment = (root["attachment"] as? [String: Any]) ?? (root["attachmentId"] != nil ? root : nil),
              let id = attachment["attachmentId"] as? String, !id.isEmpty else {
            throw RoomSendError.rejected
        }
        return VoiceTranscriptAttachment(
            attachmentId: id,
            filename: (attachment["filename"] as? String) ?? filename,
            kind: attachment["kind"] as? String,
            contentType: attachment["contentType"] as? String,
            sizeBytes: attachment["sizeBytes"] as? Int,
            status: attachment["status"] as? String
        )
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {
        var body: [String: Any] = ["text": text, "clientId": clientId]
        if let transcript { body["attachments"] = [transcript.reference] }
        _ = try await post(sessionId: sessionId, path: "human-message", idempotencyKey: clientId, body: body)
    }

    /// One authenticated POST under the room, with the same rules and errors as a typed message.
    /// One room write. `session` replaces the live deadlines for a slow call (the room summary).
    func post(sessionId: String, path: String, idempotencyKey: String, body: [String: Any],
              session: URLSession? = nil) async throws -> Data {
        let (data, http) = try await postAnswer(sessionId: sessionId, path: path, idempotencyKey: idempotencyKey, body: body,
                                                session: session)
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RoomSendError.reauthenticationRequired
        case 403, 404:
            throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default:
            throw RoomSendError.rejected
        }
    }

    /// The same POST, answered as it came back: the caller reads the status and the request id.
    func postAnswer(sessionId: String, path: String, idempotencyKey: String, body: [String: Any],
                    session: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              idempotencyKey.utf8.count <= 120 else {
            throw RoomSendError.rejected
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/\(path)"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (session ?? urlSession).data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        if !(200..<300).contains(http.statusCode) {
            ClientProblems.shared.roomRequestFailed(path: path, status: http.statusCode, response: http)
        }
        return (data, http)
    }
}

/// Editing your own message or reply (web `editSessionMessage`).
protocol RoomMessageEditing: Sendable {
    func editMessage(sessionId: String, messageId: String, isReply: Bool, text: String, expectedRevision: Int64) async throws
}

extension HTTPRoomMessageSender: RoomMessageEditing {
    /// `PATCH /api/v1/sessions/{id}/messages/{message_id}` (or `/replies/{action_id}`) with the revision being edited,
    /// so an edit never lands over someone else's, an idempotency key, and the route-bound mutation token.
    func editMessage(sessionId: String, messageId: String, isReply: Bool, text: String, expectedRevision: Int64) async throws {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedId = messageId.addingPercentEncoding(withAllowedCharacters: allowed), !encodedId.isEmpty,
              !text.isEmpty, text.unicodeScalars.count <= Self.maximumLength else {
            throw RoomSendError.rejected
        }
        let resource = isReply ? "replies" : "messages"
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/\(resource)/\(encodedId)"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        let key = "edit-" + UUID().uuidString.lowercased()
        let template = isReply
            ? "PATCH /api/v1/sessions/{session_id}/replies/{action_id}"
            : "PATCH /api/v1/sessions/{session_id}/messages/{message_id}"
        guard let csrf = SessionMutationCSRF.token(bearer: token, sessionId: sessionId, routeTemplate: template,
                                                   idempotencyKey: key) else {
            throw RoomSendError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("session-mutation", forHTTPHeaderField: "X-Sentinelayer-Session-Mutation")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "expectedRevision": expectedRevision])
        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 409, 412: throw RoomSendError.rejected   // it changed since: the room has the newer text
        case 425, 429, 500..<600: throw RoomSendError.retryable(retryAfterSeconds: nil)
        default: throw RoomSendError.rejected
        }
    }
}

/// Renaming a room (web `setSessionTitle`): its owner only, never a breakout.
protocol RoomTitleSetting: Sendable {
    /// The name as the API saved it.
    func setTitle(sessionId: String, title: String) async throws -> String
}

extension HTTPRoomMessageSender: RoomTitleSetting {
    /// `POST /api/v1/sessions/{id}/title` with `{"title": ...}`, under an idempotency key.
    func setTitle(sessionId: String, title: String) async throws -> String {
        let data = try await post(sessionId: sessionId, path: "title", idempotencyKey: "title-" + UUID().uuidString.lowercased(),
                                  body: ["title": title])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let saved = json?["title"] as? String, !saved.isEmpty else { return title }
        return saved
    }
}

extension HTTPRoomMessageSender {
    /// A POST to a member or invitation route under the room: the bearer, the native mutation intent header, an
    /// idempotency key and the route-bound mutation token (`SessionMutationCSRF`), as editing and admissions send
    /// them. Answered as it came back; the caller reads the status.
    func sessionMutation(sessionId: String, path: String, routeTemplate: String, keyPrefix: String,
                         body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RoomSendError.rejected
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/\(path)"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        let key = keyPrefix + "-" + UUID().uuidString.lowercased()
        guard let csrf = SessionMutationCSRF.token(bearer: token, sessionId: sessionId, routeTemplate: routeTemplate,
                                                   idempotencyKey: key) else {
            throw RoomSendError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("session-mutation", forHTTPHeaderField: "X-Sentinelayer-Session-Mutation")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        if http.statusCode == 401 { throw RoomSendError.reauthenticationRequired }
        if !(200..<300).contains(http.statusCode) {
            ClientProblems.shared.roomRequestFailed(path: path, status: http.statusCode, response: http)
        }
        return (data, http)
    }
}

extension HTTPRoomMessageSender {
    /// `POST /api/v1/sessions`: a new private room you own, of a type (Carter, #55287: "rooms optimized just for
    /// specific things like study together"). The id is made here; the mutation token is signed over it and the
    /// route, as the API checks before anything else.
    func createRoom(title: String, roomType: String, maxMembers: Int = 25) async throws -> String {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        components.percentEncodedPath = "/api/v1/sessions"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        let sessionId = UUID().uuidString.lowercased()
        let key = "create-" + UUID().uuidString.lowercased()
        guard let csrf = SessionMutationCSRF.token(bearer: token, sessionId: sessionId, routeTemplate: "POST /api/v1/sessions",
                                                   idempotencyKey: key) else {
            throw RoomSendError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("session-mutation", forHTTPHeaderField: "X-Sentinelayer-Session-Mutation")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        var body: [String: Any] = ["sessionId": sessionId, "title": title, "visibility": "private", "maxMembers": maxMembers]
        // A general room is the API's default; only another kind is sent (warden).
        if roomType != "general" { body["roomType"] = roomType }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (object?["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionId
        case 401: throw RoomSendError.reauthenticationRequired
        case 403: throw RoomSendError.notAllowed
        case 429, 500..<600: throw RoomSendError.retryable(retryAfterSeconds: nil)
        default: throw RoomSendError.rejected
        }
    }
}

extension HTTPRoomMessageSender: VoiceLining {
    /// `POST /api/v1/sessions/{id}/voice/turn` (API #1062) with your own bearer; the answer streams back as events.
    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let apiBaseURL,
                          var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
                        throw VoiceLineError.unavailable
                    }
                    guard let token = tokenProvider(), !token.isEmpty else { throw VoiceLineError.notAllowed }
                    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                    guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
                          let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
                        throw VoiceLineError.failed
                    }
                    components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/voice/turn"
                    components.query = nil
                    guard let url = components.url else { throw VoiceLineError.unavailable }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 25
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    // The route's limits: 2,000 characters a turn, 12 earlier turns, 4,000 characters of them.
                    var budget = 4_000
                    var context: [[String: String]] = []
                    for turn in history.suffix(12).reversed() {
                        let piece = String(turn.text.prefix(2_000))
                        guard budget - piece.count >= 0, !piece.isEmpty else { break }
                        budget -= piece.count
                        context.insert(["speaker": String(turn.speaker.prefix(80)), "text": piece], at: 0)
                    }
                    var body: [String: Any] = ["text": String(text.prefix(2_000)), "callId": callId, "history": context]
                    body["agentId"] = agentId.map { $0.lowercased() } ?? NSNull()
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await urlSession.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    switch http?.statusCode ?? 0 {
                    case 200: break
                    case 503, 404: throw VoiceLineError.unavailable
                    case 429:
                        throw VoiceLineError.rateLimited(
                            retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                    case 401, 403: throw VoiceLineError.notAllowed
                    default: throw VoiceLineError.failed
                    }
                    var reader = VoiceLineEventReader()
                    for try await line in bytes.lines {
                        switch reader.read(line) {
                        case .none: continue
                        case .failed: throw VoiceLineError.failed
                        case .event(let event):
                            continuation.yield(event)
                            if case .done = event {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is VoiceLineError ? error : VoiceLineError.failed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension HTTPRoomMessageSender: VoiceEndpointing {
    /// `POST /api/v1/sessions/{id}/voice/endpoint` with your own bearer: `{"done": 0..1}`.
    func finished(sessionId: String, text: String, callId: String) async throws -> Double {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw VoiceLineError.unavailable
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw VoiceLineError.notAllowed }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw VoiceLineError.failed
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/voice/endpoint"
        components.query = nil
        guard let url = components.url else { throw VoiceLineError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // On the critical path of a conversation: an answer later than this is no faster than the plain pause.
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": String(text.prefix(500)), "callId": callId])
        let (data, response) = try await urlSession.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 503, 404: throw VoiceLineError.unavailable
        case 429: throw VoiceLineError.rateLimited(retryAfter: nil)
        case 401, 403: throw VoiceLineError.notAllowed
        default: throw VoiceLineError.failed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let done = (json["done"] as? NSNumber)?.doubleValue, done >= 0, done <= 1 else {
            throw VoiceLineError.failed
        }
        return done
    }
}
