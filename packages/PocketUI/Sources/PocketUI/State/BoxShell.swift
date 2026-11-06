import Foundation
import PocketContracts

/// A box's terminal, as its mint console shows it (respawn-mint `console.ts`): the commands it runs, what they print
/// to stdout and stderr, and how each ended. Read from the console's own read-only events stream, through the
/// per-box view link the room already has (Carter: "shell does not show me shell. Shows me the same details as the
/// first tab").
public struct BoxShellLine: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case command, output, error, exit
    }

    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum BoxShell {
    /// Lines kept on the phone; older ones scroll away.
    public static let keptLines = 600
    /// A printed line longer than this is cut.
    public static let lineLimit = 400

    /// The box's events stream from its console link: the same https host, `/api/lives/<life>/events`, with the
    /// link's `life` and read-only `view` token. Nil for anything else (no view token, a different path, a bad id).
    public static func eventsURL(console: URL) -> URL? {
        guard console.scheme?.lowercased() == "https", let host = console.host, !host.isEmpty,
              let components = URLComponents(url: console, resolvingAgainstBaseURL: false),
              components.path == "/console" else { return nil }
        let items = components.queryItems ?? []
        guard let life = items.first(where: { $0.name == "life" })?.value,
              let view = items.first(where: { $0.name == "view" })?.value, !view.isEmpty,
              life.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        var events = URLComponents()
        events.scheme = "https"
        events.host = host
        events.port = components.port
        events.path = "/api/lives/\(life)/events"
        events.queryItems = [URLQueryItem(name: "life", value: life), URLQueryItem(name: "view", value: view)]
        return events.url
    }

    /// One event frame as terminal lines, numbered from `firstId`: `$ cmd`, each printed line, `↳ exit 0 (812 ms)`.
    /// Everything else the console streams (heartbeats, room messages, file captures) is not the shell.
    public static func lines(fromFrame data: String, firstId: Int) -> [BoxShellLine] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)),
              let kind = json["kind"]?.stringValue else { return [] }
        let body = json["data"] ?? .null
        switch kind {
        case "cmd_start":
            let command = body["cmd"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? body["cmd"]?.stringValue ?? ""
            return command.isEmpty ? [] : [BoxShellLine(id: firstId, kind: .command, text: "$ " + clip(command))]
        case "cmd_end":
            let code = body["exitCode"]?.intValue.map(String.init) ?? body["signal"]?.stringValue ?? "?"
            let took = body["durationMs"]?.intValue.map { " (\($0) ms)" } ?? ""
            return [BoxShellLine(id: firstId, kind: .exit, text: "↳ exit \(code)\(took)")]
        case "stdout", "stderr":
            guard let text = body["text"]?.stringValue else { return [] }
            var printed = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if printed.last == "" { printed.removeLast() }
            return printed.enumerated().map { offset, line in
                BoxShellLine(id: firstId + offset, kind: kind == "stdout" ? .output : .error, text: clip(line))
            }
        default:
            return []
        }
    }

    private static func clip(_ text: String) -> String {
        text.count > lineLimit ? String(text.prefix(lineLimit)) + "…" : text
    }
}
