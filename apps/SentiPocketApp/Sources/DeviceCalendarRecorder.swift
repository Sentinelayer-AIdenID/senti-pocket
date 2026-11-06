#if DEBUG
import Foundation

/// DEBUG-only stand-in for the device-events routes, for the calendar preview's `connect` stage: GET answers an empty
/// list, PUT how many it stored, DELETE 204. Each request is written to `CAL_CAPTURE_FILE` (one JSON object a line:
/// when, method, path, query, idempotency key and body), so a device test sees exactly what left the app.
final class DeviceCalendarRecorder: URLProtocol {
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bytes.append(buffer, count: read)
            }
            stream.close()
            data = bytes
        }
        let body = data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0) }
        let method = request.httpMethod ?? "GET"
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let line: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "method": method,
            "path": components?.path ?? "",
            "query": query,
            "idempotencyKey": request.value(forHTTPHeaderField: "Idempotency-Key") ?? NSNull(),
            "body": body ?? NSNull()
        ]
        Self.record(line)

        let status: Int
        var answer = Data()
        switch method {
        case "PUT":
            status = 200
            let stored = ((body as? [String: Any])?["events"] as? [Any])?.count ?? 0
            answer = Data(#"{"stored": \#(stored)}"#.utf8)
        case "DELETE":
            status = 204
        default:
            status = 200
            answer = Data(#"{"events": []}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.isEmpty { client?.urlProtocol(self, didLoad: answer) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(_ line: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["CAL_CAPTURE_FILE"], !path.isEmpty,
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
