import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Live room updates over `GET /api/v1/sessions/{id}/stream` (server-sent events), source-bound to
// sentinelayer-api `stream_session_events`. The web reads this stream with fetch (not EventSource) so it can send
// the bearer; URLSession.bytes does the same here. Only `data:` lines carry content; event names are unused.

/// Incremental SSE line parser. Feed it lines (without their terminators); it returns each completed event's
/// data, with multi-line `data:` fields joined by "\n", when a blank line ends the event.
public struct SSELineParser: Equatable, Sendable {
    private var dataLines: [String] = []
    /// The last `id:` field seen, per the SSE spec. The phone resumes by sequence instead, but this is kept for
    /// diagnostics and tests.
    public private(set) var lastEventId: String?

    public init() {}

    public mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return data
        }
        if line.hasPrefix(":") { return nil }   // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "id": lastEventId = String(value)
        default: break   // event:, retry: and unknown fields are ignored, as the web client does
        }
        return nil
    }
}

/// One decoded stream frame.
public enum RoomStreamFrame: Equatable, Sendable {
    /// A displayable room row.
    case message(RoomMessage)
    /// A durable event the room does not display; carries its sequence so the resume point still advances.
    case nonDisplayable(sequenceId: Int64)
    /// `agent_composing` control: an agent is preparing a reply. Never enters the transcript.
    case composing(agentId: String, targetSequenceId: Int64?)
    /// Any other control frame (for example an observability tick).
    case control
    /// The server reported a stream error; the client reconnects with backoff.
    case serverError(code: String?)

    public static func decode(_ data: String) -> RoomStreamFrame? {
        guard let bytes = data.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: bytes) else {
            return nil
        }
        switch json["type"]?.stringValue {
        case "error":
            return .serverError(code: json["error"]?["code"]?.stringValue)
        case "control":
            if json["control"]?.stringValue == "agent_composing" {
                let agentId = json["agentId"]?.stringValue ?? json["agent"]?["id"]?.stringValue ?? ""
                return agentId.isEmpty ? .control : .composing(
                    agentId: agentId,
                    targetSequenceId: json["targetSequenceId"]?.intValue
                )
            }
            return .control
        default:
            if let message = RoomMessage(json: json) { return .message(message) }
            if let sequence = json["sequenceId"]?.intValue ?? json["sequence_id"]?.intValue, sequence > 0 {
                return .nonDisplayable(sequenceId: sequence)
            }
            return nil
        }
    }
}

/// Why a stream connection ended. `retryAfterSeconds` is honoured by the reconnect backoff.
public enum RoomStreamEnd: Equatable, Sendable {
    /// Clean end (the server closes long connections periodically). Reconnect immediately.
    case closed
    /// Retryable failure (network, 5xx, 429, a server error frame).
    case retryable(retryAfterSeconds: Int?)
    /// Terminal: the token is no longer valid. The app must ask the user to sign in again.
    case reauthenticationRequired
    /// Terminal: no access to this room (401/403/404/410 per the web client); do not reconnect.
    case accessDenied
}

/// Reconnect delay, matching the web: immediate after a connection that delivered events, otherwise 2s doubling
/// to 30s, and never shorter than a server `Retry-After`.
public struct RoomStreamBackoff: Equatable, Sendable {
    public private(set) var failures = 0
    public init() {}

    public mutating func delayAfter(_ end: RoomStreamEnd, deliveredEvents: Bool) -> TimeInterval? {
        switch end {
        case .reauthenticationRequired, .accessDenied:
            return nil
        case .closed where deliveredEvents:
            failures = 0
            return 0
        case .closed, .retryable:
            if deliveredEvents { failures = 0 }
            failures += 1
            let exponential = min(30.0, 2.0 * pow(2.0, Double(max(failures - 1, 0))))
            if case .retryable(let retryAfter?) = end {
                return max(exponential, Double(retryAfter))
            }
            return exponential
        }
    }
}

extension HTTPSessionTransport {
    /// Opens one stream connection and yields frames until it ends. The caller owns reconnecting (see
    /// `RoomStreamBackoff`) and resumes from the highest sequence it has applied.
    public func roomStream(
        sessionId: String,
        fromSequence: Int64?
    ) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                let end = await self.runRoomStream(
                    sessionId: sessionId,
                    fromSequence: fromSequence,
                    yield: { continuation.yield(.frame($0)) }
                )
                continuation.yield(.ended(end))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runRoomStream(
        sessionId: String,
        fromSequence: Int64?,
        yield: (RoomStreamFrame) -> Void
    ) async -> RoomStreamEnd {
        #if canImport(FoundationNetworking)
        return .retryable(retryAfterSeconds: nil)   // URLSession.bytes is unavailable off Apple platforms
        #else
        let request: URLRequest
        let token: String
        do {
            var query = [URLQueryItem(name: "controls", value: "agent-observability-v1")]
            if let fromSequence { query.append(URLQueryItem(name: "fromSequence", value: String(fromSequence))) }
            (request, token) = try authorizedRequest(
                path: ["api", "v1", "sessions", sessionId, "stream"],
                query: query,
                accept: "text/event-stream",
                timeout: 90
            )
        } catch SessionTransportError.notLoggedIn {
            return .reauthenticationRequired
        } catch {
            return .accessDenied
        }
        do {
            let (bytes, response) = try await streamingSession.bytes(for: request)
            guard currentToken() == token else { return .closed }
            guard let http = response as? HTTPURLResponse else { return .retryable(retryAfterSeconds: nil) }
            switch http.statusCode {
            case 200..<300:
                break
            case 401:
                return .reauthenticationRequired
            case 403, 404, 410:
                return .accessDenied
            case 409, 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                return .retryable(retryAfterSeconds: retryAfter ?? 30)
            default:
                return .retryable(retryAfterSeconds: nil)
            }
            var parser = SSELineParser()
            for try await line in bytes.lines {
                if Task.isCancelled { return .closed }
                // A sign-out or account switch mid-stream must stop delivering the old principal's rows.
                guard currentToken() == token else { return .closed }
                if let data = parser.feed(line), let frame = RoomStreamFrame.decode(data) {
                    if case .serverError = frame {
                        yield(frame)
                        return .retryable(retryAfterSeconds: nil)
                    }
                    yield(frame)
                }
                // `bytes.lines` drops the blank separator lines SSE relies on, so flush after every data line:
                // the server writes one complete JSON object per `data:` line.
                if line.hasPrefix("data:"), let data = parser.feed(""), let frame = RoomStreamFrame.decode(data) {
                    if case .serverError = frame {
                        yield(frame)
                        return .retryable(retryAfterSeconds: nil)
                    }
                    yield(frame)
                }
            }
            return .closed
        } catch is CancellationError {
            return .closed
        } catch let error as URLError where error.code == .cancelled {
            return .closed
        } catch {
            return .retryable(retryAfterSeconds: nil)
        }
        #endif
    }
}

/// What `roomStream` yields: frames, then exactly one `ended`.
public enum RoomStreamEvent: Equatable, Sendable {
    case frame(RoomStreamFrame)
    case ended(RoomStreamEnd)
}
